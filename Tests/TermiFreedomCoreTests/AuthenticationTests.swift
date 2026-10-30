import XCTest
@testable import TermiFreedomCore

final class AuthenticationTests: XCTestCase {
    func testPasswordScopeChangesWithEndpointButNotKeyPath() {
        let original = Server(name: "Test", host: "example.invalid", user: "root")
        var changed = original; changed.host = "other.invalid"
        XCTAssertNotEqual(PasswordStore.account(for: original), PasswordStore.account(for: changed))
        changed = original; changed.user = "admin"
        XCTAssertNotEqual(PasswordStore.account(for: original), PasswordStore.account(for: changed))
        changed = original; changed.port = 2222
        XCTAssertNotEqual(PasswordStore.account(for: original), PasswordStore.account(for: changed))
        changed = original; changed.identityFile = "/tmp/key"
        XCTAssertEqual(PasswordStore.account(for: original), PasswordStore.account(for: changed))
    }
    func testOnlyExactEndpointPasswordPromptsCanUseSavedPassword() {
        XCTAssertTrue(PasswordPrompt.matches("root@example.invalid's password: ", user: "root", host: "example.invalid"))
        for prompt in ["root@other.invalid's password:", "[sudo] password for root:", "Enter passphrase for key '/tmp/key':", "Verification code:", "Are you sure you want to continue connecting?", "Password:"] {
            XCTAssertFalse(PasswordPrompt.matches(prompt, user: "root", host: "example.invalid"))
        }
        XCTAssertFalse(PasswordPrompt.matches("@example.invalid's password:", user: "", host: "example.invalid"))
    }
    func publicKey() -> String {
        let type = Data("ssh-ed25519".utf8)
        let data = Data([0,0,0,11]) + type + Data([0,0,0,32]) + Data(repeating: 17, count: 32)
        return "ssh-ed25519 " + data.base64EncodedString()
    }
    func testRejectPrivateKeysMalformedAndMultipleKeys() throws {
        XCTAssertEqual(try SSHPublicKey(publicKey() + " test comment").material, publicKey())
        for invalid in ["-----BEGIN OPENSSH PRIVATE KEY-----", "ssh-ed25519 AAAA", publicKey() + "\n" + publicKey(), "ssh-rsa " + publicKey().split(separator: " ")[1]] {
            XCTAssertThrowsError(try SSHPublicKey(invalid))
        }
    }
    func runScript(home: URL, key: String) throws -> (Int32, String) {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = ["-c", KeyInstallation.remoteCommand]
        var env = ProcessInfo.processInfo.environment; env["HOME"] = home.path; child.environment = env
        let input = Pipe(), output = Pipe(); child.standardInput = input; child.standardOutput = output; child.standardError = output
        try child.run(); input.fileHandleForWriting.write(Data((key + "\n").utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        return (child.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    func testInstallationPreservesExistingKeysAndIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".ssh"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("authorized_keys")
        let existing = "# keep this comment\nssh-ed25519 existing-key existing-comment\n"
        try existing.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try runScript(home: home, key: publicKey()).0, 0)
        let once = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(once.hasPrefix(existing)); XCTAssertTrue(once.contains(publicKey()))
        XCTAssertEqual(try runScript(home: home, key: publicKey()).0, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), once)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testExistingRestrictedKeyIsNotAddedAgainWithoutRestrictions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".ssh"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("authorized_keys")
        let existing = "no-port-forwarding,command=\"echo restricted\" " + publicKey() + " original-comment\n"
        try existing.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try runScript(home: home, key: publicKey()).0, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), existing)
    }
    func testInstallationRefusesSymlinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".ssh"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("untouched"); try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("authorized_keys"), withDestinationURL: target)
        XCTAssertNotEqual(try runScript(home: home, key: publicKey()).0, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }
    func testGeneratedKeyPairCanBeValidatedWithoutReadingPrivateMaterial() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("test key")
        let generate = Process(); generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "TermiFreedom test", "-f", key.path]
        try generate.run(); generate.waitUntilExit(); XCTAssertEqual(generate.terminationStatus, 0)
        let derive = Process(); derive.executableURL = generate.executableURL; derive.arguments = ["-y", "-f", key.path]
        let output = Pipe(); derive.standardOutput = output; try derive.run()
        let derived = output.fileHandleForReading.readDataToEndOfFile(); derive.waitUntilExit()
        XCTAssertEqual(derive.terminationStatus, 0)
        XCTAssertEqual(try SSHPublicKey(String(contentsOfFile: key.path + ".pub", encoding: .utf8)).material,
                       try SSHPublicKey(String(decoding: derived, as: UTF8.self)).material)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testKeyInstallArgumentsUseNonInteractivePTYAndOneQuotedCommand() throws {
        let server = Server(name: "Test", host: "example.invalid", user: "root")
        let args = try KeyInstallation.arguments(server: server)
        XCTAssertFalse(args.contains("-tt")); XCTAssertTrue(args.contains("-T"))
        XCTAssertEqual(args.last, KeyInstallation.remoteCommand)
        XCTAssertEqual(args[args.count - 2], server.host)
    }
}
