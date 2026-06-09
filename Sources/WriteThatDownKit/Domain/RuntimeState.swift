import Foundation

/// The single authoritative in-memory state owned by the orchestrator (§4.1.5).
/// No component other than `SessionOrchestrator` may mutate this.
public struct RuntimeState: Sendable, Equatable {
    public var sessionStatus: SessionStatus
    public var currentSession: RecordingSession?
    public var lastAudioActivityAt: Date?
    /// Identifier of the active engine.
    public var engineID: String
    public var inactivityTimeoutMs: Int
    public var pollIntervalMs: Int

    public init(
        sessionStatus: SessionStatus = .idle,
        currentSession: RecordingSession? = nil,
        lastAudioActivityAt: Date? = nil,
        engineID: String,
        inactivityTimeoutMs: Int,
        pollIntervalMs: Int
    ) {
        self.sessionStatus = sessionStatus
        self.currentSession = currentSession
        self.lastAudioActivityAt = lastAudioActivityAt
        self.engineID = engineID
        self.inactivityTimeoutMs = inactivityTimeoutMs
        self.pollIntervalMs = pollIntervalMs
    }
}
