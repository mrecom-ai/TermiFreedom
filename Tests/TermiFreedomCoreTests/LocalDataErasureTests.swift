import XCTest
@testable import TermiFreedomCore

final class LocalDataErasureTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in [AppIdentity.dataDirectoryName, LegacyCompatibility.dataDirectoryName, "Unrelated"] {
            let keys = root.appendingPathComponent(name).appendingPathComponent("Keys")
            try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: keys.appendingPathComponent("managed-key"))
        }
        return root
    }
    func testErasureIsScopedIdempotentAndDoesNotRestoreOldData() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var deleted: [String] = []
        try LocalDataErasure.erase(in: root) { deleted.append($0) }
        XCTAssertEqual(deleted, LocalDataErasure.services)
        XCTAssertEqual(Set(deleted).count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(AppIdentity.dataDirectoryName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LegacyCompatibility.dataDirectoryName).path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Unrelated/Keys/managed-key"), encoding: .utf8), "fixture")
        let current = try LocalDataMigration.prepare(in: root)
        XCTAssertEqual(try ServerStore(url: current.appendingPathComponent("servers.json")).load(), [])
        try LocalDataErasure.erase(in: root) { _ in }
    }
    func testKeychainFailureKeepsFilesAndCanBeRetried() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try LocalDataErasure.erase(in: root) { _ in throw ValidationError("Fixture denial") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(AppIdentity.dataDirectoryName + "/Keys/managed-key").path))
        try LocalDataErasure.erase(in: root) { _ in }
    }
    func testDataRootSymlinkIsRejectedBeforeDeletingCredentials() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent(AppIdentity.dataDirectoryName)
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: root.appendingPathComponent("Unrelated"))
        var touched = false
        XCTAssertThrowsError(try LocalDataErasure.erase(in: root) { _ in touched = true })
        XCTAssertFalse(touched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Unrelated/Keys/managed-key").path))
    }
    func testNestedSymlinkDoesNotEraseExternalKey() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent(AppIdentity.dataDirectoryName + "/Keys/external")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Unrelated"))
        try LocalDataErasure.erase(in: root) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Unrelated/Keys/managed-key").path))
    }
}
