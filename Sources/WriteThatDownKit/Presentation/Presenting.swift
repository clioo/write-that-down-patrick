import Foundation

/// Presentation contract driven solely by the orchestrator (§3.1.5/§3.1.6,
/// Appendix A). All methods run on the main actor (AppKit/SwiftUI). The
/// orchestrator awaits these calls; the presentation layer MUST NOT be required
/// for capture or persistence correctness (Appendix A).
@MainActor
public protocol Presenting: AnyObject, Sendable {
    /// Capture is starting — prepare the caption surface (still hidden).
    func sessionWillStart(session: RecordingSession)

    /// Show the live caption surface (§5.2).
    func showCaptions()

    /// Hide the live caption surface (§5.3).
    func hideCaptions()

    /// Show a partial (non-final) hypothesis in captions only (§8.3).
    func showPartial(_ segment: Segment)

    /// Commit a final segment to the live caption history (§14.3 `commit`).
    func commitFinal(_ segment: Segment)

    /// Reflect the current session state in the status surface (§15.5).
    func updateStatus(_ status: SessionStatus, endReason: EndReason?)

    /// Trigger the "call detected and started" notification (§5.2, §16.1).
    func notifyCallStarted(session: RecordingSession)

    /// The transcript document was created or renamed; `path` is its current
    /// absolute location (provisional during recording, final after save).
    func updateTranscriptPath(_ path: String?)

    /// Surface a visible error to the user (§10.2 — never fail silently).
    func presentError(_ message: String)
}
