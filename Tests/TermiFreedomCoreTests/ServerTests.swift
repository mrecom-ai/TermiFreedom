import XCTest
@testable import TermiFreedomCore

final class TermiFreedomCoreTests: XCTestCase {
    func server(_ host: String = "example.test") -> Server { Server(name: "Test", group: "Lab", host: host, user: "tester") }
    func testArgumentsAreSeparateAndDisableSharing() throws {
        var s = server(); s.identityFile = "/tmp/key with spaces;$(touch nope)"
        let args = try s.sshArguments()
        XCTAssertEqual(Array(args.suffix(2)), ["--", "example.test"])
        XCTAssertTrue(args.contains(s.identityFile)); XCTAssertTrue(args.contains("ControlPath=none"))
        XCTAssertTrue(args.contains("ForwardAgent=no")); XCTAssertTrue(args.contains("PermitLocalCommand=no"))
    }
    func testRejectOptionAndShellInjection() {
        for host in ["-oProxyCommand=id", "host name", "a;id", "a\nHost b", "user@host", "$(id)", "", "host/path"] { XCTAssertThrowsError(try server(host).sshArguments(), host) }
        for host in ["lab", "server.example", "192.0.2.1", "2001:db8::1", "fe80::1%en0"] { XCTAssertNoThrow(try server(host).sshArguments()) }
        var s = server(); s.user = "-root"; XCTAssertThrowsError(try s.validated())
        s.user = ""; s.port = 0; XCTAssertThrowsError(try s.validated())
        s.port = 65536; XCTAssertThrowsError(try s.validated())
        s.port = 22; s.identityFile = "relative"; XCTAssertThrowsError(try s.validated())
    }
    func testStorageRoundTripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ServerStore(url: dir.appendingPathComponent("servers.json"))
        XCTAssertEqual(try store.load(), [])
        let s = server(); try store.save([s]); XCTAssertEqual(try store.load(), [s])
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try store.save([]); XCTAssertEqual(try store.load(), [])
    }
    func testCorruptDataIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ServerStore(url: dir.appendingPathComponent("servers.json"))
        let data = Data("broken".utf8); try data.write(to: store.url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: store.url), data)
    }
    func testRejectUnsupportedSchemaAndDuplicateIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ServerStore(url: dir.appendingPathComponent("servers.json"))
        try store.save([server()])
        var text = try String(contentsOf: store.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99")
        try text.write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
        let s = server(); XCTAssertThrowsError(try store.save([s, s]))
    }
}
