import Foundation

/// Selects which transcription engine implementation is used (§11, §8.2).
/// Engine selection is purely runtime configuration — adding/selecting an engine
/// requires no changes outside its own implementation and the factory.
public enum EngineKind: String, Sendable, CaseIterable {
    /// Portable, open-source, fully-offline, multilingual default (WhisperKit).
    case `default`
    /// Optional native on-device engine (SFSpeechRecognizer).
    case native
}

/// Typed configuration with defaults (§11). Implementations MUST validate
/// configuration before operation starts — call ``validated()`` first.
///
/// ## Implementation-defined values (documented per §7.3 / §11)
/// - `sampleRate`: 16 kHz — the rate Whisper-class models expect.
/// - `channelLayout`: mono — system + microphone are down-mixed to one stream.
/// - `sampleFormat`: 32-bit float PCM normalized to [-1, 1].
/// - `captureBufferSeconds`: size of buffers delivered by the capturer (0.1 s).
/// - `transcriptionWindowSeconds`: audio the engine accumulates before running
///   inference, balancing caption latency vs. accuracy (2.0 s).
/// - `activityThresholdRMS`: RMS level below which audio counts as silence for
///   inactivity detection (0.005, ≈ −46 dBFS).
/// - `micInactivityGraceMs`: how long the mic-in-use signal must stay inactive
///   before a session ends with `system_stop` (4000 ms).
/// - `startConfirmMs`: how long the mic-in-use signal must stay active before a
///   session starts — the "confirm window" that ignores brief, non-meeting mic
///   use (3000 ms). 0 = start immediately on mic-on.
public struct AppConfiguration: Sendable, Equatable {

    // MARK: Spec-defined (§11)

    /// `~` is expanded. Default `~/Transcripts`.
    public var outputDir: URL
    /// User's primary language, or `"auto"`. Default: system language.
    public var language: String
    public var engine: EngineKind
    /// Default 900000 (15 minutes).
    public var inactivityTimeoutMs: Int
    /// Default 2000.
    public var pollIntervalMs: Int

    // MARK: Implementation-defined (documented above + in README)

    public var sampleRate: Double
    public var activityThresholdRMS: Float
    public var captureBufferSeconds: Double
    public var transcriptionWindowSeconds: Double
    public var micInactivityGraceMs: Int
    /// How long the microphone-in-use signal must remain active before a session
    /// actually starts (the "confirm window", §5.2). Brief mic use shorter than
    /// this — Siri, dictation, a notification, a device switch — is ignored and
    /// never creates a session, notification, or transcript. Enforced as
    /// `1 + ceil(startConfirmMs / pollIntervalMs)` consecutive active polls (the
    /// first poll is the baseline), guaranteeing at least this much observed
    /// sustained activity. Set to 0 to start immediately on mic-on.
    public var startConfirmMs: Int
    /// Minimum time between session-START attempts after a startup failure
    /// (engine/capture/writer could not initialize). Prevents a persistent
    /// failure from churning — and notifying — on every confirm window while
    /// the mic stays active. The cooldown clears when the mic is released
    /// (a new call retries immediately). 0 = retry on every confirm window.
    public var startRetryCooldownMs: Int
    /// Bundle IDs whose microphone use must NOT count as a call (compared
    /// case-insensitively). Defaults cover terminals and dev tools, so voice
    /// commands to coding agents (Warp/Ghostty/VS Code dictation, etc.) don't
    /// trigger recordings. Per-app attribution requires macOS 14+; on macOS 13
    /// detection falls back to "any mic in use". Setting `excludedApps` in the
    /// config file/env REPLACES this list.
    public var excludedBundleIDs: [String]

    /// Default exclusions: terminals/editors with embedded terminals, OS speech
    /// capture helpers, ScreenCaptureKit's replay daemon, and this app's own
    /// bundle ID. Calls in real meeting apps still count; ambient system services
    /// and our own capture plumbing do not.
    public static let defaultExcludedBundleIDs: [String] = [
        "com.writethatdown.app",
        "com.apple.CoreSpeech",
        "com.apple.replayd",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.anthropic.claudefordesktop",
    ]

    /// WhisperKit model variant for the default engine (e.g. "base", "small").
    public var whisperModel: String
    /// Local model folder for the default engine. When set, the engine loads from
    /// disk and performs NO download — required for a strictly offline install.
    /// When nil, WhisperKit fetches the model on first run (one-time setup only;
    /// audio is never transmitted — see README "Offline & privacy").
    public var whisperModelFolder: URL?

