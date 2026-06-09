import Foundation
import WhisperKit
import WriteThatDownKit

/// The default transcription engine (§8.2, §16.1): portable, open source, fully
/// offline, multilingual, Metal/ANE accelerated — built on WhisperKit. Lives in
/// the executable target so WhisperKit is fully isolated behind the
/// `TranscriptionEngine` protocol; the rest of the app never imports it.
///
/// ## Streaming strategy (implementation-defined)
/// WhisperKit transcribes a buffer of samples at once, so this engine accumulates
/// pushed audio and commits it in non-overlapping chunks to avoid duplicated
/// text:
/// - A chunk is committed (emitted as a FINAL segment) when it contains speech
///   AND a trailing silence is detected, or when it reaches a hard length cap.
/// - Between commits, the in-progress chunk is transcribed at a throttled cadence
///   and emitted as PARTIAL segments for the live captions.
/// - Pure-silence audio is discarded (advancing the time offset) so silence is
///   never sent to the model and timestamps stay session-relative.
/// A `final class` (not an `actor`) because WhisperKit's `transcribe` is a
/// non-`Sendable` instance method; serialization is guaranteed externally by the
/// orchestrator's single event loop (one `push`/`stop` at a time), so
/// `@unchecked Sendable` is sound.
public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {

    public let id = "whisperkit"

    // Tunables (implementation-defined, documented in README).
    private let silenceRMS: Float = 0.008
    private let speechRMS: Float = 0.02
    private let silenceTailSeconds: Double = 0.6
    private let minCommitSeconds: Double = 1.5
    private let maxSegmentSeconds: Double = 14.0
    private let maxSilenceHoldSeconds: Double = 2.0

    private var partialThrottleSeconds: Double = 1.0

    private var whisperKit: WhisperKit?
    private var language = "en"
    private var sampleRate: Double = 16_000

    private var pending: [Float] = []
    private var committedSeconds: TimeInterval = 0
    private var lastPartialAtSeconds: Double = 0
    private var finalIndex = 0

    public init() {}

    public func start(_ config: EngineConfig) async throws {
        self.language = config.language
        self.sampleRate = config.sampleRate
        self.partialThrottleSeconds = max(0.5, config.windowSeconds / 2)

        let wkConfig = WhisperKitConfig(
            model: config.model,
            modelFolder: config.modelFolder?.path,
            verbose: false,
            logLevel: .error,
            // Strictly offline when a local model folder is provided (no download).
            download: config.modelFolder == nil
        )
        do {
            self.whisperKit = try await WhisperKit(wkConfig)
        } catch {
            throw EngineError.initializationFailed(error.localizedDescription)
        }
        Log.engine.info("WhisperKitEngine started (model=\(config.model, privacy: .public)).")
    }

    public func push(_ buffer: AudioBuffer) async throws -> [Segment] {
        guard whisperKit != nil else { throw EngineError.notStarted }
        pending.append(contentsOf: buffer.samples)
        let duration = Double(pending.count) / sampleRate

        let pendingRMS = rms(pending)
        // Discard pure-silence runs so the model never transcribes silence.
        if pendingRMS < speechRMS {
            if duration >= maxSilenceHoldSeconds {
                committedSeconds += duration
                pending.removeAll(keepingCapacity: true)
                lastPartialAtSeconds = 0
            }
            return []
        }

        let tailSilent = isTailSilent()
        if (duration >= minCommitSeconds && tailSilent) || duration >= maxSegmentSeconds {
            return try await commit(duration: duration)
        }

        if duration - lastPartialAtSeconds >= partialThrottleSeconds {
            lastPartialAtSeconds = duration
            let text = try await transcribe(pending)
            return text.isEmpty ? [] : [Segment(index: -1, timestamp: committedSeconds, text: text, isFinal: false)]
        }
        return []
    }

    public func stop() async throws -> [Segment] {
        defer {
            pending.removeAll(keepingCapacity: false)
            whisperKit = nil
        }
        guard whisperKit != nil else { return [] }
        if rms(pending) >= speechRMS {
            let duration = Double(pending.count) / sampleRate
            let text = try await transcribe(pending)
            if !text.isEmpty {
                let seg = Segment(index: finalIndex, timestamp: committedSeconds, text: text, isFinal: true)
                finalIndex += 1
                committedSeconds += duration
                Log.engine.info("WhisperKitEngine stopped; flushed trailing segment.")
                return [seg]
            }
        }
        Log.engine.info("WhisperKitEngine stopped.")
        return []
    }

    // MARK: - Internals

    private func commit(duration: Double) async throws -> [Segment] {
        let text = try await transcribe(pending)
        var out: [Segment] = []
        if !text.isEmpty {
            out.append(Segment(index: finalIndex, timestamp: committedSeconds, text: text, isFinal: true))
            finalIndex += 1
        }
        committedSeconds += duration
        pending.removeAll(keepingCapacity: true)
        lastPartialAtSeconds = 0
        return out
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisperKit, !samples.isEmpty else { return "" }
        let isAuto = language.lowercased() == "auto"
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: isAuto ? nil : language,
            detectLanguage: isAuto ? true : nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        do {
            let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map { $0.text }.joined(separator: " ")
            return Self.clean(text)
        } catch {
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }

    private func isTailSilent() -> Bool {
        let tailCount = min(pending.count, Int(silenceTailSeconds * sampleRate))
        guard tailCount > 0 else { return false }
        return rms(Array(pending.suffix(tailCount))) < silenceRMS
    }

    private static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop common Whisper "no speech" placeholders.
        for token in ["[BLANK_AUDIO]", "(silence)", "[silence]", "[ Silence ]"] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
