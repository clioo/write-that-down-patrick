import AppKit
import WriteThatDownKit

/// Application delegate. Configures the process as a menu-bar-only accessory app
/// (LSUIElement equivalent) and boots the composition root on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no main window (mirrors LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        do {
            let environment = try AppEnvironment()
            self.environment = environment
            Task { await environment.run() }
            Log.app.info("Write That Down launched.")
        } catch {
            // Invalid configuration is a hard, visible failure before any
            // operation starts (§11).
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Write That Down — configuration error"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