    public init(
        outputDir: URL,
        language: String,
        engine: EngineKind,
        inactivityTimeoutMs: Int,
        pollIntervalMs: Int,
        sampleRate: Double = 16_000,
        activityThresholdRMS: Float = 0.005,
        captureBufferSeconds: Double = 0.1,
        transcriptionWindowSeconds: Double = 2.0,
        micInactivityGraceMs: Int = 4_000,
        startConfirmMs: Int = 3_000,
        startRetryCooldownMs: Int = 60_000,
        excludedBundleIDs: [String] = AppConfiguration.defaultExcludedBundleIDs,
        whisperModel: String = "base",
        whisperModelFolder: URL? = nil
    ) {
        self.outputDir = outputDir
        self.language = language
        self.engine = engine
        self.inactivityTimeoutMs = inactivityTimeoutMs
        self.pollIntervalMs = pollIntervalMs
        self.sampleRate = sampleRate
        self.activityThresholdRMS = activityThresholdRMS
        self.captureBufferSeconds = captureBufferSeconds
        self.transcriptionWindowSeconds = transcriptionWindowSeconds
        self.micInactivityGraceMs = micInactivityGraceMs
        self.startConfirmMs = startConfirmMs
        self.startRetryCooldownMs = startRetryCooldownMs
        self.excludedBundleIDs = excludedBundleIDs
        self.whisperModel = whisperModel
        self.whisperModelFolder = whisperModelFolder
    }

    // MARK: Defaults

    /// Default configuration (§11). `~` is expanded in `outputDir`.
    public static var `default`: AppConfiguration {
        AppConfiguration(
            outputDir: AppConfiguration.expandTilde("~/Transcripts"),
            language: AppConfiguration.systemPrimaryLanguage(),
            engine: .default,
            inactivityTimeoutMs: 900_000,
            pollIntervalMs: 2_000
        )
    }

    // MARK: Validation

    /// Validates the configuration and returns a normalized copy (tilde already
    /// expanded). Throws ``ConfigurationError`` on the first invalid value (§11).
    public func validated() throws -> AppConfiguration {
        if outputDir.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigurationError.emptyOutputDirectory
        }
        if language.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ConfigurationError.emptyLanguage
        }
        if inactivityTimeoutMs <= 0 {
            throw ConfigurationError.nonPositive(field: "inactivity_timeout_ms", value: inactivityTimeoutMs)
        }
        if pollIntervalMs <= 0 {
            throw ConfigurationError.nonPositive(field: "poll_interval_ms", value: pollIntervalMs)
        }
        if micInactivityGraceMs <= 0 {
            throw ConfigurationError.nonPositive(field: "mic_inactivity_grace_ms", value: micInactivityGraceMs)
        }
        if startConfirmMs < 0 {
            throw ConfigurationError.outOfRange(field: "start_confirm_ms", value: Double(startConfirmMs))
        }
        if startRetryCooldownMs < 0 {
            throw ConfigurationError.outOfRange(field: "start_retry_cooldown_ms", value: Double(startRetryCooldownMs))
        }
        if sampleRate <= 0 {
            throw ConfigurationError.outOfRange(field: "sample_rate", value: sampleRate)
        }
        if activityThresholdRMS < 0 || activityThresholdRMS > 1 {
            throw ConfigurationError.outOfRange(field: "activity_threshold_rms", value: Double(activityThresholdRMS))
        }
        if captureBufferSeconds <= 0 {
            throw ConfigurationError.outOfRange(field: "capture_buffer_seconds", value: captureBufferSeconds)
        }
        if transcriptionWindowSeconds <= 0 {
            throw ConfigurationError.outOfRange(field: "transcription_window_seconds", value: transcriptionWindowSeconds)
        }
        return self
    }

    // MARK: Helpers

    /// Expands a leading `~` to the user's home directory (§11).
    public static func expandTilde(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Best-effort system primary language code (e.g. "en"). Used as the default
    /// `language`. Falls back to "en".
    public static func systemPrimaryLanguage() -> String {
        if let code = Locale.preferredLanguages.first {
            // Normalize "en-US" / "en_US" → "en".
            let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            if let base, !base.isEmpty { return base.lowercased() }
        }
        return "en"
    }
}
