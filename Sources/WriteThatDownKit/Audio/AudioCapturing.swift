import Foundation

/// Errors surfaced by the capture layer (§10.1 Capture Failures).
public enum CaptureError: Error, LocalizedError {
    case systemAudioUnavailable(String)
    case microphoneUnavailable(String)
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .systemAudioUnavailable(m): return "System audio capture failed: \(m)"
        case let .microphoneUnavailable(m): return "Microphone capture failed: \(m)"
        case let .startFailed(m): return "Audio capture could not start: \(m)"
        }
    }
}

/// Contract for the Audio Capturer (§3.1.2). Captures system + microphone audio,
/// down-mixes to a normalized stream, and delivers `AudioBuffer`s via `onBuffer`.
///
/// The orchestrator provides the delivery closure at `start`; buffers may be
/// delivered from an arbitrary thread, so the closure is `@Sendable`.
public protocol AudioCapturing: AnyObject, Sendable {
    /// Opens system + microphone capture. The closure is invoked for every
    /// delivered buffer until `stop()` is called. Throws ``CaptureError`` if a
    /// source cannot be opened (§10.2 — capture failure → session fails).
    func start(onBuffer: @escaping @Sendable (AudioBuffer) -> Void) async throws

    /// Closes all capture sources. Safe to call multiple times.
    func stop() async
}
