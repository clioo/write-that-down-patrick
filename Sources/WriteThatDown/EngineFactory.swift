import Foundation
import WriteThatDownKit

/// Maps the `engine` configuration value (§11) to a concrete
/// `TranscriptionEngine`. This is the ONLY place both engine implementations are
/// named together — selecting/adding an engine requires no changes elsewhere
/// (§8.2). The rest of the app depends only on the protocol.
enum EngineFactory {
    static func make(_ kind: EngineKind, language: String) -> any TranscriptionEngine {
        switch kind {
        case .default:
            return WhisperKitEngine()
        case .native:
            return NativeSpeechEngine(localeIdentifier: language)
        }
    }
}
