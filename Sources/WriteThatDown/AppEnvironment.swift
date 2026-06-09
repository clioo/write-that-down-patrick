import AppKit
import Foundation
import WriteThatDownKit

/// Composition root (§3.1). Loads + validates configuration, constructs every
/// component, injects the engine/capturer/writer factories into the orchestrator,
/// and starts observing. The orchestrator remains the single state authority; this
/// type only wires dependencies.
@MainActor
final class AppEnvironment {

    let config: AppConfiguration
    private let presenter: PresentationCoordinator
    private let permissions: SystemPermissionManager
    private let detector: CallDetector
    private let orchestrator: SessionOrchestrator

    init() throws {
        // Validate configuration BEFORE any operation starts (§11).
        self.config = try AppEnvironment.loadConfiguration().validated()

        // Ensure the base output directory exists (date folders are created
        // per-session by the writer, §9.2).
        try? FileManager.default.createDirectory(at: config.outputDir, withIntermediateDirectories: true)

        self.permissions = SystemPermissionManager(requiresSpeech: config.engine == .native)
        self.presenter = PresentationCoordinator(outputDir: config.outputDir)
        self.detector = CallDetector(pollIntervalMs: config.pollIntervalMs)

        let cfg = config
        self.orchestrator = SessionOrchestrator(
            config: cfg,
            detector: detector,
            makeCapturer: { AudioCapturer(config: cfg) },
            makeEngine: { EngineFactory.make(cfg.engine, language: cfg.language) },
            makeWriter: { TranscriptWriter(outputDir: cfg.outputDir) },
            presenter: presenter,
            permissions: permissions
        )

        Log.app.info("Configured: engine=\(cfg.engine.rawValue, privacy: .public), outputDir=\(cfg.outputDir.path, privacy: .public).")
    }

    /// Requests permissions on first launch (§12), installs the UI, then starts
    /// the orchestrator's event loop (this call does not return until shutdown).
    func run() async {
        _ = await permissions.requestAll()
        await presenter.install()

        let orchestrator = self.orchestrator
        presenter.onManualStop = { orchestrator.requestManualStop() }
        presenter.onQuit = { orchestrator.requestShutdown() }

        // Returns only once the event loop ends (after `requestShutdown()` has
        // finalized any in-progress session); then terminate the app.
        await orchestrator.start()
        NSApp.terminate(nil)
    }

    // MARK: - Configuration loading (defaults + environment overrides)

    /// Builds configuration from §11 defaults, then applies (in increasing
    /// precedence) a JSON config file and environment variables. The config file
    /// is the durable mechanism for GUI launches, which do not inherit `WTD_*`
    /// env vars.
    static func loadConfiguration() -> AppConfiguration {
        var config = AppConfiguration.default
        applyConfigFile(&config)     // file overrides built-in defaults
        applyEnvironment(&config)    // env overrides file
        return config
    }

    /// `~/Library/Application Support/WriteThatDown/config.json`
    static var configFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? AppConfiguration.expandTilde("~/Library/Application Support")
        return base.appendingPathComponent("WriteThatDown/config.json", isDirectory: false)
    }

    /// Optional JSON config; all keys optional. Mirrors the env-var overrides.
    private struct FileConfig: Decodable {
        var outputDir: String?
        var language: String?
        var engine: String?
        var inactivityTimeoutMs: Int?
        var pollIntervalMs: Int?
        var whisperModel: String?
        var whisperModelFolder: String?
    }

    private static func applyConfigFile(_ config: inout AppConfiguration) {
        let url = configFileURL
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FileConfig.self, from: data)
        else { return }
        if let v = file.outputDir, !v.isEmpty { config.outputDir = AppConfiguration.expandTilde(v) }
        if let v = file.language, !v.isEmpty { config.language = v }
        if let v = file.engine, let e = EngineKind(rawValue: v) { config.engine = e }
        if let v = file.inactivityTimeoutMs { config.inactivityTimeoutMs = v }
        if let v = file.pollIntervalMs { config.pollIntervalMs = v }
        if let v = file.whisperModel, !v.isEmpty { config.whisperModel = v }
        if let v = file.whisperModelFolder, !v.isEmpty { config.whisperModelFolder = AppConfiguration.expandTilde(v) }
        Log.app.info("Applied config file at \(url.path, privacy: .public).")
    }

    private static func applyEnvironment(_ config: inout AppConfiguration) {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["WTD_OUTPUT_DIR"], !dir.isEmpty {
            config.outputDir = AppConfiguration.expandTilde(dir)
        }
        if let lang = env["WTD_LANGUAGE"], !lang.isEmpty {
            config.language = lang
        }
        if let engineRaw = env["WTD_ENGINE"], let engine = EngineKind(rawValue: engineRaw) {
            config.engine = engine
        }
        if let raw = env["WTD_INACTIVITY_TIMEOUT_MS"], let value = Int(raw) {
            config.inactivityTimeoutMs = value
        }
        if let raw = env["WTD_POLL_INTERVAL_MS"], let value = Int(raw) {
            config.pollIntervalMs = value
        }
        if let model = env["WTD_WHISPER_MODEL"], !model.isEmpty {
            config.whisperModel = model
        }
        if let folder = env["WTD_WHISPER_MODEL_FOLDER"], !folder.isEmpty {
            config.whisperModelFolder = AppConfiguration.expandTilde(folder)
        }
    }
}
