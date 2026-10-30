import Foundation

// Read-only compatibility identifiers, never app names or permission-purpose strings.
// Keep originals available until the user has successfully adopted the current version.
public enum LegacyCompatibility {
    public static let dataDirectoryName = "HarborSSH"
    public static let passwordService = "local.jarrod.HarborSSH.passwords"
    public static let authenticationService = "local.jarrod.HarborSSH.authentication"
}

public enum LocalDataMigration {
    public static func prepare(in applicationSupport: URL) throws -> URL {
        let current = applicationSupport.appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
        let previous = applicationSupport.appendingPathComponent(LegacyCompatibility.dataDirectoryName, isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: previous.appendingPathComponent("servers.json").path) else { return current }
        if manager.fileExists(atPath: current.path) {
            guard manager.fileExists(atPath: current.appendingPathComponent("servers.json").path) else {
                throw ValidationError("The TermiFreedom data folder already exists without a server file. It was not overwritten; the previous data remains intact.")
            }
            return current
        }
        let staging = applicationSupport.appendingPathComponent(".TermiFreedom-import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: previous, to: staging)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        let store = ServerStore(url: staging.appendingPathComponent("servers.json"))
        var servers = try store.load()
        let oldKeys = previous.appendingPathComponent("Keys").path + "/"
        for index in servers.indices where servers[index].identityFile.hasPrefix(oldKeys) {
            let name = String(servers[index].identityFile.dropFirst(oldKeys.count))
            guard !name.contains("/"), !name.isEmpty,
                  manager.fileExists(atPath: staging.appendingPathComponent("Keys").appendingPathComponent(name).path) else { continue }
            servers[index].identityFile = current.appendingPathComponent("Keys").appendingPathComponent(name).path
        }
        try store.save(servers)
        try manager.moveItem(at: staging, to: current)
        return current
    }
}
