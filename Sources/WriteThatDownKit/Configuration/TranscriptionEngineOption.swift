import Foundation

/// A transcription runtime the user can select from Settings. The list shown in
/// the UI contains only options the composition root has verified as available.
public struct TranscriptionEngineOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let engine: EngineKind
    public let title: String
    public let detail: String
    public let whisperModel: String
    public let whisperModelFolder: URL?

    public init(
        id: String,
        engine: EngineKind,
        title: String,
        detail: String,
        whisperModel: String = "",
        whisperModelFolder: URL? = nil
    ) {
        self.id = id
        self.engine = engine
        self.title = title
        self.detail = detail
        self.whisperModel = whisperModel
        self.whisperModelFolder = whisperModelFolder
    }

    public static func from(_ config: AppConfiguration) -> TranscriptionEngineOption {
        switch config.engine {
        case .native:
            return TranscriptionEngineOption(
                id: "native",
                engine: .native,
                title: "Apple Speech",
                detail: "Built into macOS"
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
                whisperModelFolder: folder
            )
        }
    }

    public static func whisperID(model: String, folder: URL?) -> String {
        if let folder { return "whisper:\(folder.path)" }
        return "whisper:\(model)"
    }

    public static func whisperTitle(for model: String) -> String {
        let short = model
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "openai_whisper_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return "WhisperKit \(short)"
    }
}
