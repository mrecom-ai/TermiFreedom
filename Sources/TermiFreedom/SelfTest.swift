import AppKit
import SwiftTerm
import Darwin
import TermiFreedomCore

@MainActor enum SelfTest {
    static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
    static func run() async {
        var failures: [String] = []
        var results: [String] = []
        func check(_ ok: Bool, _ name: String) {
            if !ok { failures.append(name) }
            let line = "\(ok ? "PASS" : "FAIL"): \(name)"; results.append(line); print(line)
        }
        check(await waitUntil { NSApp.windows.contains { $0.isVisible } }, "App window launched")
        if let icon = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TermiFreedom.icns")) {
            check(icon.isValid, "Native app icon loads")
        } else { check(false, "Native app icon loads") }
        for result in await CredentialChecks.run() { check(result.passed, result.name) }
        for index in 0..<5 {
            var session: Session? = Session(diagnostic: true)
            weak var weakView = session?.terminal
            let pid = session!.terminal!.process.shellPid
            check(pid > 0, "PTY launch \(index)")
            let rendered = await waitUntil { String(decoding: session!.terminal!.getBufferAsData(), as: UTF8.self).contains("TermiFreedom terminal is working.") }
            check(session!.terminal!.process.running, "Local child running \(index)")
            check(rendered, "PTY output rendered \(index)")
            if index == 0 {
                session!.zoom(by: 2); check(session!.terminal!.font.pointSize == 15, "Terminal text zoom")
                session!.resetZoom(); check(session!.terminal!.font.pointSize == 13, "Terminal text zoom reset")
            }
            session!.close(); session = nil
            check(await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }, "Child terminated and reaped \(index)")
            check(weakView == nil, "Terminal view released \(index)")
        }
        var sshVersion: SafeTerminal? = SafeTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        sshVersion!.startProcess(executable: "/usr/bin/ssh", args: ["-V"])
        check(await waitUntil { !sshVersion!.process.running && String(decoding: sshVersion!.getBufferAsData(), as: UTF8.self).contains("OpenSSH") }, "Built-in OpenSSH starts and exits locally")
        sshVersion = nil
        var stubborn: SafeTerminal? = SafeTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        stubborn!.startProcess(executable: "/bin/sh", args: ["-c", "trap '' TERM; printf ready; while :; do :; done"])
        let stubbornPID = stubborn!.process.shellPid
        check(await waitUntil { String(decoding: stubborn!.getBufferAsData(), as: UTF8.self).contains("ready") }, "TERM-resistant test child started")
        stubborn!.terminate(); stubborn = nil
        check(await waitUntil { kill(stubbornPID, 0) == -1 && errno == ESRCH }, "TERM-resistant child escalated and reaped")
        var options = TerminalOptions(scrollback: 2000); options.enableSixelReported = false
        var terminal: SafeTerminal? = SafeTerminal(frame: NSRect(x: 0, y: 0, width: 800, height: 500), options: options)
        terminal!.feed(text: "FIRST-LINE-MARKER\r\n" + String(repeating: "bounded scrollback\r\n", count: 15000) + "LAST-LINE-MARKER\r\n")
        let data = terminal!.getBufferAsData()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").count
        check(lines > 1900 && lines < 2100 && !text.contains("FIRST-LINE-MARKER") && text.contains("LAST-LINE-MARKER"), "Scrollback evicts old lines after 15,000 lines (\(lines) retained)")
        terminal = nil
        print(failures.isEmpty ? "ALL APP CHECKS PASSED" : "FAILED: \(failures.joined(separator: ", "))")
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--report"), args.indices.contains(index + 1) {
            try? (results.joined(separator: "\n") + "\n").write(toFile: args[index + 1], atomically: true, encoding: .utf8)
        }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
