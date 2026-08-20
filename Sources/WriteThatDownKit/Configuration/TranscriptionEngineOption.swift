import Foundation

/// A transcription runtime shown in Settings. Downloadable catalog entries may
/// be present before installation; `ModelInstallState` gates actual selection.
public struct TranscriptionEngineOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let engine: EngineKind
    public let title: String
    public let detail: String
    public let whisperModel: String
    public let whisperModelFolder: URL?
    public let summary: String
    public let sizeBytes: Int64?
    public let isRecommended: Bool
    public let isStreaming: Bool
    public let isDownloadable: Bool

    public init(
        id: String,
        engine: EngineKind,
        title: String,
        detail: String,
        whisperModel: String = "",
        whisperModelFolder: URL? = nil,
        summary: String = "",
        sizeBytes: Int64? = nil,
        isRecommended: Bool = false,
        isStreaming: Bool = false,
        isDownloadable: Bool = false
    ) {
        self.id = id
        self.engine = engine
        self.title = title
        self.detail = detail
        self.whisperModel = whisperModel
        self.whisperModelFolder = whisperModelFolder
        self.summary = summary
        self.sizeBytes = sizeBytes
        self.isRecommended = isRecommended
        self.isStreaming = isStreaming
        self.isDownloadable = isDownloadable
    }

    /// Engine-neutral aliases retained alongside the original Whisper-specific
    /// storage so the orchestration contract can configure any local backend.
    public var model: String { whisperModel }
    public var modelFolder: URL? { whisperModelFolder }

    public static func from(_ config: AppConfiguration) -> TranscriptionEngineOption {
        switch config.engine {
        case .native:
            return TranscriptionEngineOption(
                id: "native",
                engine: .native,
                title: "Apple Speech",
                detail: "Built into macOS",
                summary: "Uses Apple's on-device dictation model for the selected language."
            )
        case .sherpa:
            if let manifest = SpeechModelCatalog.model(id: config.speechModel) {
                let folder = SpeechModelStore.defaultRootDirectory
                    .appendingPathComponent(manifest.id, isDirectory: true)
                return from(manifest, modelFolder: folder)
            }
            return TranscriptionEngineOption(
                id: sherpaID(model: config.speechModel),
                engine: .sherpa,
                title: config.speechModel,
                detail: "Unknown catalog model",
                whisperModel: config.speechModel,
                summary: "This configured model is not present in the current catalog."
            )
        case .default:
            let folder = config.whisperModelFolder
            let model = config.whisperModel
            return TranscriptionEngineOption(
                id: Self.whisperID(model: model, folder: folder),
                engine: .default,
                title: Self.whisperTitle(for: model),
                detail: folder?.path ?? "WhisperKit cache",
                whisperModel: model,
                whisperModelFolder: folder,
                summary: "General-purpose multilingual transcription powered by WhisperKit."
            )
        }
    }

    public static func from(_ manifest: SpeechModelManifest, modelFolder: URL) -> TranscriptionEngineOption {
        TranscriptionEngineOption(
            id: sherpaID(model: manifest.id),
            engine: manifest.engine,
            title: manifest.title,
            detail: "Local model · \(formattedSize(manifest.sizeBytes))",
            whisperModel: manifest.id,
            whisperModelFolder: modelFolder,
            summary: manifest.summary,
            sizeBytes: manifest.sizeBytes,
            isRecommended: manifest.isRecommended,
            isStreaming: manifest.isStreaming,
            isDownloadable: true
        )
    }

    public static func whisperID(model: String, folder: URL?) -> String {
        if let folder { return "whisper:\(folder.path)" }
        return "whisper:\(model)"
    }

    public static func sherpaID(model: String) -> String {
        "sherpa:\(model)"
    }

    public static func whisperTitle(for model: String) -> String {
        let short = model
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "openai_whisper_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return "WhisperKit \(short)"
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }
}
