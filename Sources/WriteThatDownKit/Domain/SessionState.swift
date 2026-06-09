import Foundation

/// Session orchestration state (§6.1). The orchestrator is the only component
/// that mutates this value.
public enum SessionStatus: String, Sendable, Equatable, CaseIterable {
    /// No active session. The service observes the detection signal.
    case idle
    /// Microphone activity observed; capture startup is in progress.
    case detected
    /// Capture and transcription are active; segments are emitted.
    case recording
    /// Capture stopped; final segments are written and the document is closed.
    case finalizing
    /// The document was persisted; the session is terminal.
    case saved
    /// A failure prevented completing the session. The partial document is kept.
    case failed
}

/// Why a session ended (§4.1.1 `end_reason`).
public enum EndReason: String, Sendable, Equatable, CaseIterable {
    /// Audio level stayed below threshold for `inactivity_timeout_ms` (§7.3).
    case inactivity
    /// The user requested a manual stop.
    case manual
    /// A failure ended the session.
    case error
    /// The microphone-in-use signal became inactive in a sustained manner (§5.3).
    case systemStop = "system_stop"
}
