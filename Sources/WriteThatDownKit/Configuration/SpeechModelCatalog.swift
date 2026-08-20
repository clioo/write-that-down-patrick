import Foundation

/// One immutable artifact that makes up a downloadable speech model.
/// URLs point at a pinned upstream revision and every file is verified before
/// the staged download becomes visible to the transcription engine.
public struct SpeechModelFile: Sendable, Equatable {
    public let name: String
    public let remoteURL: URL
    public let sizeBytes: Int64
    public let sha256: String

    public init(name: String, remoteURL: URL, sizeBytes: Int64, sha256: String) {
        self.name = name
        self.remoteURL = remoteURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

/// Declarative metadata used by both the model picker and model store.
/// Adding another downloadable model should be a catalog change plus an engine
/// implementation only when its runtime format differs from an existing one.
public struct SpeechModelManifest: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let engine: EngineKind
    public let sampleRate: Double
    public let isStreaming: Bool
    public let isRecommended: Bool
    public let files: [SpeechModelFile]

    public init(
        id: String,
        title: String,
        summary: String,
        engine: EngineKind,
        sampleRate: Double,
        isStreaming: Bool,
        isRecommended: Bool,
        files: [SpeechModelFile]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.engine = engine
        self.sampleRate = sampleRate
        self.isStreaming = isStreaming
        self.isRecommended = isRecommended
        self.files = files
    }

    public var sizeBytes: Int64 {
        files.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// Installation lifecycle surfaced in the model picker.
public enum ModelInstallState: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Built-in downloadable model catalog. Download URLs intentionally use an
/// immutable Hugging Face revision rather than a moving `main` branch.
public enum SpeechModelCatalog {
    public static let parakeetTDTv3ID = "parakeet-tdt-0.6b-v3-int8"

    public static let parakeetTDTv3 = SpeechModelManifest(
        id: parakeetTDTv3ID,
        title: "Parakeet TDT v3",
        summary: "Highest accuracy for 25 European languages. Punctuation, capitalization, and word-level timestamps.",
        engine: .sherpa,
        sampleRate: 16_000,
        isStreaming: false,
        isRecommended: true,
        files: [
            file(
                "encoder.int8.onnx",
                sizeBytes: 652_184_281,
                sha256: "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"
            ),
            file(
                "decoder.int8.onnx",
                sizeBytes: 11_845_275,
                sha256: "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"
            ),
            file(
                "joiner.int8.onnx",
                sizeBytes: 6_355_277,
                sha256: "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"
            ),
            file(
                "tokens.txt",
                sizeBytes: 93_939,
                sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"
            ),
        ]
    )

    public static let all: [SpeechModelManifest] = [parakeetTDTv3]

    public static func model(id: String) -> SpeechModelManifest? {
        all.first { $0.id == id }
    }

    private static let parakeetRepository =
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
    private static let parakeetRevision = "2bda32ec70b097a55adaa07d9a7173915b43cc78"

    private static func file(_ name: String, sizeBytes: Int64, sha256: String) -> SpeechModelFile {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let urlString = "\(parakeetRepository)/resolve/\(parakeetRevision)/\(encodedName)?download=true"
        // All components above are compile-time constants under our control.
        precondition(URL(string: urlString) != nil, "Invalid speech model URL")
        return SpeechModelFile(
            name: name,
            remoteURL: URL(string: urlString)!,
            sizeBytes: sizeBytes,
            sha256: sha256
        )
    }
}
