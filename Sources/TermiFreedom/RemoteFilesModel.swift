import AppKit
import SwiftUI
import TermiFreedomCore

struct FileTransfer: Identifiable {
    let id: UUID
    let name: String
    let direction: String
    var done: UInt64 = 0
    var total: UInt64 = 0
    var status = "Queued"
}

@MainActor final class RemoteFilesModel: ObservableObject {
    let id = UUID()
    let server: Server
    @Published var files: [RemoteFile] = []
    @Published var path = ""
    @Published var pathField = ""
    @Published var home = ""
    @Published var connected = false
    @Published var busy = false
    @Published var message: String?
    @Published var transfers: [FileTransfer] = []
    @Published var selection: Set<String> = []
    private var client: SFTPClient?
    private var authentication: AuthenticationContext?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var testDirectory: URL?
    var hasOpenConnection: Bool { client?.transport.isRunning == true }
    init(server: Server) { self.server = server }
    private func operation(_ work: @escaping (SFTPClient) async throws -> Void) {
        guard !busy, let client else { return }
        busy = true; message = nil
        let token = UUID(); operationID = token
        task = Task {
            defer { busy = false; task = nil; operationID = nil }
            do { try await work(client) }
            catch is CancellationError { message = "Transfer cancelled. Original files were preserved." }
            catch { message = error.localizedDescription; pathField = path }
            if !client.transport.isRunning { connected = false }
        }
    }
    func connect() {
        guard !busy, !connected else { return }
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let transport: SFTPTransport
                if RunMode.uiPreview {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TermiFreedom-files-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: root.appendingPathComponent("Example folder"), withIntermediateDirectories: true)
                    try Data("Local SFTP preview. No network connection was made.\n".utf8).write(to: root.appendingPathComponent("Read me.txt"))
                    testDirectory = root
                    transport = try SFTPTransport(executable: "/usr/libexec/sftp-server", arguments: ["-d", root.path])
                } else {
                    let auth = try AuthenticationContext(server: server, forcePrompt: true)
                    authentication = auth
                    var env = ProcessInfo.processInfo.environment
                    auth.environment.forEach { env[$0.key] = $0.value }
                    transport = try SFTPTransport(executable: "/usr/bin/ssh", arguments: server.sftpArguments(), environment: env)
                    try auth.activate(pid: transport.pid)
                }
                let client = SFTPClient(transport: transport); self.client = client
                try await client.handshake()
                let canonical = try await client.realPath(".")
                home = canonical
                try await load(canonical, using: client)
                connected = true
            } catch {
                client?.disconnect(); client = nil; authentication = nil
                message = error.localizedDescription
            }
        }
    }
    private func load(_ path: String, using client: SFTPClient) async throws {
        let canonical = try await client.realPath(path)
        let entries = try await client.list(canonical)
        self.path = canonical; pathField = canonical; files = entries; selection = []
    }
    func browse(_ path: String) { operation { [weak self] client in try await self?.load(path, using: client) } }
    func enter(_ file: RemoteFile) {
        guard file.isDirectory || file.isLink else { return }
        do { browse(try SFTPClient.childPath(file.name, in: path)) } catch { message = error.localizedDescription }
    }
    func up() {
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        browse("/" + parent)
    }
    func cancel() {
        task?.cancel(); message = "Cancelling…"
        let token = operationID, connection = client
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.busy, self.operationID == token else { return }
            connection?.disconnect()
        }
    }
    func disconnect() {
        task?.cancel(); client?.disconnect(); client = nil; authentication = nil
        connected = false; files = []; selection = []
    }
    func createFolder(_ name: String) {
        do {
            let target = try SFTPClient.childPath(name, in: path)
            operation { [weak self] client in
                try await client.createDirectory(target)
                if let self { try await self.load(self.path, using: client) }
            }
        } catch { message = error.localizedDescription }
    }
    func rename(_ file: RemoteFile, to name: String) {
        do {
            let old = try SFTPClient.childPath(file.name, in: path), new = try SFTPClient.childPath(name, in: path)
            guard !files.contains(where: { $0.name == name }) else { throw SFTPFailure("An entry with that name already exists. Choose a different name.") }
            operation { [weak self] client in
                try await client.rename(old, to: new)
                if let self { try await self.load(self.path, using: client) }
            }
        } catch { message = error.localizedDescription }
    }
    func upload(_ urls: [URL], replacing names: Set<String>) {
        let destination = path
        let jobs = urls.map { FileTransfer(id: UUID(), name: $0.lastPathComponent, direction: "Upload") }
        transfers = Array((transfers + jobs).suffix(50))
        operation { [weak self] client in
            guard let self else { return }
            for (url, job) in zip(urls, jobs) {
                do {
                    try Task.checkCancellation()
                    self.update(job.id, status: "Uploading")
                    let remote = try SFTPClient.childPath(url.lastPathComponent, in: destination)
                    try await client.upload(local: url, remote: remote, replacing: names.contains(url.lastPathComponent)) { [weak self] done, total in
                        Task { @MainActor in self?.update(job.id, done: done, total: total) }
                    }
                    self.update(job.id, status: "Complete")
                } catch {
                    self.update(job.id, status: Task.isCancelled ? "Cancelled" : "Failed")
                    for queued in jobs where self.transfers.first(where: { $0.id == queued.id })?.status == "Queued" { self.update(queued.id, status: "Not started") }
                    throw error
                }
            }
            try await self.load(destination, using: client)
        }
    }
    func download(_ file: RemoteFile, to url: URL) {
        do {
            let remote = try SFTPClient.childPath(file.name, in: path)
            let job = FileTransfer(id: UUID(), name: file.name, direction: "Download")
            transfers = Array((transfers + [job]).suffix(50))
            operation { [weak self] client in
                self?.update(job.id, status: "Downloading")
                do {
                    try await client.download(remote: remote, local: url) { [weak self] done, total in
                        Task { @MainActor in self?.update(job.id, done: done, total: total) }
                    }
                    self?.update(job.id, status: "Complete")
                } catch { self?.update(job.id, status: Task.isCancelled ? "Cancelled" : "Failed"); throw error }
            }
        } catch { message = error.localizedDescription }
    }
    private func update(_ id: UUID, done: UInt64? = nil, total: UInt64? = nil, status: String? = nil) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        if let done { transfers[i].done = done }; if let total { transfers[i].total = total }; if let status { transfers[i].status = status }
    }
    deinit { client?.disconnect(); if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) } }
}
