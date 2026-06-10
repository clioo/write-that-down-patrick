import Foundation

/// A set of optional configuration overrides from one source — the JSON config
/// file or the `WTD_*` environment variables. Decoding/parsing and applying are
/// pure and live here in the Kit so they are unit-testable; reading the file
/// and the process environment stays in the app layer (the composition root).
public struct ConfigOverrides: Decodable, Sendable, Equatable {
    public var outputDir: String?
    public var language: String?
    public var engine: String?
    public var inactivityTimeoutMs: Int?
    public var pollIntervalMs: Int?
    public var startConfirmMs: Int?
    public var startRetryCooldownMs: Int?
    public var whisperModel: String?
    public var whisperModelFolder: String?

    public init(
        outputDir: String? = nil,
        language: String? = nil,
        engine: String? = nil,
        inactivityTimeoutMs: Int? = nil,
        pollIntervalMs: Int? = nil,
        startConfirmMs: Int? = nil,
        startRetryCooldownMs: Int? = nil,
        whisperModel: String? = nil,
        whisperModelFolder: String? = nil
    ) {
        self.outputDir = outputDir
        self.language = language
        self.engine = engine
        self.inactivityTimeoutMs = inactivityTimeoutMs
        self.pollIntervalMs = pollIntervalMs
        self.startConfirmMs = startConfirmMs
        self.startRetryCooldownMs = startRetryCooldownMs
        self.whisperModel = whisperModel
        self.whisperModelFolder = whisperModelFolder
    }

    /// Decodes the JSON config-file format. Throws on malformed JSON or
    /// wrong-typed values so the caller can surface the problem loudly instead
    /// of silently running on defaults.
    public static func decode(fromJSON data: Data) throws -> ConfigOverrides {
        try JSONDecoder().decode(ConfigOverrides.self, from: data)
    }

    /// Extracts overrides from `WTD_*` environment variables. Integer variables
    /// that are present but unparsable are skipped and reported in `warnings`
    /// rather than silently dropped.
    public static func fromEnvironment(
        _ env: [String: String]
    ) -> (overrides: ConfigOverrides, warnings: [String]) {
        var warnings: [String] = []
        func int(_ key: String) -> Int? {
            guard let raw = env[key], !raw.isEmpty else { return nil }
            guard let value = Int(raw) else {
                warnings.append("\(key)='\(raw)' is not an integer and was ignored.")
                return nil
            }
            return value
        }
        let overrides = ConfigOverrides(
            outputDir: env["WTD_OUTPUT_DIR"],
            language: env["WTD_LANGUAGE"],
            engine: env["WTD_ENGINE"],
            inactivityTimeoutMs: int("WTD_INACTIVITY_TIMEOUT_MS"),
            pollIntervalMs: int("WTD_POLL_INTERVAL_MS"),
            startConfirmMs: int("WTD_START_CONFIRM_MS"),
            startRetryCooldownMs: int("WTD_START_RETRY_COOLDOWN_MS"),
            whisperModel: env["WTD_WHISPER_MODEL"],
            whisperModelFolder: env["WTD_WHISPER_MODEL_FOLDER"]
        )
        return (overrides, warnings)
    }
}

extension AppConfiguration {
    /// Returns a copy with the non-nil override values applied. This is the
    /// single source of truth for override semantics — tilde expansion,
    /// empty-string rejection, engine-string parsing — shared by the config
    /// file and the environment so the two sources cannot drift. A present but
    /// unrecognized engine value is kept out and reported in `warnings` rather
    /// than silently dropped.
    public func applying(_ overrides: ConfigOverrides) -> (config: AppConfiguration, warnings: [String]) {
        var config = self
        var warnings: [String] = []
        if let v = overrides.outputDir, !v.isEmpty {
            config.outputDir = AppConfiguration.expandTilde(v)
        }
        if let v = overrides.language, !v.isEmpty {
            config.language = v
        }
        if let v = overrides.engine, !v.isEmpty {
            if let engine = EngineKind(rawValue: v) {
                config.engine = engine
            } else {
                let valid = EngineKind.allCases.map(\.rawValue).joined(separator: ", ")
                warnings.append("Unknown engine '\(v)' (valid: \(valid)); keeping '\(config.engine.rawValue)'.")
            }
        }
        if let v = overrides.inactivityTimeoutMs { config.inactivityTimeoutMs = v }
        if let v = overrides.pollIntervalMs { config.pollIntervalMs = v }
        if let v = overrides.startConfirmMs { config.startConfirmMs = v }
        if let v = overrides.startRetryCooldownMs { config.startRetryCooldownMs = v }
        if let v = overrides.whisperModel, !v.isEmpty {
            config.whisperModel = v
        }
        if let v = overrides.whisperModelFolder, !v.isEmpty {
            config.whisperModelFolder = AppConfiguration.expandTilde(v)
        }
        return (config, warnings)
    }
}
