import AppKit
import SwiftUI
import SwiftTerm
import TermiFreedomCore

// OSC clipboard requests from remote hosts are never granted. Normal Cmd-C/V still work.
final class SafeTerminal: LocalProcessTerminalView {
    override func clipboardCopy(source: TerminalView, content: Data) {}
    override func clipboardRead(source: TerminalView) -> Data? { nil }
}

@MainActor final class Session: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let name: String
    private(set) var server: Server?
    private var authentication: AuthenticationContext?
    @Published var status = "Starting…"
    var terminal: SafeTerminal?
    var isRunning: Bool { terminal?.process.running == true || terminal?.process.windingDown == true }
    init(server: Server) throws {
        let args = try server.sshArguments()
        name = server.name
        self.server = server
        super.init()
        authentication = try AuthenticationContext(server: server)
        start(executable: "/usr/bin/ssh", args: args)
    }
    init(diagnostic: Bool, diagnosticServer: Server? = nil) {
        name = "Local terminal check"
        self.server = diagnosticServer
        super.init()
        // Explicitly requested local diagnostic; never creates a network connection.
        start(executable: "/bin/sh", args: ["-c", "printf '\\033[32mTermiFreedom terminal is working.\\033[0m\\r\\nNo server connection was made.\\r\\n'; exec /bin/sleep 600"])
    }
    private func start(executable: String, args: [String]) {
        var options = TerminalOptions(scrollback: 2000)
        options.enableSixelReported = false
        options.kittyGraphics.storageLimitBytesPerScreen = 0
        let view = SafeTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 580), font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.10, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        view.processDelegate = self
        terminal = view
        var env = ProcessInfo.processInfo.environment
        authentication?.environment.forEach { env[$0.key] = $0.value }
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        view.startProcess(executable: executable, args: args, environment: env.map { "\($0.key)=\($0.value)" })
        do { try authentication?.activate(pid: view.process.shellPid); status = "Session open" }
        catch { view.terminate(); status = error.localizedDescription }
    }
    func zoom(by amount: CGFloat) {
        guard let terminal else { return }
        terminal.font = .monospacedSystemFont(ofSize: min(28, max(9, terminal.font.pointSize + amount)), weight: .regular)
    }
    func resetZoom() { terminal?.font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
    func close() {
        guard let view = terminal else { return }
        view.processDelegate = nil
        view.terminate()
        view.removeFromSuperview()
        terminal = nil // LocalProcess deinit closes PTY, reaps and escalates if required.
        authentication = nil
        status = "Closed"
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { authentication = nil; status = exitCode.map { "Exited (\($0))" } ?? "Disconnected" }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) { authentication = nil; status = "Could not start: \(error)" }
}

struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: Session
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let terminal = session.terminal {
            terminal.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminal)
            NSLayoutConstraint.activate([terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor), terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor), terminal.topAnchor.constraint(equalTo: container.topAnchor), terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
