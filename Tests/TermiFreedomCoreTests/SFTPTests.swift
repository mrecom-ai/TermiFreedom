import XCTest
@testable import TermiFreedomCore
import Darwin

final class SFTPTests: XCTestCase {
    func fixture() throws -> (URL, SFTPClient) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TermiFreedom-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path])
        return (root, SFTPClient(transport: transport))
    }
    func testBinaryRoundTripAndTruncatedPackets() throws {
        var writer = SFTPWriter(); writer.byte(42); writer.uint32(UInt32.max); writer.uint64(UInt64.max); try writer.string("space ' \" [*] café\n.txt")
        var reader = SFTPReader(data: writer.data)
        XCTAssertEqual(try reader.byte(), 42); XCTAssertEqual(try reader.uint32(), UInt32.max); XCTAssertEqual(try reader.uint64(), UInt64.max)
        XCTAssertEqual(try reader.string(), "space ' \" [*] café\n.txt")
        XCTAssertThrowsError(try reader.uint32())
        var truncated = SFTPReader(data: Data([0,0,0,100,1]))
        XCTAssertThrowsError(try truncated.bytes())
        XCTAssertThrowsError(try writer.string("bad\0name"))
    }
    func testFilenameValidationAndSFTPArguments() throws {
        XCTAssertEqual(try SFTPClient.childPath("quoted ' [*].txt", in: "/folder"), "/folder/quoted ' [*].txt")
        for invalid in ["..", ".", "", "/absolute", "a/b", "a\0b"] { XCTAssertThrowsError(try SFTPClient.childPath(invalid, in: "/tmp")) }
        let server = Server(name: "Example", host: "example.invalid", user: "tester", port: 2222)
        let args = try server.sftpArguments()
        XCTAssertEqual(Array(args.suffix(3)), ["--", "example.invalid", "sftp"])
        XCTAssertTrue(args.contains("-s")); XCTAssertTrue(args.contains("-T")); XCTAssertFalse(args.contains("-tt"))
        XCTAssertTrue(args.contains("ForwardAgent=no")); XCTAssertTrue(args.contains("ControlPath=none"))
    }
    func testRealSFTPProtocolListsCreatesAndRenamesUnicodeFolders() async throws {
        let (root, client) = try fixture(); defer { client.disconnect(); try? FileManager.default.removeItem(at: root) }
        try Data("sample".utf8).write(to: root.appendingPathComponent("a b ' [*] café.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
        try await client.handshake()
        let canonical = try await client.realPath(".")
        XCTAssertEqual(URL(fileURLWithPath: canonical).resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        var files = try await client.list(canonical)
        XCTAssertEqual(Set(files.map(\.name)), ["a b ' [*] café.txt", ".hidden"])
        let folder = try SFTPClient.childPath("New café folder", in: canonical)
        try await client.createDirectory(folder)
        let renamed = try SFTPClient.childPath("Renamed folder", in: canonical)
        try await client.rename(folder, to: renamed)
        files = try await client.list(canonical)
        XCTAssertTrue(files.contains { $0.name == "Renamed folder" && $0.isDirectory })
    }
    func testUploadDownloadAndAtomicReplacementThroughLocalSFTPServer() async throws {
        let (root, client) = try fixture(); defer { client.disconnect(); try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("source.bin")
        let content = Data((0..<200000).map { UInt8(truncatingIfNeeded: $0) })
        try content.write(to: local)
        try await client.handshake()
        let remote = root.appendingPathComponent("remote ' [*].bin").path
        try await client.upload(local: local, remote: remote, replacing: false) { _,_ in }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), content)
        let download = root.appendingPathComponent("download.bin")
        try Data("previous download".utf8).write(to: download)
        try await client.download(remote: remote, local: download) { _,_ in }
        XCTAssertEqual(try Data(contentsOf: download), content)
        let new = Data("replacement".utf8); try new.write(to: local)
        try await client.upload(local: local, remote: remote, replacing: true) { _,_ in }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), new)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".part") })
    }
    func testNoClobberAndFailedDownloadPreserveExistingFiles() async throws {
        let (root, client) = try fixture(); defer { client.disconnect(); try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("source"); try Data("new".utf8).write(to: local)
        let target = root.appendingPathComponent("existing"); let original = Data("original".utf8); try original.write(to: target)
        try await client.handshake()
        do { try await client.upload(local: local, remote: target.path, replacing: false) { _,_ in }; XCTFail("Unexpected overwrite") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), original)
        do { try await client.download(remote: root.appendingPathComponent("missing").path, local: target) { _,_ in }; XCTFail("Unexpected download") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".part") })
    }
    private final class CancelOnProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Error>?
        private var requested = false
        func bind(_ task: Task<Void, Error>) { lock.lock(); self.task = task; if requested { task.cancel() }; lock.unlock() }
        func progress(_ done: UInt64) { guard done >= 65536 else { return }; lock.lock(); requested = true; task?.cancel(); lock.unlock() }
    }
    func testCancelledUploadCleansTemporaryFileAndPreservesOriginal() async throws {
        let (root, client) = try fixture(); defer { client.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await client.handshake()
        let source = root.appendingPathComponent("source"); try Data(repeating: 91, count: 300000).write(to: source)
        let target = root.appendingPathComponent("original"); let original = Data("keep original".utf8); try original.write(to: target)
        let cancel = CancelOnProgress()
        let task = Task { try await client.upload(local: source, remote: target.path, replacing: true) { done,_ in cancel.progress(done) } }
        cancel.bind(task)
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".part") })
    }
    func testCancelledDownloadPreservesLocalDestination() async throws {
        let (root, client) = try fixture(); defer { client.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await client.handshake()
        let source = root.appendingPathComponent("remote"); try Data(repeating: 27, count: 300000).write(to: source)
        let target = root.appendingPathComponent("local"); let original = Data("keep local".utf8); try original.write(to: target)
        let cancel = CancelOnProgress()
        let task = Task { try await client.download(remote: source.path, local: target) { done,_ in cancel.progress(done) } }
        cancel.bind(task)
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".part") })
    }
    func testDisconnectReapsLocalSubsystem() async throws {
        let (root, client) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await client.handshake(); let pid = client.transport.pid
        client.disconnect()
        for _ in 0..<40 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("SFTP subsystem was not reaped")
    }
}
