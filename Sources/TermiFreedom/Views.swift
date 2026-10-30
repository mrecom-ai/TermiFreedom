import SwiftUI
import AppKit
import TermiFreedomCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedServer: UUID?
    @State private var query = ""
    @State private var editing: Server?
    @State private var closing: Session?
    @State private var deleting: Server?
    @State private var installingKey: Server?
    var filtered: [Server] { model.servers.filter { query.isEmpty || "\($0.name) \($0.host) \($0.group)".localizedCaseInsensitiveContains(query) } }
    var groups: [String] { Set(filtered.map { $0.group }).sorted() }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedServer) {
                    ForEach(groups, id: \.self) { group in
                        Section(group.isEmpty ? "Servers" : group) {
                            ForEach(filtered.filter { $0.group == group }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { server in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(server.name, systemImage: "server.rack").font(.headline)
                                    Text(server.user.isEmpty ? server.host : "\(server.user)@\(server.host)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).tag(server.id)

                            }
                        }
                    }
                }.searchable(text: $query, prompt: "Find a server")
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let server = model.servers.first(where: { ids.contains($0.id) }) {
                        Button("Connect") { model.connect(server) }
                        Button("Browse files…") { openWindow(id: "files", value: server.id) }
                        Button("Edit…") { editing = server }
                        Button("Delete…", role: .destructive) { deleting = server }
                    }
                } primaryAction: { ids in
                    if let server = model.servers.first(where: { ids.contains($0.id) }) { model.connect(server) }
                }
                HStack {
                    Button { editing = Server() } label: { Label("Add server", systemImage: "plus") }
                    Spacer()
                    Text("Local only").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }.navigationTitle("TermiFreedom").navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 350)
        } detail: {
            VStack(spacing: 0) {
                if !model.sessions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(model.sessions) { session in
                                HStack(spacing: 10) {
                                    Button { model.selectedSession = session.id } label: { Label(session.name, systemImage: "terminal").lineLimit(1) }.buttonStyle(.plain)
                                    Button { requestClose(session) } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain).help("Close session")
                                }.padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(model.selectedSession == session.id ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }.padding(6)
                    }
                    Divider()
                    if let session = model.sessions.first(where: { $0.id == model.selectedSession }) {
                        SessionPane(session: session).id(session.id)
                    }
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "terminal.fill").font(.system(size: 52)).foregroundStyle(.teal)
                        Text("Your servers. A quieter home.").font(.largeTitle.weight(.semibold))
                        Text("Save a server, then connect with your Mac’s OpenSSH.\nKeys stay where they are. Everything stays on this Mac.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        HStack {
                            Button("Add server…") { editing = Server() }.buttonStyle(.borderedProminent)
                            Button("Test local terminal") { model.diagnostic() }
                        }
                        Text("2,000 lines of scrollback per tab · Up to 12 tabs").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 600, minHeight: 420)
            .toolbar {
                if let server = model.servers.first(where: { $0.id == selectedServer }) {
                    Button("Files", systemImage: "folder") { openWindow(id: "files", value: server.id) }
                    Button("Edit", systemImage: "pencil") { editing = server }
                    Button("Connect", systemImage: "bolt.fill") { model.connect(server) }.keyboardShortcut(.return, modifiers: .command)
                }
                if let session = model.sessions.first(where: { $0.id == model.selectedSession }), session.isRunning, let snapshot = session.server {
                    Button("Add key to server…", systemImage: "key.fill") { installingKey = snapshot }
                }
                Button { editing = Server() } label: { Label("New server", systemImage: "plus") }.keyboardShortcut("n")
            }
        }
        .sheet(item: $installingKey) { server in InstallKeySheet(server: server) }
        .sheet(item: $editing) { server in ServerEditor(server: server) }
        .alert("TermiFreedom", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("Close session?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("Cancel", role: .cancel) { closing = nil }
            Button("Disconnect", role: .destructive) { if let session = closing { model.close(session) }; closing = nil }
        } message: { Text("This ends the SSH process in this tab. Work running on the server may be interrupted.") }
        .alert("Delete saved server?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let server = deleting { model.delete(server) }; deleting = nil }
        } message: { Text("Only this saved entry will be removed. Open sessions stay open.") }
        .onReceive(NotificationCenter.default.publisher(for: .closeTermiFreedomTab)) { _ in
            if let session = model.sessions.first(where: { $0.id == model.selectedSession }) { requestClose(session) }
        }
    }
    func requestClose(_ session: Session) { if session.isRunning { closing = session } else { model.close(session) } }
}
struct SessionPane: View {
    @ObservedObject var session: Session
    var body: some View {
        VStack(spacing: 0) {
            TerminalHost(session: session)
            HStack { Circle().fill(session.isRunning ? .green : .gray).frame(width: 6, height: 6); Text(session.status); Spacer(); Text("OpenSSH · Local scrollback") }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }
}
struct ServerEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var server: Server
    @State private var error: String?
    @State private var portText = ""
    @State private var password = ""
    @State private var hasPassword = false
    @State private var forgetPassword = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(server.name.isEmpty ? "Add server" : "Edit server").font(.title2.bold())
            Form {
                TextField("Name", text: $server.name)
                TextField("Group", text: $server.group, prompt: Text("Optional"))
                TextField("Host or SSH alias", text: $server.host)
                TextField("Username", text: $server.user, prompt: Text("Use SSH config / current user"))
                TextField("Port", text: $portText)
                SecureField(hasPassword && !forgetPassword ? "Replace saved password" : "Password", text: $password, prompt: Text(hasPassword && !forgetPassword ? "Leave blank to keep saved password" : "Optional · stored in Keychain"))
                if hasPassword {
                    Toggle("Remove saved password", isOn: $forgetPassword)
                }
                HStack {
                    TextField("SSH key path", text: $server.identityFile, prompt: Text("Use SSH agent / defaults"))
                    Button("Choose…") { chooseKey() }
                }
            }.textFieldStyle(.roundedBorder)
            Text("Passwords are saved only in macOS Keychain for this host, port and username. Keys are tried first; the saved password is a fallback. Leave the password blank to keep it. Changing the host, port or username requires saving the password again.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520).onAppear { portText = String(server.port); do { hasPassword = try PasswordStore().contains(PasswordStore.account(for: server)) } catch { self.error = error.localizedDescription } }
    }
    func save() {
        guard let port = Int(portText) else { error = "Enter a numeric port."; return }
        server.port = port
        do { try model.save(server, password: password.isEmpty ? nil : password, forgetPassword: forgetPassword && password.isEmpty); password = ""; dismiss() } catch { self.error = error.localizedDescription }
    }
    func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "Select an existing SSH private key. TermiFreedom stores only its path."
        if panel.runModal() == .OK, let url = panel.url { server.identityFile = url.path }
    }
}
extension Notification.Name { static let closeTermiFreedomTab = Notification.Name("closeTermiFreedomTab") }
