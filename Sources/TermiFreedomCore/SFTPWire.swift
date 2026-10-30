import Foundation

public struct SFTPFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

struct SFTPWriter {
    var data = Data()
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func uint32(_ value: UInt32) { for shift in [24,16,8,0] { data.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func uint64(_ value: UInt64) { uint32(UInt32(truncatingIfNeeded: value >> 32)); uint32(UInt32(truncatingIfNeeded: value)) }
    mutating func bytes(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) throws {
        guard !value.contains("\0"), value.utf8.count <= 262144 else { throw SFTPFailure("The remote path is invalid or too long.") }
        bytes(Data(value.utf8))
    }
}
struct SFTPReader {
    let data: Data
    var offset = 0
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw SFTPFailure("The SFTP server sent a truncated packet.") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try take(1)[0] }
    mutating func uint32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    mutating func uint64() throws -> UInt64 { let hi = try uint32(); return (UInt64(hi) << 32) | UInt64(try uint32()) }
    mutating func bytes() throws -> Data { let count = try uint32(); return try take(Int(count)) }
    mutating func string() throws -> String {
        guard let text = String(data: try bytes(), encoding: .utf8), !text.contains("\0") else { throw SFTPFailure("This server returned a filename that is not valid UTF-8. No file was changed.") }
        return text
    }
}

public struct RemoteFile: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let size: UInt64
    public let permissions: UInt32
    public let modified: Date?
    public var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    public var isLink: Bool { permissions & 0o170000 == 0o120000 }
    public var permissionText: String { String(format: "%03o", permissions & 0o777) }
}
struct SFTPAttributes {
    var size: UInt64 = 0
    var permissions: UInt32 = 0
    var modified: UInt32?
    static func read(_ reader: inout SFTPReader) throws -> Self {
        let flags = try reader.uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPFailure("Unsupported SFTP attributes.") }
        var result = Self()
        if flags & 1 != 0 { result.size = try reader.uint64() }
        if flags & 2 != 0 { _ = try reader.uint32(); _ = try reader.uint32() }
        if flags & 4 != 0 { result.permissions = try reader.uint32() }
        if flags & 8 != 0 { _ = try reader.uint32(); result.modified = try reader.uint32() }
        if flags & 0x80000000 != 0 {
            let count = try reader.uint32(); guard count <= 128 else { throw SFTPFailure("Too many extended file attributes.") }
            for _ in 0..<count { _ = try reader.bytes(); _ = try reader.bytes() }
        }
        return result
    }
}

// Process cancellation is independent of the actor so a blocked network read can be interrupted.
public final class SFTPTransport: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorLock = NSLock()
    private var errors = Data()
    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }
    public init(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
        process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        try process.run()
        let handle = stderr.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                guard let self else { break }
                self.errorLock.lock(); self.errors.append(chunk)
                if self.errors.count > 32768 { self.errors = self.errors.suffix(32768) }
                self.errorLock.unlock()
            }
            try? handle.close()
        }
    }
    public func abort() { if process.isRunning { process.terminate() } }
    private func detail() -> String {
        errorLock.lock(); defer { errorLock.unlock() }
        let text = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The file connection closed." : text
    }
    func send(_ packet: Data) throws {
        guard packet.count <= 1_048_576 else { throw SFTPFailure("The SFTP request is too large.") }
        var framed = SFTPWriter(); framed.uint32(UInt32(packet.count)); framed.data.append(packet)
        do { try input.write(contentsOf: framed.data) } catch { throw SFTPFailure(detail()) }
    }
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try output.read(upToCount: count - data.count), !chunk.isEmpty else { throw SFTPFailure(detail()) }
            data.append(chunk)
        }
        return data
    }
    func receive() throws -> Data {
        var reader = SFTPReader(data: try readExactly(4))
        let size = try reader.uint32()
        guard size > 0, size <= 1_048_576 else { throw SFTPFailure("The server sent an invalid or oversized SFTP packet.") }
        return try readExactly(Int(size))
    }
    deinit {
        abort(); try? input.close(); try? output.close()
        let child = process
        DispatchQueue.global(qos: .utility).async { child.waitUntilExit() }
    }
}
