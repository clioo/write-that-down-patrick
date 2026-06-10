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

        Log.app.notice("Configured: engine=\(cfg.engine.rawValue, privacy: .public), outputDir=\(cfg.outputDir.path, privacy: .public).")
    }

    /// Installs the UI FIRST (the menu-bar icon must appear even if a TCC
    /// permission prompt stalls unanswered), then requests permissions (§12)
    /// and starts the orchestrator's event loop (does not return until shutdown).
    func run() async {
        // Wire EVERYTHING synchronous first — engine info and the popover's
        // Stop/Quit actions must work the instant the icon appears, even while
        // a permission prompt is stalled unanswered.
        let orchestrator = self.orchestrator
        presenter.onManualStop = { orchestrator.requestManualStop() }
        presenter.onQuit = { orchestrator.requestShutdown() }
        presenter.setEngineInfo(
            engineName: config.engine == .native ? "Apple Speech (on-device)" : "WhisperKit (local)",
            modelName: config.engine == .native ? "macOS dictation model" : config.whisperModel,
            modelDetail: AppEnvironment.modelLocationDetail(for: config)
        )
        await presenter.install()
        // The app is not menu-bar-only: show the dashboard window on launch
        // (and AppDelegate re-shows it when the user re-opens the app).
        presenter.showMainWindow()
        _ = await permissions.requestAll()

        // Returns only once the event loop ends (after `requestShutdown()` has
        // finalized any in-progress session); then terminate the app.
        await orchestrator.start()
        NSApp.terminate(nil)
    }

    /// Re-shows the dashboard window (user re-opened the app while running).
    func showMainWindow() {
        presenter.showMainWindow()
    }

    // MARK: - Configuration loading (defaults + environment overrides)

    /// Builds configuration from §11 defaults, then applies (in increasing
    /// precedence) the JSON config file and `WTD_*` environment variables. The
    /// config file is the durable mechanism for GUI launches, which do not
    /// inherit env vars. Override SEMANTICS (tilde expansion, engine parsing,
    /// empty-string rejection) live in `ConfigOverrides`/`applying(_:)` in the
    /// Kit, where they are unit-tested; this layer only does the I/O.
    static func loadConfiguration() -> AppConfiguration {
        var config = AppConfiguration.default

        // 1. Config file (overrides built-in defaults). A MISSING file is the
        //    normal case; a file that exists but fails to parse must not be
        //    silently ignored — the user wrote it expecting it to apply.
        let url = configFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let overrides = try ConfigOverrides.decode(fromJSON: data)
                let (applied, warnings) = config.applying(overrides)
                config = applied
                warn(warnings, source: url.path)
                Log.app.notice("Applied config file at \(url.path, privacy: .public).")
            } catch {
                Log.app.error("Config file at \(url.path, privacy: .public) is invalid and was IGNORED: \(error.localizedDescription, privacy: .public)")
                FileHandle.standardError.write(Data("warning: invalid config file ignored (\(url.path)): \(error.localizedDescription)\n".utf8))
            }
        }

        // 2. Environment (overrides the file).
        let (envOverrides, parseWarnings) = ConfigOverrides.fromEnvironment(ProcessInfo.processInfo.environment)
        let (applied, applyWarnings) = config.applying(envOverrides)
        config = applied
        warn(parseWarnings + applyWarnings, source: "environment")
        return config
    }

    /// Human-readable description of where the model will load from and whether
    /// it is actually usable — surfaces the Git-LFS-pointer trap directly in
    /// the menu-bar popover instead of failing at first call.
    static func modelLocationDetail(for config: AppConfiguration) -> String {
        if config.engine == .native { return "Built into macOS — no download" }

        func weightsStatus(at folder: URL) -> String? {
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            var total: Int64 = 0
            var fileCount = 0
            var enumerationFailed = false
            let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [],
                errorHandler: { _, _ in enumerationFailed = true; return true }
            )
            var sampleWeightFile: URL?
            if let files = enumerator {
                for case let f as URL in files {
                    fileCount += 1
                    total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    if f.lastPathComponent == "weight.bin", sampleWeightFile == nil { sampleWeightFile = f }
                }
            }
            if enumerationFailed || fileCount == 0 {
                // Denied/empty enumeration must not masquerade as a diagnosis.
                return "Model folder present — could not verify contents"
            }
            // Real CoreML weights are tens of MB minimum.
            if total > 5_000_000 {
                let mb = Double(total) / 1_048_576
                return String(format: "On disk · %.0f MB · loads offline", mb)
            }
            // Tiny total: check for the literal Git LFS pointer signature before
            // claiming stubs; otherwise just report what we see.
            if let wf = sampleWeightFile,
               let head = try? FileHandle(forReadingFrom: wf).read(upToCount: 40),
               String(data: head, encoding: .utf8)?.hasPrefix("version https://git-lfs") == true {
                return "⚠️ Folder holds Git LFS pointer stubs, not weights"
            }
            return "⚠️ Folder exists but looks incomplete (only \(fileCount) small files)"
        }

        if let folder = config.whisperModelFolder {
            return weightsStatus(at: folder) ?? "⚠️ Configured folder not found: \(folder.path)"
        }
        // Default download cache used by WhisperKit.
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(config.whisperModel)
        return weightsStatus(at: cache) ?? "Not downloaded yet — fetched once on first call"
    }

    /// `~/Library/Application Support/WriteThatDown/config.json`
    static var configFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? AppConfiguration.expandTilde("~/Library/Application Support")
        return base.appendingPathComponent("WriteThatDown/config.json", isDirectory: false)
    }

    /// Surfaces override warnings (unknown engine string, unparsable integer)
    /// loudly — log + stderr — instead of dropping values silently.
    private static func warn(_ warnings: [String], source: String) {
        for warning in warnings {
            Log.app.warning("Config (\(source, privacy: .public)): \(warning, privacy: .public)")
            FileHandle.standardError.write(Data("warning: config (\(source)): \(warning)\n".utf8))
        }
    }
}
