import Foundation
import Security
import TermiFreedomCore

struct CredentialCheckResult {
    let passed: Bool
    let name: String
}
@MainActor enum CredentialChecks {
    static func run() async -> [CredentialCheckResult] {
        let headless = CommandLine.arguments.contains("--check-credentials")
        if headless { SecKeychainSetUserInteractionAllowed(false) }
        var results: [CredentialCheckResult] = []
        func check(_ passed: Bool, _ name: String) { results.append(CredentialCheckResult(passed: passed, name: name)) }
        do {
            let server = Server(name: "TermiFreedom credential self-test", host: "example.invalid", user: "termifreedom-test")
            let passwords = PasswordStore(), account = PasswordStore.account(for: server)
            let secret = UUID().uuidString
            defer { try? passwords.delete(account) }
            try passwords.write(secret, account: account)
            check(try passwords.contains(account) && passwords.read(account) == secret, "Keychain password save and read")
            let replacement = UUID().uuidString
            try passwords.write(replacement, account: account)
            check(try passwords.read(account) == replacement, "Keychain password update")
            let authentication = try AuthenticationContext(server: server)
            try authentication.activate(pid: ProcessInfo.processInfo.processIdentifier)
            var env = ProcessInfo.processInfo.environment
            authentication.environment.forEach { env[$0.key] = $0.value }
            if headless { env["TERMIFREEDOM_CREDENTIAL_CHECK"] = "1" }
            env["TERMIFREEDOM_ASKPASS_TEST_NO_UI"] = "1"
            check(!env.values.contains(replacement), "No password in child environment")
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/askpass").path
            func invoke(_ prompt: String) async throws -> (Int32, String) {
                let child = Process(); child.executableURL = URL(fileURLWithPath: helper); child.arguments = [prompt]; child.environment = env
                let output = Pipe(); child.standardOutput = output; child.standardError = FileHandle.nullDevice
                try child.run()
                return await Task.detached {
                    let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
                    return (child.terminationStatus, String(decoding: data, as: UTF8.self))
                }.value
            }
            let other = try await invoke("termifreedom-test@other.invalid's password: ")
            check(other.0 != 0 && other.1.isEmpty, "Another host cannot receive the saved password")
            try authentication.activate(pid: ProcessInfo.processInfo.processIdentifier + 1)
            let wrongParent = try await invoke("termifreedom-test@example.invalid's password: ")
            check(wrongParent.0 != 0 && wrongParent.1.isEmpty, "Unregistered parent process cannot retrieve a password")
            try authentication.activate(pid: ProcessInfo.processInfo.processIdentifier)
            let leasePath = env["TERMIFREEDOM_AUTH_LEASE"]!
            let forgedPath = authentication.directory.appendingPathComponent("forged.json")
            var forgedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: leasePath))) as! [String: Any]
            forgedJSON["signature"] = Data(repeating: 0, count: 32).base64EncodedString()
            try JSONSerialization.data(withJSONObject: forgedJSON).write(to: forgedPath)
            env["TERMIFREEDOM_AUTH_LEASE"] = forgedPath.path
            let forged = try await invoke("termifreedom-test@example.invalid's password: ")
            check(forged.0 != 0 && forged.1.isEmpty, "Forged authentication lease cannot retrieve a password")
            env["TERMIFREEDOM_AUTH_LEASE"] = leasePath
            let first = try await invoke("termifreedom-test@example.invalid's password: ")
            check(first.0 == 0 && first.1 == replacement + "\n", "OpenSSH askpass retrieves only the scoped Keychain password")
            let retry = try await invoke("termifreedom-test@example.invalid's password: ")
            check(retry.0 != 0 && retry.1.isEmpty, "Wrong-password retry requires user input")
            try passwords.delete(account)
            check(try !passwords.contains(account), "Keychain password removal")
            withExtendedLifetime(authentication) {}
        } catch { check(false, "Keychain integration: \(error.localizedDescription)") }
        do {
            let service = "app.termifreedom.erasure-check." + UUID().uuidString
            let otherService = service + ".unrelated"
            let backend = SystemPasswordBackend()
            defer { try? backend.deleteAll(service: service); try? backend.deleteAll(service: otherService) }
            try backend.write("fixture-a", service: service, account: "first", label: "TermiFreedom cleanup check", onlyIfAbsent: false)
            try backend.write("fixture-b", service: service, account: "orphan", label: "TermiFreedom cleanup check", onlyIfAbsent: false)
            try backend.write("fixture-c", service: otherService, account: "first", label: "TermiFreedom cleanup check", onlyIfAbsent: false)
            try backend.deleteAll(service: service)
            check(try !backend.contains(service: service, account: "first"), "Service-wide cleanup removes first credential")
            check(try !backend.contains(service: service, account: "orphan"), "Service-wide cleanup removes orphaned credential")
            check(try backend.contains(service: otherService, account: "first"), "Service-wide cleanup preserves unrelated services")
            try backend.deleteAll(service: service)
        } catch { check(false, "Keychain cleanup integration: \(error.localizedDescription)") }
        return results
    }
}
