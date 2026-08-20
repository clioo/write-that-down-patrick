import Foundation
import SherpaOnnx
import WriteThatDownKit

/// Offline, downloadable ONNX transcription powered by sherpa-onnx. Parakeet
/// itself decodes complete buffers, so the engine exposes live captions by
/// periodically re-decoding the growing utterance and commits a final segment
/// at trailing silence or at a bounded hard cap.
public final class SherpaOnnxEngine: TranscriptionEngine, @unchecked Sendable {
    public let id = "sherpa-onnx"

    private let silenceRMS: Float = 0.008
    private let speechRMS: Float = 0.02
    private let silenceTailSeconds: Double = 0.6
    private let minCommitSeconds: Double = 1.5
    private let maxSegmentSeconds: Double = 20
    private let maxSilenceHoldSeconds: Double = 2

    private var partialThrottleSeconds: Double = 1
    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var sampleRate: Double = 16_000
    private var pending: [Float] = []
    private var committedSeconds: TimeInterval = 0
    private var lastPartialAtSeconds: Double = 0
    private var finalIndex = 0
    private var inferenceCount = 0
    private var maxInferenceMs = 0

    public init() {}

    public func start(_ config: EngineConfig) async throws {
        guard let folder = config.modelFolder else {
            throw EngineError.initializationFailed("The selected speech model has not been downloaded.")
        }
        guard abs(config.sampleRate - 16_000) < 0.5 else {
            throw EngineError.initializationFailed("Parakeet requires 16 kHz audio.")
        }

        let encoder = folder.appendingPathComponent("encoder.int8.onnx")
        let decoder = folder.appendingPathComponent("decoder.int8.onnx")
        let joiner = folder.appendingPathComponent("joiner.int8.onnx")
        let tokens = folder.appendingPathComponent("tokens.txt")
        for file in [encoder, decoder, joiner, tokens] where !FileManager.default.fileExists(atPath: file.path) {
            throw EngineError.initializationFailed("Model file is missing: \(file.lastPathComponent)")
        }

        self.sampleRate = config.sampleRate
        self.partialThrottleSeconds = max(0.75, config.windowSeconds / 2)
        self.pending.removeAll(keepingCapacity: false)
        self.committedSeconds = 0
        self.lastPartialAtSeconds = 0
        self.finalIndex = 0
        self.inferenceCount = 0
        self.maxInferenceMs = 0

        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: encoder.path,
            decoder: decoder.path,
            joiner: joiner.path
        )
        let model = sherpaOnnxOfflineModelConfig(
            tokens: tokens.path,
            transducer: transducer,
            numThreads: 2,
            provider: "cpu",
            debug: 0
        )
        let features = sherpaOnnxFeatureConfig(sampleRate: Int(config.sampleRate), featureDim: 80)
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: features,
            modelConfig: model,
            decodingMethod: "greedy_search"
        )
        self.recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)

        Log.engine.info("SherpaOnnxEngine started (model=\(config.model, privacy: .public)).")
        Log.metrics.notice(
            "sherpa_start model=\(config.model, privacy: .public) partial_throttle_ms=\(Int(self.partialThrottleSeconds * 1000), privacy: .public)"
        )
    }

    public func push(_ buffer: AudioBuffer) async throws -> [Segment] {
        guard recognizer != nil else { throw EngineError.notStarted }
        pending.append(contentsOf: buffer.samples)
        let duration = Double(pending.count) / sampleRate

        if rms(pending) < speechRMS {
            if duration >= maxSilenceHoldSeconds {
                committedSeconds += duration
                pending.removeAll(keepingCapacity: true)
                lastPartialAtSeconds = 0
            }
            return []
        }

        if (duration >= minCommitSeconds && isTailSilent()) || duration >= maxSegmentSeconds {
            return try commit(duration: duration)
        }

        if duration - lastPartialAtSeconds >= partialThrottleSeconds {
            lastPartialAtSeconds = duration
            let text = try transcribe(pending, reason: "partial")
            return text.isEmpty
                ? []
                : [Segment(index: -1, timestamp: committedSeconds, text: text, isFinal: false)]
        }
        return []
    }

    public func stop() async throws -> [Segment] {
        defer {
            pending.removeAll(keepingCapacity: false)
            recognizer = nil
        }
        guard recognizer != nil else { return [] }
        guard rms(pending) >= speechRMS else { return [] }

        let duration = Double(pending.count) / sampleRate
        let text = try transcribe(pending, reason: "flush")
        guard !text.isEmpty else { return [] }
        let segment = Segment(
            index: finalIndex,
            timestamp: committedSeconds,
            text: text,
            isFinal: true
        )
        finalIndex += 1
        committedSeconds += duration
        return [segment]
    }

    private func commit(duration: Double) throws -> [Segment] {
        let text = try transcribe(pending, reason: "final")
        var output: [Segment] = []
        if !text.isEmpty {
            output.append(
                Segment(
                    index: finalIndex,
                    timestamp: committedSeconds,
                    text: text,
                    isFinal: true
                )
            )
            finalIndex += 1
        }
        committedSeconds += duration
        pending.removeAll(keepingCapacity: true)
        lastPartialAtSeconds = 0
        return output
    }

    private func transcribe(_ samples: [Float], reason: String) throws -> String {
        guard let recognizer, !samples.isEmpty else { return "" }
        let audioMs = Int((Double(samples.count) / sampleRate) * 1_000)
        let started = Date()
        let result = recognizer.decode(samples: samples, sampleRate: Int(sampleRate))
        let cleaned = Self.clean(result.text)
        let elapsedMs = max(0, Int(Date().timeIntervalSince(started) * 1_000))
        inferenceCount += 1
        maxInferenceMs = max(maxInferenceMs, elapsedMs)
        Log.metrics.notice(
            "sherpa_inference reason=\(reason, privacy: .public) audio_ms=\(audioMs, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public) max_elapsed_ms=\(self.maxInferenceMs, privacy: .public) inference_count=\(self.inferenceCount, privacy: .public) result_chars=\(cleaned.count, privacy: .public)"
        )
        return cleaned
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func isTailSilent() -> Bool {
        let count = min(pending.count, Int(silenceTailSeconds * sampleRate))
        guard count > 0 else { return false }
        return rms(Array(pending.suffix(count))) < silenceRMS
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
