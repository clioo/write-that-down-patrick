import Foundation

/// Initialization parameters handed to an engine at `start` (§8.1).
public struct EngineConfig: Sendable, Equatable {
    /// BCP-47-ish language code (e.g. "en") or "auto" for detection.
    public let language: String
    /// Sample rate of buffers that will be pushed (Hz). Default 16 kHz.
    public let sampleRate: Double
    /// Number of accumulated audio seconds before the engine runs inference,
    /// balancing caption latency against accuracy (§7.2).
    public let windowSeconds: Double
    /// Engine-specific model identifier (e.g. WhisperKit "base").
    public let model: String
    /// Optional local model folder. When set, the engine MUST NOT download
    /// (strictly-offline operation).
    public let modelFolder: URL?

    public init(
        language: String,
        sampleRate: Double,
        windowSeconds: Double,
        model: String,
        modelFolder: URL?
    ) {
        self.language = language
        self.sampleRate = sampleRate
        self.windowSeconds = windowSeconds
        self.model = model
        self.modelFolder = modelFolder
    }
}

/// Errors raised by a transcription engine (§10.1 Engine Failures).
public enum EngineError: Error, LocalizedError {
    case initializationFailed(String)
    case transcriptionFailed(String)
    case notStarted

    public var errorDescription: String? {
        switch self {
        case let .initializationFailed(m): return "Transcription engine failed to initialize: \(m)"
        case let .transcriptionFailed(m): return "Transcription failed: \(m)"
        case .notStarted: return "Transcription engine used before start()."
        }
    }
}

/// The swappable transcription engine contract (§8.1). The rest of the
/// application interacts ONLY with this protocol and MUST NOT depend on any
/// concrete engine (§8). Adding a new engine requires no changes outside its own
/// implementation (and the small `EngineFactory` that maps config → engine).
///
/// ## Segment authorship convention
/// An engine fills `text`, `isFinal`, and its best-effort session-relative
/// `timestamp` (it knows elapsed audio from samples pushed since `start`). The
/// `index` it sets is advisory; the orchestrator assigns the authoritative
/// monotonic `index` (§4.1.3) when persisting final segments.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Stable engine identifier (e.g. "whisperkit", "native-sfspeech"). Surfaced
    /// in `RuntimeState.engineID`.
    var id: String { get }

    /// Initializes the engine; MAY incur an initial model-load cost (§8.1).
    func start(_ config: EngineConfig) async throws

    /// Receives audio and returns zero or more segments, partial or final (§8.1).
    func push(_ buffer: AudioBuffer) async throws -> [Segment]

    /// Flushes and returns any pending final segments (§8.1).
    func stop() async throws -> [Segment]
}
