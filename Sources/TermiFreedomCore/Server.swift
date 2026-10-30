import Foundation

public struct Server: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var group: String
    public var host: String
    public var user: String
    public var port: Int
    public var identityFile: String
    public init(id: UUID = UUID(), name: String = "", group: String = "", host: String = "", user: String = "", port: Int = 22, identityFile: String = "") {
        self.id = id; self.name = name; self.group = group; self.host = host; self.user = user; self.port = port; self.identityFile = identityFile
    }
    public func validated() throws -> Server {
        func fail(_ text: String) throws -> Never { throw ValidationError(text) }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try fail("Enter a name for this server.") }
        // A host may also be a trusted alias from the user's existing SSH config.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]%")
        if host.isEmpty || host.hasPrefix("-") || !host.unicodeScalars.allSatisfy(allowed.contains) { try fail("Enter a hostname, IP address, or SSH config alias without spaces or options.") }
        let users = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if user.hasPrefix("-") || !user.unicodeScalars.allSatisfy(users.contains) { try fail("The username contains unsupported characters.") }
        if !(1...65535).contains(port) { try fail("Port must be between 1 and 65535.") }
        if !identityFile.isEmpty && (!identityFile.hasPrefix("/") || identityFile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) { try fail("Choose an absolute path to an SSH key.") }
        return self
    }
    public func sftpArguments() throws -> [String] {
        var args = try sshArguments()
        args.removeAll { $0 == "-tt" }
        args.insert(contentsOf: ["-T", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-s"], at: 0)
        args.append("sftp")
        return args
    }
    public func sshArguments() throws -> [String] {
        _ = try validated()
        // Each argument goes directly to exec; no shell interpolation or remote command.
        var args = ["-tt", "-o", "ForwardAgent=no", "-o", "PermitLocalCommand=no", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-p", String(port)]
        if !user.isEmpty { args += ["-l", user] }
        if !identityFile.isEmpty { args += ["-o", "IdentitiesOnly=yes", "-i", identityFile] }
        args += ["--", host]
        return args
    }
}
public struct ValidationError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ServerStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    private struct Document: Codable { var version: Int; var servers: [Server] }
    public func load() throws -> [Server] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw ValidationError("Unsupported server file version. Your file has been preserved.") }
        guard Set(document.servers.map(\.id)).count == document.servers.count else { throw ValidationError("Duplicate server IDs in saved data.") }
        return try document.servers.map { try $0.validated() }
    }
    public func save(_ servers: [Server]) throws {
        _ = try servers.map { try $0.validated() }
        guard Set(servers.map(\.id)).count == servers.count else { throw ValidationError("Duplicate server IDs cannot be saved.") }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, servers: servers))
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
