import Foundation
import Security
import CryptoKit

public protocol PasswordBackend {
    func contains(service: String, account: String) throws -> Bool
    func read(service: String, account: String) throws -> String?
    @discardableResult func write(_ value: String, service: String, account: String, label: String, onlyIfAbsent: Bool) throws -> Bool
    func delete(service: String, account: String) throws
}

public struct SystemPasswordBackend: PasswordBackend {
    public init() {}
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ValidationError("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))") }
    }
    public func contains(service: String, account: String) throws -> Bool {
        var q = query(service, account); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecItemNotFound { return false }; try check(status); return true
    }
    public func read(service: String, account: String) throws -> String? {
        var q = query(service, account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }; try check(status)
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw ValidationError("The saved password could not be read.") }
        return text
    }
    @discardableResult public func write(_ value: String, service: String, account: String, label: String, onlyIfAbsent: Bool) throws -> Bool {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrLabel as String: label, kSecAttrDescription as String: label]
        if !onlyIfAbsent {
            let status = SecItemUpdate(query(service, account) as CFDictionary, attributes as CFDictionary)
            if status != errSecItemNotFound { try check(status); return true }
        }
        var item = query(service, account); attributes.forEach { item[$0.key] = $0.value }
        var access: SecAccess?
        try check(SecAccessCreate(label as CFString, nil, &access))
        if let access { item[kSecAttrAccess as String] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        if onlyIfAbsent && status == errSecDuplicateItem { return false }
        try check(status); return true
    }
    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    /// Erase only nonsynchronizing generic passwords in this app's exact service.
    public func deleteAll(service: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
                               kSecMatchLimit as String: kSecMatchLimitAll]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

public struct PasswordStore {
    public let service: String
    public let legacyService: String?
    private let backend: any PasswordBackend
    public init(service: String = AppIdentity.passwordService, legacyService: String? = nil, backend: any PasswordBackend = SystemPasswordBackend()) {
        self.service = service; self.backend = backend
        self.legacyService = legacyService ?? (service == AppIdentity.passwordService ? LegacyCompatibility.passwordService : nil)
    }
    public static func account(for server: Server) -> String {
        let scope = "\(server.id.uuidString)|\(server.host)|\(server.port)|\(server.user)"
        return SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func contains(_ account: String) throws -> Bool {
        if try backend.contains(service: service, account: account) { return true }
        if let legacyService { return try backend.contains(service: legacyService, account: account) }
        return false
    }
    public func readCurrent(_ account: String) throws -> String? { try backend.read(service: service, account: account) }
    public func read(_ account: String) throws -> String? {
        if let current = try readCurrent(account) { return current }
        guard let legacyService, let original = try backend.read(service: legacyService, account: account) else { return nil }
        // Copy only when needed; never erase the previous credential during adoption.
        try write(original, account: account)
        return original
    }
    public func write(_ password: String, account: String) throws {
        guard !password.isEmpty, !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else { throw ValidationError("Enter a nonempty password without line breaks.") }
        try backend.write(password, service: service, account: account, label: "TermiFreedom SSH password", onlyIfAbsent: false)
    }
    public func installationSecret() throws -> Data {
        let account = "authentication-lease-signing-key"
        if let encoded = try readCurrent(account), let bytes = Data(base64Encoded: encoded), bytes.count == 32 { return bytes }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ValidationError("The local authentication key could not be generated.") }
        if try backend.write(bytes.base64EncodedString(), service: service, account: account, label: "TermiFreedom local authentication signing key", onlyIfAbsent: true) { return bytes }
        guard let encoded = try readCurrent(account), let existing = Data(base64Encoded: encoded), existing.count == 32 else { throw ValidationError("The local authentication key could not be read.") }
        return existing
    }
    public func deleteCurrent(_ account: String) throws { try backend.delete(service: service, account: account) }
    public func delete(_ account: String) throws {
        try deleteCurrent(account)
        if let legacyService { try backend.delete(service: legacyService, account: account) }
    }
}

public enum PasswordPrompt {
    public static func matches(_ prompt: String, user: String, host: String) -> Bool {
        guard !user.isEmpty else { return false }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "\(user)@\(host)'s password:"
    }
}
