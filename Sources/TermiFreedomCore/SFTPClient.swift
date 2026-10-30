import Foundation
import Darwin

public actor SFTPClient {
    public nonisolated let transport: SFTPTransport
    private var nextID: UInt32 = 0
    private var supportsAtomicReplace = false
    public init(transport: SFTPTransport) { self.transport = transport }
    public nonisolated func disconnect() { transport.abort() }
    public func handshake() throws {
        var packet = SFTPWriter(); packet.byte(1); packet.uint32(3); try transport.send(packet.data)
        var reply = SFTPReader(data: try transport.receive())
        guard try reply.byte() == 2, try reply.uint32() == 3 else { throw SFTPFailure("The server does not support SFTP version 3.") }
        while reply.offset < reply.data.count {
            let name = try reply.string(), value = try reply.string()
            if name == "posix-rename@openssh.com", value == "1" { supportsAtomicReplace = true }
        }
    }
    private func request(_ type: UInt8, ignoringCancellation: Bool = false, _ body: (inout SFTPWriter) throws -> Void) throws -> (UInt8, SFTPReader) {
        if !ignoringCancellation { try Task.checkCancellation() }
        nextID &+= 1
        var packet = SFTPWriter(); packet.byte(type); packet.uint32(nextID); try body(&packet); try transport.send(packet.data)
        var reply = SFTPReader(data: try transport.receive()); let kind = try reply.byte()
        guard try reply.uint32() == nextID else { throw SFTPFailure("The SFTP server replied with an unexpected request ID.") }
        return (kind, reply)
    }
    private func status(_ response: (UInt8, SFTPReader), allowEOF: Bool = false) throws -> Bool {
        var (kind, reader) = response
        guard kind == 101 else { throw SFTPFailure("Unexpected SFTP reply.") }
        let code = try reader.uint32(), message = try reader.string()
        if code == 0 { return false }
        if allowEOF && code == 1 { return true }
        throw SFTPFailure(message.isEmpty ? "SFTP failed (code \(code))." : message)
    }
    public func realPath(_ path: String) throws -> String {
        var (kind, reader) = try request(16) { try $0.string(path) }
        if kind == 101 { _ = try status((kind, reader)) }
        guard kind == 104, try reader.uint32() == 1 else { throw SFTPFailure("The server could not resolve this folder.") }
        return try reader.string()
    }
    private func attributes(_ path: String, followLinks: Bool = true) throws -> SFTPAttributes {
        var (kind, reader) = try request(followLinks ? 17 : 7) { try $0.string(path) }
        if kind == 101 { _ = try status((kind, reader)) }
        guard kind == 105 else { throw SFTPFailure("The server could not read file information.") }
        return try SFTPAttributes.read(&reader)
    }
    private func handle(_ type: UInt8, body: (inout SFTPWriter) throws -> Void) throws -> Data {
        var (kind, reader) = try request(type, body)
        if kind == 101 { _ = try status((kind, reader)) }
        guard kind == 102 else { throw SFTPFailure("The server could not open the file or folder.") }
        return try reader.bytes()
    }
    private func close(_ handle: Data) { _ = try? status(request(4, ignoringCancellation: true) { $0.bytes(handle) }) }
    public func list(_ path: String) throws -> [RemoteFile] {
        let directory = try handle(11) { try $0.string(path) }; defer { close(directory) }
        var files: [RemoteFile] = []
        while true {
            var (kind, reader) = try request(12) { $0.bytes(directory) }
            if kind == 101 { if try status((kind, reader), allowEOF: true) { return files }; throw SFTPFailure("Unexpected directory status.") }
            guard kind == 104 else { throw SFTPFailure("Unexpected directory listing reply.") }
            let count = try reader.uint32()
            guard count > 0, count <= 10000, files.count + Int(count) <= 10000 else { throw SFTPFailure("This folder exceeds the 10,000-entry browser limit. Open a smaller folder by its path.") }
            for _ in 0..<count {
                let name = try reader.string(); _ = try reader.string(); let attrs = try SFTPAttributes.read(&reader)
                guard name != ".", name != ".." else { continue }
                guard !name.contains("/"), !name.isEmpty else { throw SFTPFailure("The server returned an invalid filename.") }
                files.append(RemoteFile(name: name, size: attrs.size, permissions: attrs.permissions, modified: attrs.modified.map { Date(timeIntervalSince1970: Double($0)) }))
            }
        }
    }
    public static func childPath(_ name: String, in directory: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw SFTPFailure("Enter a single file or folder name.") }
        return (directory == "/" ? "/" : directory + "/") + name
    }
    public func createDirectory(_ path: String) throws {
        _ = try status(request(14) { try $0.string(path); $0.uint32(4); $0.uint32(0o700) })
    }
    public func rename(_ old: String, to new: String) throws {
        _ = try status(request(18) { try $0.string(old); try $0.string(new) })
    }
    private func remove(_ path: String) { _ = try? status(request(13, ignoringCancellation: true) { try $0.string(path) }) }
    public func upload(local: URL, remote: String, replacing: Bool, progress: @Sendable (UInt64, UInt64) -> Void) throws {
        let localAttributes = try FileManager.default.attributesOfItem(atPath: local.path)
        guard localAttributes[.type] as? FileAttributeType == .typeRegular else { throw SFTPFailure("Only regular files can be uploaded in this version.") }
        let total = (localAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        let permissions: UInt32
        if replacing {
            guard supportsAtomicReplace else { throw SFTPFailure("This server cannot replace a file atomically. Upload under a different name to preserve the existing file.") }
            let existing = try attributes(remote, followLinks: false)
            guard existing.permissions & 0o170000 == 0o100000 else { throw SFTPFailure("Only an existing regular file can be replaced.") }
            permissions = existing.permissions & 0o777
        } else { permissions = UInt32((localAttributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o600) & 0o777 }
        let temporary = remote + ".termifreedom-" + UUID().uuidString + ".part"
        let file = try handle(3) { try $0.string(temporary); $0.uint32(2 | 8 | 32); $0.uint32(4); $0.uint32(permissions) }
        var completed = false, closed = false
        defer { if !closed { close(file) }; if !completed { remove(temporary) } }
        let source = try FileHandle(forReadingFrom: local); defer { try? source.close() }
        var offset: UInt64 = 0, lastReport = Date.distantPast
        progress(0, total)
        while offset < total {
            try Task.checkCancellation()
            guard let data = try source.read(upToCount: Int(min(65536, total - offset))), !data.isEmpty else { throw SFTPFailure("The local file changed during upload. The destination was preserved.") }
            _ = try status(request(6) { $0.bytes(file); $0.uint64(offset); $0.bytes(data) })
            offset += UInt64(data.count)
            if Date().timeIntervalSince(lastReport) >= 0.1 { progress(offset, total); lastReport = Date() }
        }
        let now = try FileManager.default.attributesOfItem(atPath: local.path)
        guard now[.size] as? NSNumber == localAttributes[.size] as? NSNumber, now[.modificationDate] as? Date == localAttributes[.modificationDate] as? Date else { throw SFTPFailure("The local file changed during upload. The destination was preserved.") }
        _ = try status(request(4) { $0.bytes(file) }); closed = true
        try Task.checkCancellation()
        if replacing { _ = try status(request(200) { try $0.string("posix-rename@openssh.com"); try $0.string(temporary); try $0.string(remote) }) }
        else { _ = try status(request(18) { try $0.string(temporary); try $0.string(remote) }) }
        completed = true; progress(total, total)
    }
    public func download(remote: String, local: URL, progress: @Sendable (UInt64, UInt64) -> Void) throws {
        let initial = try attributes(remote, followLinks: false)
        guard initial.permissions & 0o170000 == 0o100000 else { throw SFTPFailure("Only regular files can be downloaded in this version.") }
        let source = try handle(3) { try $0.string(remote); $0.uint32(1); $0.uint32(0) }; defer { close(source) }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".termifreedom-\(UUID().uuidString).part")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SFTPFailure("A temporary download file could not be created.") }
        let target = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var completed = false
        defer { try? target.close(); if !completed { try? FileManager.default.removeItem(at: temporary) } }
        var offset: UInt64 = 0, lastReport = Date.distantPast
        progress(0, initial.size)
        while offset < initial.size {
            var (kind, reader) = try request(5) { $0.bytes(source); $0.uint64(offset); $0.uint32(UInt32(min(65536, initial.size - offset))) }
            if kind == 101 { _ = try status((kind, reader)); throw SFTPFailure("The remote file changed during download.") }
            guard kind == 103 else { throw SFTPFailure("Unexpected file data reply.") }
            let data = try reader.bytes()
            guard !data.isEmpty, data.count <= 65536, UInt64(data.count) <= initial.size - offset else { throw SFTPFailure("The server returned invalid file data.") }
            try target.write(contentsOf: data); offset += UInt64(data.count)
            if Date().timeIntervalSince(lastReport) >= 0.1 { progress(offset, initial.size); lastReport = Date() }
        }
        let final = try attributes(remote)
        guard initial.size == final.size, initial.modified == final.modified else { throw SFTPFailure("The remote file changed during download. The existing local file was preserved.") }
        try Task.checkCancellation()
        try target.synchronize(); try target.close()
        guard Darwin.rename(temporary.path, local.path) == 0 else { throw SFTPFailure("The completed download could not be moved to its destination.") }
        completed = true; progress(offset, initial.size)
    }
}
