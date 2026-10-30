import Foundation
import Security
import AppKit
import TermiFreedomCore
import Darwin
import CryptoKit

// Only credential references, never secrets, enter the child environment.
private struct AuthenticationLease: Codable {
    var parentPID: Int32
    var account: String
    var host: String
    var user: String
    var marker: String
    var expires: TimeInterval
}
private struct SignedAuthenticationLease: Codable { var payload: Data; var signature: Data }

// Signed, short-lived leases bind a credential request to a child TermiFreedom launched.
final class AuthenticationContext {
    let directory: URL
    let environment: [String: String]
    private let server: Server
    private let signingKey: Data
    // Production retains its original bundle identifier. Verification bundles use isolated control secrets.
    private static var signingService: String { (Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier) + ".authentication" }
    init(server: Server, forcePrompt: Bool = false) throws {
        self.server = server
        let account = PasswordStore.account(for: server)
        let saved = try PasswordStore().contains(account)
        signingKey = try PasswordStore(service: Self.signingService).installationSecret()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TermiFreedom-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/askpass").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            try? FileManager.default.removeItem(at: directory)
            throw ValidationError("The authentication helper is missing. Open the built TermiFreedom.app.")
        }
        environment = ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": (saved || forcePrompt) ? "force" : "prefer",
                       "TERMIFREEDOM_AUTH_LEASE": directory.appendingPathComponent("lease.json").path]
    }
    func activate(pid: Int32) throws {
        guard pid > 1 else { throw ValidationError("SSH did not start successfully.") }
        let lease = AuthenticationLease(parentPID: pid, account: PasswordStore.account(for: server), host: server.host,
                                        user: server.user.isEmpty ? NSUserName() : server.user,
                                        marker: directory.appendingPathComponent("password-used").path,
                                        expires: Date().timeIntervalSince1970 + 300)
        let payload = try JSONEncoder().encode(lease)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: signingKey)))
        let url = directory.appendingPathComponent("lease.json")
        try JSONEncoder().encode(SignedAuthenticationLease(payload: payload, signature: signature)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    fileprivate static func verify(environment: [String: String]) -> AuthenticationLease? {
        guard let path = environment["TERMIFREEDOM_AUTH_LEASE"] else { return nil }
        // The helper may start before the parent finishes writing its child's lease.
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: path) { break }
            usleep(10_000)
        }
        guard let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 32768, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let signed = try? JSONDecoder().decode(SignedAuthenticationLease.self, from: data),
              let encodedKey = try? PasswordStore(service: Self.signingService).read("authentication-lease-signing-key"),
              let key = Data(base64Encoded: encodedKey),
              HMAC<SHA256>.isValidAuthenticationCode(signed.signature, authenticating: signed.payload, using: SymmetricKey(data: key)),
              let lease = try? JSONDecoder().decode(AuthenticationLease.self, from: signed.payload),
              lease.parentPID == getppid(), lease.expires > Date().timeIntervalSince1970 else { return nil }
        return lease
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor enum Askpass {
    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        if env["TERMIFREEDOM_CREDENTIAL_CHECK"] == "1" { SecKeychainSetUserInteractionAllowed(false) }
        let prompt = CommandLine.arguments.dropFirst(2).joined(separator: " ")
        guard let lease = AuthenticationContext.verify(environment: env) else { exit(1) }
        if PasswordPrompt.matches(prompt, user: lease.user, host: lease.host),
           let password = try? PasswordStore().read(lease.account) {
            let fd = open(lease.marker, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            if fd >= 0 { Darwin.close(fd); answer(password) }
        }
        if env["TERMIFREEDOM_ASKPASS_TEST_NO_UI"] == "1" { exit(2) }
        let parent = getppid()
        guard parent > 1 else { exit(1) }
        let monitor = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        monitor.setEventHandler { exit(1) }; monitor.resume()
        defer { monitor.cancel() }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "TermiFreedom · SSH authentication"
        alert.informativeText = String(prompt.prefix(3000))
        if env["SSH_ASKPASS_PROMPT"] == "confirm" || prompt.contains("Are you sure you want to continue connecting") {
            alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { answer("yes") }
        } else {
            let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
            alert.accessoryView = input
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = input
            if alert.runModal() == .alertFirstButtonReturn { answer(input.stringValue) }
        }
        exit(1)
    }
    private static func answer(_ text: String) -> Never {
        FileHandle.standardOutput.write(Data((text + "\n").utf8)); exit(0)
    }
}

@main enum TermiFreedomEntry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--askpass" { Askpass.run() }
        if CommandLine.arguments.dropFirst().first == "--check-credentials" {
            Task { @MainActor in
                let results = await CredentialChecks.run()
                let report = results.map { "\($0.passed ? "PASS" : "FAIL"): \($0.name)" }.joined(separator: "\n") + "\n"
                if let i = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(i + 1) {
                    try? report.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
                }
                print(report); fflush(stdout); exit(results.allSatisfy(\.passed) ? 0 : 1)
            }
            dispatchMain()
        }
        TermiFreedomApp.main()
    }
}
