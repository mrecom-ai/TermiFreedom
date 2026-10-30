import SwiftUI
import AppKit
import TermiFreedomCore

struct TermiFreedomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("TermiFreedom", id: "main") {
            ContentView().environmentObject(model).frame(minWidth: 880, minHeight: 540)
                .onAppear { delegate.prepare(model) }
        }.defaultSize(width: 1140, height: 740)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Erase Local TermiFreedom Data…") { model.confirmEraseLocalData() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Close Session") { NotificationCenter.default.post(name: .closeTermiFreedomTab, object: nil) }.keyboardShortcut("w")
                Button("Test Local Terminal") { model.diagnostic() }
            }
            CommandMenu("Terminal") {
                Button("Larger Text") { model.sessions.first { $0.id == model.selectedSession }?.zoom(by: 1) }.keyboardShortcut("=")
                Button("Smaller Text") { model.sessions.first { $0.id == model.selectedSession }?.zoom(by: -1) }.keyboardShortcut("-")
                Button("Reset Text Size") { model.sessions.first { $0.id == model.selectedSession }?.resetZoom() }.keyboardShortcut("0")
            }
            CommandGroup(after: .help) {
                Button("Port forwarding explained") {
                    let alert = NSAlert(); alert.messageText = "What is port forwarding?"
                    alert.informativeText = "An SSH tunnel carries traffic for another app through your secure server connection.\n\nLocal forwarding lets a Mac app reach a private service on or behind the server—for example, a database. The service can remain closed to the public internet.\n\nRemote forwarding exposes a service from your Mac through a server. A SOCKS tunnel lets compatible apps route connections through the server. These can expose services if configured incorrectly.\n\nTermiFreedom does not create tunnels in this version. A future tunnel manager will start with local forwarding bound only to your Mac’s loopback address."
                    alert.addButton(withTitle: "Got it"); alert.runModal()
                }
            }
        }
        WindowGroup("Files", id: "files", for: UUID.self) { $serverID in
            if let serverID, let server = model.servers.first(where: { $0.id == serverID }) {
                RemoteFilesView(server: server).environmentObject(model)
            } else { Text("Choose a saved server to browse files.").padding(40) }
        }.defaultSize(width: 1000, height: 700)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    private var prepared = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func prepare(_ model: AppModel) {
        self.model = model
        guard !prepared else { return }; prepared = true
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.canBecomeMain })?.delegate = self
            if ProcessInfo.processInfo.arguments.contains("--self-test") {
                Task { await SelfTest.run() }
            } else if ProcessInfo.processInfo.arguments.contains("--demo") { self.model?.diagnostic() }
        }
    }
    func confirmDisconnect() -> Bool {
        guard model?.sessions.contains(where: { $0.isRunning }) == true || model?.activeInstaller?.busy == true || model?.fileBrowsers.values.contains(where: { $0.hasOpenConnection || $0.busy }) == true else { return true }
        let alert = NSAlert(); alert.messageText = "Disconnect open sessions?"
        alert.informativeText = "Closing TermiFreedom ends its SSH processes and file connections, and cancels any key installation. Work running on servers may be interrupted; a key already accepted by a server may remain installed."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Disconnect")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmDisconnect() else { return false }
        model?.activeInstaller?.cancel(); model?.closeAll(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard confirmDisconnect() else { return .terminateCancel }
        model?.activeInstaller?.cancel(); model?.closeAll(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
