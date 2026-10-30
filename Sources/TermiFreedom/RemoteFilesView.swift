import SwiftUI
import AppKit
import TermiFreedomCore

struct RemoteFilesView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: RemoteFilesModel
    @State private var search = ""
    @State private var showHidden = false
    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name)]
    @State private var folderName = ""
    @State private var renameName = ""
    @State private var newFolder = false
    @State private var renaming = false
    @State private var renameTarget: RemoteFile?
    init(server: Server) { _model = StateObject(wrappedValue: RemoteFilesModel(server: server)) }
    var entries: [RemoteFile] {
        let items = model.files.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.sorted(using: sortOrder)
        return items.filter(\.isDirectory) + items.filter { !$0.isDirectory }
    }
    var selected: RemoteFile? { model.files.first { model.selection.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.server.name, systemImage: "externaldrive.connected.to.line.below").font(.headline)
                Text("SFTP").font(.caption.weight(.semibold)).foregroundStyle(.teal)
                Spacer()
                if model.connected { Button("Disconnect") { model.disconnect() }.disabled(model.busy) }
                else { Button("Connect") { model.connect() }.buttonStyle(.borderedProminent).disabled(model.busy) }
            }.padding()
            if model.connected {
                HStack(spacing: 8) {
                    Button { model.browse(model.home) } label: { Image(systemName: "house") }.help("Remote home")
                    Button { model.up() } label: { Image(systemName: "arrow.up") }.help("Parent folder")
                    TextField("Remote folder", text: $model.pathField).onSubmit { model.browse(model.pathField) }.textFieldStyle(.roundedBorder)
                    Button { model.browse(model.path) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                }.padding(.horizontal).padding(.bottom, 12).disabled(model.busy)
                Divider()
                Table(entries, selection: $model.selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { file in
                        Label(file.name, systemImage: file.isDirectory ? "folder.fill" : file.isLink ? "link" : "doc").foregroundStyle(file.isDirectory ? .teal : .primary)
                    }.width(min: 220, ideal: 350)
                    TableColumn("Size", value: \.size) { file in Text(file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)).monospacedDigit() }.width(100)
                    TableColumn("Permissions") { file in Text(file.permissionText).monospaced() }.width(90)
                    TableColumn("Modified") { file in Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—") }.width(min: 150, ideal: 180)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let file = model.files.first(where: { ids.contains($0.id) }) {
                        if file.isDirectory || file.isLink { Button("Open folder") { model.enter(file) }.disabled(model.busy) }
                        if !file.isDirectory && !file.isLink { Button("Download…") { download(file) }.disabled(model.busy) }
                        Button("Rename…") { renameTarget = file; renameName = file.name; renaming = true }.disabled(model.busy)
                    }
                } primaryAction: { ids in
                    if let file = model.files.first(where: { ids.contains($0.id) }), !model.busy { model.enter(file) }
                }
                HStack {
                    TextField("Filter files", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Toggle("Hidden files", isOn: $showHidden).toggleStyle(.checkbox)
                    Spacer()
                    Button("New folder…") { folderName = ""; newFolder = true }.disabled(model.busy)
                    Button("Upload…") { upload() }.disabled(model.busy)
                    Button("Download…") { if let file = selected { download(file) } }.disabled(model.busy || model.selection.count != 1 || selected?.isDirectory != false || selected?.isLink != false)
                }.padding(12)
            } else {
                ContentUnavailableView {
                    Label("Files on \(model.server.name)", systemImage: "folder.badge.gearshape")
                } description: {
                    Text("Browse remote folders and transfer files using OpenSSH and SFTP. Your terminal sessions stay separate.")
                } actions: { Button("Connect to browse files") { model.connect() }.disabled(model.busy) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Text("Working…"); Spacer(); Button("Cancel") { model.cancel() } }.padding(12) }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            if !model.transfers.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.transfers.reversed()) { transfer in
                            HStack {
                                Image(systemName: transfer.direction == "Upload" ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(.teal)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(transfer.name).lineLimit(1)
                                    if transfer.status == "Uploading" || transfer.status == "Downloading" {
                                        ProgressView(value: Double(transfer.done), total: Double(max(1, transfer.total)))
                                    }
                                }
                                Spacer()
                                Text(transfer.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12)
                }.frame(maxHeight: 150)
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        .background(FileWindowGuard(model: model))
        .navigationTitle("\(model.server.name) · Files")
        .onAppear { app.fileBrowsers[model.id] = model }
        .onDisappear { model.disconnect(); app.fileBrowsers[model.id] = nil }
        .alert("New remote folder", isPresented: $newFolder) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { model.createFolder(folderName) }
        }
        .alert("Rename remote entry", isPresented: $renaming) {
            TextField("New name", text: $renameName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let file = renameTarget { model.rename(file, to: renameName) }; renameTarget = nil }
        }
    }
    func upload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "Choose files to upload to \(model.path)."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let names = Set(urls.map(\.lastPathComponent))
        guard names.count == urls.count else { model.message = "Choose files with distinct names for this folder."; return }
        let existing = Set(model.files.map(\.name)).intersection(names)
        if !existing.isEmpty {
            let alert = NSAlert(); alert.messageText = "Replace \(existing.count) existing file(s)?"
            alert.informativeText = existing.sorted().joined(separator: "\n") + "\nExisting files are replaced only after uploads finish successfully."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        model.upload(urls, replacing: existing)
    }
    func download(_ file: RemoteFile) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.name; panel.message = "Save a local copy of \(file.name)."
        if panel.runModal() == .OK, let url = panel.url { model.download(file, to: url) }
    }
}

struct FileWindowGuard: NSViewRepresentable {
    let model: RemoteFilesModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = GuardView()
        view.didAttach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class GuardView: NSView {
        var didAttach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { didAttach?(window) } }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: RemoteFilesModel
        init(model: RemoteFilesModel) { self.model = model }
        func attach(_ window: NSWindow) { window.delegate = self }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model.busy {
                let alert = NSAlert(); alert.messageText = "Stop the file operation and close?"
                alert.informativeText = "Original files are preserved. An interrupted upload may leave a temporary .part file on the server."
                alert.addButton(withTitle: "Keep open"); alert.addButton(withTitle: "Stop and close")
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
            }
            model.disconnect(); return true
        }
    }
}
