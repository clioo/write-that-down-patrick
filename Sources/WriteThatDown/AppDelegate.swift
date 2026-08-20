import AppKit
import WriteThatDownKit

/// Application delegate. Configures the process as a menu-bar-only accessory app
/// (LSUIElement equivalent) and boots the composition root on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var environment: AppEnvironment?
    private var previewPresenter: PresentationCoordinator?
    private var previewMode: PresentationPreviewMode?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no main window (mirrors LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        if let previewMode = PresentationPreviewMode.current() {
            // Keep screenshot comparisons deterministic and aligned with the
            // approved light mockup without changing the normal app appearance.
            NSApp.appearance = NSAppearance(named: .aqua)
            let presenter = PresentationCoordinator(
                outputDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent("WriteThatDownPreview", isDirectory: true)
            )
            self.previewMode = previewMode
            previewPresenter = presenter
            switch previewMode {
            case .chat:
                presenter.showConversationPreview()
            case .recordingPrompt:
                presenter.showRecordingPromptPreview()
            case .summary:
                presenter.showConversationSummaryPreview()
            }
            return
        }

        do {
            let environment = try AppEnvironment()
            self.environment = environment
            Task { await environment.run() }
            Log.app.notice("Write That Down launched.")
        } catch {
            // Invalid configuration is a hard, visible failure before any
            // operation starts (§11).
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = AppLanguage.current.text(
                "Write That Down — configuration error",
                spanish: "Write That Down — error de configuración"
            )
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: AppLanguage.current.text("Quit", spanish: "Salir"))
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        previewMode != nil
    }

    /// Re-opening the app (Spotlight, Finder, `open`) while it's already
    /// running re-shows the dashboard window instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment?.showMainWindow()
        return false
    }
}
