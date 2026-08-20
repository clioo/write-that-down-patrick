import Foundation

/// A short-lived, microphone-only transcription session used by global
/// dictation. It serializes every engine call and returns plain text without
/// creating a meeting, transcript file, assistant request, or cloud upload.
public actor LocalDictationSession {
    private let engine: any TranscriptionEngine
    private let configuration: EngineConfig
    private var finalTexts: [String] = []
    private var latestPartial = ""
    private var started = false
    private var finished = false

    public init(engine: any TranscriptionEngine, configuration: EngineConfig) {
        self.engine = engine
        self.configuration = configuration
    }

    public func start() async throws {
        guard !started, !finished else { return }
        try await engine.start(configuration)
        started = true
    }

    public func ingest(_ buffer: AudioBuffer) async throws {
        guard started, !finished, !buffer.samples.isEmpty else { return }
        consume(try await engine.push(buffer))
    }

    public func finish() async throws -> String {
        guard !finished else { return assembledText }
        finished = true
        guard started else { return assembledText }
        consume(try await engine.stop())
        return assembledText
    }

    private func consume(_ segments: [Segment]) {
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if segment.isFinal {
                finalTexts.append(text)
                latestPartial = ""
            } else {
                latestPartial = text
            }
        }
    }

    private var assembledText: String {
        let pieces = finalTexts + (latestPartial.isEmpty ? [] : [latestPartial])
        return pieces.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
