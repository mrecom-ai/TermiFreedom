import Foundation

/// Called only after explicit confirmation, with all app connections closed.
/// The injectable Keychain operation lets tests exercise erasure without real credentials.
public enum LocalDataErasure {
    public static let services = [AppIdentity.passwordService, AppIdentity.bundleIdentifier + ".authentication",
                                  LegacyCompatibility.passwordService, LegacyCompatibility.authenticationService]

    public static func erase(in applicationSupport: URL, deleteService: (String) throws -> Void) throws {
        let manager = FileManager.default
        let directories = [AppIdentity.dataDirectoryName, LegacyCompatibility.dataDirectoryName].map {
            applicationSupport.appendingPathComponent($0, isDirectory: true)
        }
        // Preflight both roots before touching Keychain. Never traverse a redirected data root.
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                throw ValidationError("A local data folder is a symbolic link. No data was erased. Resolve the link before trying again.")
            }
        }
        // Exact service scope also removes credentials orphaned by an edited/deleted server.
        // Failure is reported; subsequent attempts are safe and can complete partial cleanup.
        for service in services { try deleteService(service) }
        for directory in directories {
            do { try manager.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
    }
}
