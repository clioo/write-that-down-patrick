import AppKit

/// Implements `Presenting` (§3.1.5/§3.1.6) by coordinating the caption HUD, the
/// menu-bar status item, and notifications. Driven solely by the orchestrator;
/// holds no session-correctness state of its own (Appendix A).
@MainActor
public final class PresentationCoordinator: Presenting {

    private let captionModel = CaptionModel()
    private let statusModel = StatusModel()
    private let captionSurface: CaptionSurface
    private let statusSurface: StatusSurface
    private let notifications: NotificationService
    private let outputDir: URL

    /// Wired to the orchestrator's manual-stop entry point.
    public var onManualStop: (() -> Void)? {
        didSet { statusSurface.onManualStop = onManualStop }
    }
    /// Wired to the app's quit handler.
    public var onQuit: (() -> Void)? {
        didSet { statusSurface.onQuit = onQuit }
    }

    public init(outputDir: URL, notifications: NotificationService = NotificationService()) {
        self.outputDir = outputDir
        self.notifications = notifications
        self.captionSurface = CaptionSurface(model: captionModel)
        self.statusSurface = StatusSurface(model: statusModel)
        self.statusSurface.onOpenFolder = { [outputDir] in
            NSWorkspace.shared.open(outputDir)
        }
    }

    /// Installs the menu-bar item and requests notification authorization.
    public func install() async {
        statusSurface.install()
        statusSurface.update(status: .idle, endReason: nil, detail: "Waiting for a call…")
        await notifications.requestAuthorization()
    }

    // MARK: Presenting

    public func sessionWillStart(session: RecordingSession) {
        captionSurface.reset()
        captionModel.statusText = "Starting…"
    }

    public func showCaptions() {
        captionSurface.show()
    }

    public func hideCaptions() {
        captionSurface.hide()
    }

    public func showPartial(_ segment: Segment) {
        captionSurface.showPartial(segment.text)
    }

    public func commitFinal(_ segment: Segment) {
        captionSurface.commitFinal(segment)
    }

    public func updateStatus(_ status: SessionStatus, endReason: EndReason?) {
        statusSurface.update(status: status, endReason: endReason, detail: Self.detail(for: status, reason: endReason))
        captionModel.statusText = statusModel.headline
    }

    public func notifyCallStarted(session: RecordingSession) {
        notifications.notifyCallStarted(session: session)
    }

    public func presentError(_ message: String) {
        Log.presentation.error("User-visible error: \(message, privacy: .public)")
        statusSurface.update(status: .failed, endReason: .error, detail: message)
        // Present asynchronously so this awaited call returns immediately: the
        // orchestrator's (off-main) event loop must not be parked on the modal
        // run loop that `runModal()` spins while the alert is on screen.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Write That Down"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func detail(for status: SessionStatus, reason: EndReason?) -> String {
        switch status {
        case .idle:
            if let reason { return "Last session ended (\(reason.rawValue)). Waiting for a call…" }
            return "Waiting for a call…"
        case .detected: return "Call detected — starting capture…"
        case .recording: return "Transcribing this call locally."
        case .finalizing: return "Saving transcript…"
        case .saved: return "Transcript saved."
        case .failed: return "Session failed. See details."
        }
    }
}
