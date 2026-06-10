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
    private let mainWindow: MainWindowController
    private let notifications: NotificationService
    private let outputDir: URL

    /// Wired to the orchestrator's manual-stop entry point.
    public var onManualStop: (() -> Void)? {
        didSet {
            statusSurface.onManualStop = onManualStop
            mainWindow.onStop = { [weak self] in self?.onManualStop?() }
        }
    }
    /// Wired to the app's quit handler.
    public var onQuit: (() -> Void)? {
        didSet {
            statusSurface.onQuit = onQuit
            mainWindow.onQuit = { [weak self] in self?.onQuit?() }
        }
    }

    public init(outputDir: URL, notifications: NotificationService = NotificationService()) {
        self.outputDir = outputDir
        self.notifications = notifications
        self.captionSurface = CaptionSurface(model: captionModel)
        self.statusSurface = StatusSurface(model: statusModel)
        self.mainWindow = MainWindowController(statusModel: statusModel, captionModel: captionModel)

        let openFolder: () -> Void = { [outputDir] in
            NSWorkspace.shared.open(outputDir)
        }
        self.statusSurface.onOpenFolder = openFolder
        self.mainWindow.onOpenFolder = openFolder

        // Toggle the caption panel mid-meeting without touching the session.
        // Show-on-start / hide-on-finalize (§15.5) still flow from the orchestrator.
        let toggleCaptions: () -> Void = { [weak self] in
            guard let self else { return }
            if self.captionSurface.isVisible {
                self.captionSurface.hide()
                self.statusModel.captionsVisible = false
            } else {
                self.captionSurface.show()
                self.statusModel.captionsVisible = true
            }
        }
        self.statusSurface.onToggleCaptions = toggleCaptions
        self.mainWindow.onToggleCaptions = toggleCaptions
        // Keep the menu-bar mirror in sync when the user closes the panel via
        // its title-bar X button (that path bypasses the toggle handler).
        self.captionSurface.onUserClosed = { [weak self] in
            self?.statusModel.captionsVisible = false
        }
    }

    /// Installs the menu-bar item and requests notification authorization.
    public func install() async {
        statusSurface.install()
        statusSurface.update(status: .idle, endReason: nil, detail: "Waiting for a call…")
        statusModel.outputDirPath = outputDir.path
        await notifications.requestAuthorization()
    }

    /// Static engine/model info for the popover (set once by the composition
    /// root, which knows the resolved configuration).
    public func setEngineInfo(engineName: String, modelName: String, modelDetail: String) {
        statusModel.engineName = engineName
        statusModel.modelName = modelName
        statusModel.modelDetail = modelDetail
    }

    /// Shows (or brings forward) the desktop dashboard window — called on
    /// launch and whenever the user re-opens the app from Spotlight/Finder.
    public func showMainWindow() {
        mainWindow.show()
    }

    // MARK: Presenting

    /// True between a session attempt starting and returning to idle — used to
    /// tell pipeline failures apart from pre-pipeline permission blocks.
    private var sessionAttempted = false

    public func sessionWillStart(session: RecordingSession) {
        captionSurface.reset()
        statusModel.hasSessionContent = false
        sessionAttempted = true
        captionModel.statusText = "Starting…"
        captionModel.sessionStartedAt = session.startedAt
    }

    public func showCaptions() {
        // Do NOT set statusText here — updateStatus is the single writer.
        captionSurface.show()
        statusModel.captionsVisible = true
    }

    public func hideCaptions() {
        captionSurface.hide()
        statusModel.captionsVisible = false
        captionModel.sessionStartedAt = nil
        // Preserve hasSessionContent so the idle toggle can reopen the panel
        // for review/copy until the next session starts.
    }

    public func showPartial(_ segment: Segment) {
        captionSurface.showPartial(segment.text)
    }

    public func commitFinal(_ segment: Segment) {
        captionSurface.commitFinal(segment)
        statusModel.hasSessionContent = true
    }

    public func updateStatus(_ status: SessionStatus, endReason: EndReason?) {
        if status == .recording {
            // Re-baseline BOTH visible clocks (menu bar + caption header) at
            // recording-ready: model load can take seconds and must not show as
            // pre-elapsed time. This also keeps the clocks consistent with the
            // capture-relative segment offsets in the transcript.
            captionModel.sessionStartedAt = Date()
        }
        statusSurface.update(
            status: status,
            endReason: endReason,
            detail: Self.detail(for: status, reason: endReason),
            recordingSince: status == .recording ? captionModel.sessionStartedAt : nil
        )
        captionModel.statusText = statusModel.headline
        // Pipeline health, derived from session outcomes: reaching Recording
        // proves engine + capture + writer all initialized.
        if status == .recording {
            statusModel.engineHealth = .healthy(Date())
            // Recording also proves the model is on disk now; freshen a stale
            // "not downloaded yet" hint from launch time.
            if statusModel.modelDetail.hasPrefix("Not downloaded") {
                statusModel.modelDetail = "Downloaded · loads offline"
            }
        }
        if status == .idle {
            // Next presentError before any sessionWillStart is a pre-pipeline
            // block (permissions), not an engine failure.
            sessionAttempted = false
        }
    }

    public func notifyCallStarted(session: RecordingSession) {
        notifications.notifyCallStarted(session: session)
    }

    public func updateTranscriptPath(_ path: String?) {
        statusModel.lastTranscriptPath = path
    }

    public func presentError(_ message: String) {
        Log.presentation.error("User-visible error: \(message, privacy: .public)")
        // Permission blocks happen BEFORE any session attempt — the engine was
        // never tested, so don't label it "Failed".
        statusModel.engineHealth = sessionAttempted ? .failed(message) : .blocked(message)
        // Surface via the status item (already done by the caller setting .failed)
        // and a notification banner — both are visible without stealing focus.
        // A modal NSAlert with NSApp.activate would yank keyboard focus away from
        // the meeting app at exactly the wrong moment (spec §10.2 only requires
        // the error be visible, not blocking).
        statusSurface.update(status: .failed, endReason: .error, detail: message)
        notifications.notify(title: "Write That Down — Error", body: message)
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
        case .failed: return "Session failed. Click for details."
        }
    }
}
