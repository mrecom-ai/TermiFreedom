import AppKit
import TermiFreedomCore

@MainActor extension AppModel {
    private var erasureBlocked: Bool {
        sessions.contains { $0.isRunning } || activeInstaller?.busy == true ||
        fileBrowsers.values.contains { $0.hasOpenConnection || $0.busy }
    }

    func confirmEraseLocalData() {
        guard !RunMode.uiPreview, !ProcessInfo.processInfo.arguments.contains("--self-test"),
              ProcessInfo.processInfo.environment["TERMIFREEDOM_DATA_DIR"] == nil else {
            error = "Local data erasure is unavailable in a test or custom-data session."; return
        }
        guard !erasureBlocked else {
            error = "Close terminal connections, disconnect Files windows, and finish or cancel key installation before erasing local data."; return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase local TermiFreedom data?"
        alert.informativeText = "Permanently delete saved servers, app-managed private keys, and TermiFreedom passwords and authentication entries in Keychain. This includes local data retained during the app’s rename.\n\nExternal SSH keys, your SSH configuration, downloaded files, and remote servers are unchanged. Public keys previously installed on servers remain there. Losing an app-managed private key can prevent you from logging in again; keep another way to access your servers.\n\nThis cannot be undone. Type ERASE to confirm. TermiFreedom will quit after cleanup."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        input.placeholderString = "ERASE"
        alert.accessoryView = input
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Erase Local Data")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard input.stringValue == "ERASE" else {
            error = "Nothing was erased. Type ERASE exactly to confirm."; return
        }
        // Modal alerts run a nested event loop; check connection state again.
        guard !erasureBlocked else { error = "A connection became active. Close it before erasing local data."; return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            try LocalDataErasure.erase(in: support) { try SystemPasswordBackend().deleteAll(service: $0) }
            UserDefaults.standard.removePersistentDomain(forName: AppIdentity.bundleIdentifier)
            servers = []; closeAll()
            let done = NSAlert(); done.messageText = "Local data erased"
            done.informativeText = "TermiFreedom will now quit. To uninstall the program, move TermiFreedom from Applications to Trash."
            done.addButton(withTitle: "Quit"); done.runModal()
            NSApp.terminate(nil)
        } catch {
            // Exit even on partial cleanup so stale in-memory records cannot be saved again.
            let failed = NSAlert(); failed.alertStyle = .critical
            failed.messageText = "Cleanup did not finish"
            failed.informativeText = "\(error.localizedDescription) Some data may already have been removed. TermiFreedom will quit; reopen it to retry cleanup."
            failed.addButton(withTitle: "Quit"); failed.runModal(); NSApp.terminate(nil)
        }
    }
}
