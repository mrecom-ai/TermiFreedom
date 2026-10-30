import AppKit
import SwiftUI
import TermiFreedomCore
import Darwin

@MainActor final class KeyInstaller: ObservableObject {
    @Published var busy = false
    @Published var message: String?
    @Published var succeeded = false
    private var process: Process?
    private var cancelled = false

    func cancel() { cancelled = true; process?.terminate() }
    private func run(_ executable: String, _ args: [String], input: Data = Data(), environment: [String: String]? = nil, authentication: AuthenticationContext? = nil) async throws -> String {
        if cancelled { throw CancellationError() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = args
        child.environment = environment ?? ProcessInfo.processInfo.environment
        let output = Pipe(), stdin = Pipe()
        child.standardOutput = output; child.standardError = output; child.standardInput = stdin
        try child.run(); process = child
        defer { process = nil }
        do { try authentication?.activate(pid: child.processIdentifier) }
        catch { child.terminate(); throw error }
        // Keys are small; this input contains only the public key, never a password.
        try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close()
        let result = await Task.detached { () -> (Int32, String) in
            var captured = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                if captured.count < 32768 { captured.append(chunk.prefix(32768 - captured.count)) }
            }
            child.waitUntilExit()
            return (child.terminationStatus, String(decoding: captured, as: UTF8.self))
        }.value
        process = nil
        if cancelled { throw CancellationError() }
        guard result.0 == 0 else { throw ValidationError(result.1.isEmpty ? "The SSH operation did not complete." : result.1) }
        return result.1
    }
    func install(server: Server, existingPublicKey: URL?, model: AppModel) async {
        guard !busy else { return }
        if RunMode.uiPreview { message = "Server changes are disabled in this local UI test."; return }
        busy = true; cancelled = false; message = nil
        defer { busy = false }
        do {
            var updated = server
            let privateKey: URL
            let publicKey: URL
            if let existingPublicKey {
                guard existingPublicKey.pathExtension == "pub" else { throw ValidationError("Choose the public .pub file for an existing SSH key.") }
                publicKey = existingPublicKey; privateKey = existingPublicKey.deletingPathExtension()
                guard FileManager.default.fileExists(atPath: privateKey.path) else { throw ValidationError("The matching private key must be beside the .pub file.") }
            } else {
                let directory = model.store.url.deletingLastPathComponent().appendingPathComponent("Keys")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                privateKey = directory.appendingPathComponent(server.id.uuidString.lowercased() + "_ed25519")
                publicKey = URL(fileURLWithPath: privateKey.path + ".pub")
                if !FileManager.default.fileExists(atPath: privateKey.path) && !FileManager.default.fileExists(atPath: publicKey.path) {
                    message = "Creating a key on this Mac…"
                    _ = try await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "TermiFreedom", "-f", privateKey.path])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
                }
            }
            let values = try publicKey.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) < 32768 else { throw ValidationError("The selected public key is too large.") }
            let key = try SSHPublicKey(String(contentsOf: publicKey, encoding: .utf8))
            message = "Adding the public key to \(server.name)…"
            let authentication = try AuthenticationContext(server: server, forcePrompt: true)
            var env = ProcessInfo.processInfo.environment
            authentication.environment.forEach { env[$0.key] = $0.value }
            // Ensure the public file belongs to the private key before granting access.
            let derived = try await run("/usr/bin/ssh-keygen", ["-y", "-f", privateKey.path], environment: env, authentication: authentication)
            guard try SSHPublicKey(derived).material == key.material else { throw ValidationError("The public key does not match its private key. No server changes were made.") }
            var args = try KeyInstallation.arguments(server: server)
            args.insert(contentsOf: ["-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"], at: 0)
            let output = try await run("/usr/bin/ssh", args, input: Data((key.material + "\n").utf8), environment: env, authentication: authentication)
            withExtendedLifetime(authentication) {}
            guard output.contains("TERMIFREEDOM_KEY_INSTALLED") else { throw ValidationError("The server did not confirm installation. The saved connection has not been changed.") }
            updated.identityFile = privateKey.path
            // Preserve any edits made while the sheet was open; only update the key path.
            guard var current = model.servers.first(where: { $0.id == server.id }), current.host == server.host, current.port == server.port, current.user == server.user else { throw ValidationError("The key was installed, but the saved server changed. Set its key path manually: \(privateKey.path)") }
            current.identityFile = updated.identityFile
            do { try model.save(current) } catch { throw ValidationError("The key was installed, but its path could not be saved. The key remains at \(privateKey.path). \(error.localizedDescription)") }
            succeeded = true
            message = "Key added. Future connections will use it. Your saved password is still in Keychain."
        } catch is CancellationError { message = "Cancelled. If the server had already accepted the key, it may remain installed. Your active terminal is unchanged." }
        catch { message = error.localizedDescription }
    }
}

struct InstallKeySheet: View {
    let server: Server
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var installer = KeyInstaller()
    @State private var publicKey: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add key to \(server.name)").font(.title2.bold())
            Text("Account: \(server.user.isEmpty ? "SSH default user" : server.user)@\(server.host):\(server.port)").textSelection(.enabled)
            Text("TermiFreedom will open a separate SSH connection and add only the public key to this account’s authorized keys. Your current terminal stays open. You may be asked to authenticate again.")
            HStack {
                Text(publicKey?.lastPathComponent ?? "Create a new TermiFreedom key").lineLimit(1)
                Spacer()
                Button("Choose existing key…") { choose() }.disabled(installer.busy)
                if publicKey != nil { Button("Use new key") { publicKey = nil }.disabled(installer.busy) }
            }
            if publicKey == nil {
                Text("The new private key stays on this Mac, protected by file permissions. It has no passphrase, so anyone with access to your Mac account could use it.").font(.caption).foregroundStyle(.secondary)
            }
            Text("This creates ~/.ssh if needed, preserves existing authorized keys, skips duplicate keys, and sets SSH folder/file permissions to 700/600. Password login remains available.").font(.caption).foregroundStyle(.secondary)
            if installer.busy { ProgressView().controlSize(.small) }
            if let message = installer.message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(installer.busy ? "Cancel operation" : (installer.succeeded ? "Done" : "Cancel")) {
                    if installer.busy { installer.cancel() } else { dismiss() }
                }
                if !installer.succeeded {
                    Button("Add key to server") { Task { await installer.install(server: server, existingPublicKey: publicKey, model: model) } }.buttonStyle(.borderedProminent).disabled(installer.busy)
                }
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(installer.busy)
            .onAppear { model.activeInstaller = installer }
            .onDisappear { if model.activeInstaller === installer { model.activeInstaller = nil } }
    }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "Choose an existing public key (.pub). Its matching private key stays on this Mac."
        if panel.runModal() == .OK { publicKey = panel.url }
    }
}
