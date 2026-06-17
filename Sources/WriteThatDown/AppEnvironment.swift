import AppKit
import Foundation
import Speech
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
    private let availableEngineOptions: [TranscriptionEngineOption]
    private let engineSelectionStore: EngineSelectionStore

    init() throws {
        // Validate configuration BEFORE any operation starts (§11).
        self.config = try AppEnvironment.loadConfiguration().validated()
        let discoveredOptions = AppEnvironment.availableTranscriptionOptions(for: config)
        let selectedOption = AppEnvironment.initialSelectedOption(
            configured: TranscriptionEngineOption.from(config),
            available: discoveredOptions
        )
        let selectionStore = EngineSelectionStore(selected: selectedOption)
        self.availableEngineOptions = discoveredOptions
        self.engineSelectionStore = selectionStore

        // Ensure the base output directory exists (date folders are created
        // per-session by the writer, §9.2).
        try? FileManager.default.createDirectory(at: config.outputDir, withIntermediateDirectories: true)

        self.permissions = SystemPermissionManager(requiresSpeech: {
            selectionStore.current.engine == .native
        })
        self.presenter = PresentationCoordinator(outputDir: config.outputDir)
        self.detector = CallDetector(
            pollIntervalMs: config.pollIntervalMs,
            excludedBundleIDs: config.excludedBundleIDs
        )

        let cfg = config
        self.orchestrator = SessionOrchestrator(
            config: cfg,
            detector: detector,
            makeCapturer: { AudioCapturer(config: cfg) },
            makeEngine: { kind in EngineFactory.make(kind, language: cfg.language) },
            makeWriter: { TranscriptWriter(outputDir: cfg.outputDir) },
            engineSelection: { selectionStore.current },
            presenter: presenter,
            permissions: permissions
        )

        Log.app.notice("Configured: engine=\(selectedOption.engine.rawValue, privacy: .public), option=\(selectedOption.title, privacy: .public), outputDir=\(cfg.outputDir.path, privacy: .public).")
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
        presenter.onSelectEngineOption = { [weak self] id in
            Task { await self?.selectEngineOption(id) }
        }
        presenter.setEngineOptions(availableEngineOptions, selectedID: engineSelectionStore.current.id)
        if availableEngineOptions.isEmpty {
            presenter.updateSelectedEngineOption(engineSelectionStore.current, resetHealth: false)
        }
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

    private func selectEngineOption(_ id: String) async {
        guard let option = availableEngineOptions.first(where: { $0.id == id }) else {
            Log.app.error("Ignoring unavailable transcription option id=\(id, privacy: .public).")
            return
        }

        engineSelectionStore.current = option
        presenter.updateSelectedEngineOption(option)
        do {
            try AppEnvironment.persistEngineSelection(option)
            Log.app.notice("Selected transcription option \(option.title, privacy: .public).")
        } catch {
            Log.app.error("Failed to persist transcription option \(option.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if option.engine == .native {
            _ = await permissions.requestAll()
        }
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
        modelLocationDetail(for: TranscriptionEngineOption.from(config))
    }

    static func modelLocationDetail(for option: TranscriptionEngineOption) -> String {
        switch option.engine {
        case .native:
            return option.detail
        case .default:
            if let folder = option.whisperModelFolder {
                return weightsStatus(at: folder) ?? "⚠️ Configured folder not found: \(folder.path)"
            }
            return weightsStatus(at: cachedWhisperModelFolder(for: option.whisperModel))
                ?? "Not downloaded yet — fetched once on first call"
        }
    }

    static func availableTranscriptionOptions(for config: AppConfiguration) -> [TranscriptionEngineOption] {
        var options: [TranscriptionEngineOption] = []
        var seen: Set<String> = []

        func add(_ option: TranscriptionEngineOption) {
            guard !seen.contains(option.id) else { return }
            seen.insert(option.id)
            options.append(option)
        }

        func addWhisperModel(folder: URL) {
            guard let detail = weightsStatus(at: folder), detail.hasPrefix("On disk") else { return }
            let model = folder.lastPathComponent
            add(TranscriptionEngineOption(
                id: TranscriptionEngineOption.whisperID(model: model, folder: folder),
                engine: .default,
                title: TranscriptionEngineOption.whisperTitle(for: model),
                detail: detail,
                whisperModel: model,
                whisperModelFolder: folder
            ))
        }

        if let configuredFolder = config.whisperModelFolder {
            addWhisperModel(folder: configuredFolder)
        }
        addWhisperModel(folder: cachedWhisperModelFolder(for: config.whisperModel))

        if let folders = try? FileManager.default.contentsOfDirectory(
            at: whisperCacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for folder in folders where isDirectory(folder) {
                addWhisperModel(folder: folder)
            }
        }

        if let native = nativeEngineOption(for: config.language) {
            add(native)
        }

        return options.sorted { lhs, rhs in
            if lhs.engine != rhs.engine {
                return lhs.engine == .default
            }
            if lhs.engine == .native {
                return lhs.title < rhs.title
            }
            let lhsRank = whisperSortRank(lhs.whisperModel)
            let rhsRank = whisperSortRank(rhs.whisperModel)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func initialSelectedOption(
        configured: TranscriptionEngineOption,
        available: [TranscriptionEngineOption]
    ) -> TranscriptionEngineOption {
        if let exact = available.first(where: { $0.id == configured.id }) {
            return exact
        }
        if configured.engine == .default,
           let sameModel = available.first(where: {
               $0.engine == .default && $0.whisperModel == configured.whisperModel
           }) {
            return sameModel
        }
        if let sameEngine = available.first(where: { $0.engine == configured.engine }) {
            return sameEngine
        }
        if let firstWhisper = available.first(where: { $0.engine == .default }) {
            return firstWhisper
        }
        return available.first ?? configured
    }

    static var whisperCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
    }

    static func cachedWhisperModelFolder(for model: String) -> URL {
        whisperCacheRoot.appendingPathComponent(model)
    }

    static func weightsStatus(at folder: URL) -> String? {
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

    private static func nativeEngineOption(for language: String) -> TranscriptionEngineOption? {
        let locale = language.lowercased() == "auto" ? Locale.current : Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.supportsOnDeviceRecognition
        else { return nil }
        let identifier = recognizer.locale.identifier
        return TranscriptionEngineOption(
            id: "native:\(identifier)",
            engine: .native,
            title: "Apple Speech",
            detail: "Built into macOS · \(identifier)"
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func whisperSortRank(_ model: String) -> Int {
        let lower = model.lowercased()
        if lower.contains("tiny") { return 0 }
        if lower.contains("base") { return 1 }
        if lower.contains("small") { return 2 }
        if lower.contains("medium") { return 3 }
        if lower.contains("large") { return 4 }
        return 10
    }

    private static func persistEngineSelection(_ option: TranscriptionEngineOption) throws {
        let url = configFileURL
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           let dictionary = parsed as? [String: Any] {
            object = dictionary
        }

        object["engine"] = option.engine.rawValue
        if option.engine == .default {
            object["whisperModel"] = option.whisperModel
            if let folder = option.whisperModelFolder {
                object["whisperModelFolder"] = folder.path
            } else {
                object.removeValue(forKey: "whisperModelFolder")
            }
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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
