import SwiftUI
import TermiFreedomCore

@MainActor final class AppModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var sessions: [Session] = []
    @Published var selectedSession: UUID?
    @Published var error: String?
    var fileBrowsers: [UUID: RemoteFilesModel] = [:]
    weak var activeInstaller: KeyInstaller?
    private var canSave = true
    let store: ServerStore
    init() {
        let base: URL
        if ProcessInfo.processInfo.arguments.contains("--self-test") || RunMode.uiPreview { base = FileManager.default.temporaryDirectory.appendingPathComponent("TermiFreedomSelfTest-\(ProcessInfo.processInfo.processIdentifier)") }
        else if let path = ProcessInfo.processInfo.environment["TERMIFREEDOM_DATA_DIR"] { base = URL(fileURLWithPath: path) }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            do { base = try LocalDataMigration.prepare(in: support) }
            catch {
                store = ServerStore(url: support.appendingPathComponent(AppIdentity.dataDirectoryName).appendingPathComponent("servers.json"))
                canSave = false; self.error = "The previous data could not be copied. Your original data is unchanged. \(error.localizedDescription)"; return
            }
        }
        store = ServerStore(url: base.appendingPathComponent("servers.json"))
        if RunMode.uiPreview { servers = [Server(name: "Double-click check", host: "example.invalid", user: "test")]; return }
        do { servers = try store.load() } catch { canSave = false; self.error = "Saved servers could not be read. The file will not be overwritten. \(error.localizedDescription)" }
    }
    func save(_ server: Server, password: String? = nil, forgetPassword: Bool = false) throws {
        guard canSave else { throw ValidationError("Resolve the saved-data error before making changes.") }
        _ = try server.validated()
        var updated = servers
        if let i = updated.firstIndex(where: { $0.id == server.id }) { updated[i] = server } else { updated.append(server) }
        let passwords = PasswordStore(), account = PasswordStore.account(for: server)
        let changingPassword = password != nil
        let oldPassword = changingPassword ? try passwords.readCurrent(account) : nil
        if let password { try passwords.write(password, account: account) }
        do { try store.save(updated) } catch {
            if changingPassword {
                if let oldPassword { try? passwords.write(oldPassword, account: account) }
                else { try? passwords.deleteCurrent(account) }
            }
            throw error
        }
        let previous = servers.first { $0.id == server.id }
        servers = updated
        if forgetPassword && password == nil { try passwords.delete(account) }
        if let previous, PasswordStore.account(for: previous) != account {
            do { try passwords.delete(PasswordStore.account(for: previous)) }
            catch { self.error = "Server saved. Its old password could not be removed from Keychain: \(error.localizedDescription)" }
        }
    }
    func delete(_ server: Server) {
        guard canSave else { return }
        let updated = servers.filter { $0.id != server.id }
        do { try store.save(updated); servers = updated; try PasswordStore().delete(PasswordStore.account(for: server)) } catch { self.error = error.localizedDescription }
    }
    func connect(_ server: Server) {
        guard sessions.count < 12 else { error = "Close a tab before opening another (12-tab limit)."; return }
        do { let session = RunMode.uiPreview ? Session(diagnostic: true, diagnosticServer: server) : try Session(server: server); sessions.append(session); selectedSession = session.id } catch { self.error = error.localizedDescription }
    }
    func diagnostic() {
        guard sessions.count < 12 else { return }
        let session = Session(diagnostic: true); sessions.append(session); selectedSession = session.id
    }
    func close(_ session: Session) {
        session.close(); sessions.removeAll { $0.id == session.id }
        if selectedSession == session.id { selectedSession = sessions.last?.id }
    }
    func closeAll() { fileBrowsers.values.forEach { $0.disconnect() }; sessions.forEach { $0.close() }; sessions = []; selectedSession = nil }
}
