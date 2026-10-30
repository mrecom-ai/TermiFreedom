import XCTest
@testable import TermiFreedomCore

final class BrandMigrationTests: XCTestCase {
    final class MemoryPasswords: PasswordBackend {
        var values: [String: String] = [:]
        var labels: [String: String] = [:]
        var reads: [String] = []
        var denied: String?
        var failWrites = false
        func key(_ service: String, _ account: String) -> String { service + ":" + account }
        func contains(service: String, account: String) throws -> Bool { values[key(service, account)] != nil }
        func read(service: String, account: String) throws -> String? {
            reads.append(service)
            if service == denied { throw ValidationError("Access denied") }
            return values[key(service, account)]
        }
        func write(_ value: String, service: String, account: String, label: String, onlyIfAbsent: Bool) throws -> Bool {
            if failWrites { throw ValidationError("Write denied") }
            let k = key(service, account)
            if onlyIfAbsent && values[k] != nil { return false }
            values[k] = value; labels[k] = label; return true
        }
        func delete(service: String, account: String) throws { values[key(service, account)] = nil }
    }
    func testCredentialAdoptionCopiesAndRetainsOriginal() throws {
        let backend = MemoryPasswords(); backend.values["previous:account"] = "fixture-password"
        let store = PasswordStore(service: "current", legacyService: "previous", backend: backend)
        XCTAssertTrue(try store.contains("account")); XCTAssertTrue(backend.reads.isEmpty)
        XCTAssertEqual(try store.read("account"), "fixture-password")
        XCTAssertEqual(backend.values["previous:account"], "fixture-password")
        XCTAssertEqual(backend.values["current:account"], "fixture-password")
        XCTAssertEqual(backend.labels["current:account"], "TermiFreedom SSH password")
        backend.reads = []; XCTAssertEqual(try store.read("account"), "fixture-password")
        XCTAssertEqual(backend.reads, ["current"])
    }
    func testReplacingPasswordDoesNotReadPreviousCredential() throws {
        let backend = MemoryPasswords(); backend.values["previous:account"] = "original"
        let store = PasswordStore(service: "current", legacyService: "previous", backend: backend)
        XCTAssertNil(try store.readCurrent("account")); try store.write("replacement", account: "account")
        XCTAssertEqual(backend.reads, ["current"]); XCTAssertEqual(backend.values["previous:account"], "original")
        try store.delete("account")
        XCTAssertNil(backend.values["previous:account"]); XCTAssertNil(backend.values["current:account"])
    }
    func testDeniedCredentialAdoptionPreservesOriginal() throws {
        let backend = MemoryPasswords(); backend.values["previous:account"] = "original"; backend.denied = "previous"
        let store = PasswordStore(service: "current", legacyService: "previous", backend: backend)
        XCTAssertThrowsError(try store.read("account")); XCTAssertEqual(backend.values["previous:account"], "original")
        XCTAssertNil(backend.values["current:account"])
        backend.denied = nil; backend.failWrites = true
        XCTAssertThrowsError(try store.read("account")); XCTAssertEqual(backend.values["previous:account"], "original")
    }
    func testDataAdoptionPreservesOriginalAndRemapsOnlyManagedKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent(LegacyCompatibility.dataDirectoryName)
        let keys = previous.appendingPathComponent("Keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = keys.appendingPathComponent("fixture-key"); try Data("dummy key fixture".utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let a = Server(name: "Example", host: "example.invalid", user: "tester", identityFile: key.path)
        let b = Server(name: "External", host: "other.invalid", identityFile: "/external/user-chosen-key")
        let oldStore = ServerStore(url: previous.appendingPathComponent("servers.json")); try oldStore.save([a,b])
        let original = try Data(contentsOf: oldStore.url)
        let current = try LocalDataMigration.prepare(in: root)
        let adopted = try ServerStore(url: current.appendingPathComponent("servers.json")).load()
        XCTAssertEqual(adopted.map(\.id), [a.id,b.id]); XCTAssertEqual(adopted[0].identityFile, current.appendingPathComponent("Keys/fixture-key").path)
        XCTAssertEqual(adopted[1].identityFile, b.identityFile)
        XCTAssertEqual(try Data(contentsOf: oldStore.url), original); XCTAssertTrue(FileManager.default.fileExists(atPath: key.path))
        XCTAssertEqual(try LocalDataMigration.prepare(in: root), current)
    }
    func testDataAdoptionDoesNotOverwriteExistingCurrentData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Server(name: "Previous", host: "old.invalid"), b = Server(name: "Current", host: "new.invalid")
        try ServerStore(url: root.appendingPathComponent(LegacyCompatibility.dataDirectoryName + "/servers.json")).save([a])
        let current = root.appendingPathComponent(AppIdentity.dataDirectoryName)
        let store = ServerStore(url: current.appendingPathComponent("servers.json")); try store.save([b])
        _ = try LocalDataMigration.prepare(in: root); XCTAssertEqual(try store.load(), [b])
    }
    func testInvalidPreviousDataDoesNotCreateCurrentStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent(LegacyCompatibility.dataDirectoryName)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: previous.appendingPathComponent("servers.json"))
        XCTAssertThrowsError(try LocalDataMigration.prepare(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(AppIdentity.dataDirectoryName).path))
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("servers.json"), encoding: .utf8), "corrupt")
    }
}
