import Foundation
import Speech
import AVFoundation

/// Optional native engine (§8.2, §16.2) built on `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true`. Strictly offline: if the device/locale
/// does not support on-device recognition, `start` throws rather than silently
/// falling back to network recognition (honors the no-network constraint, §12).
///
/// SFSpeech delivers cumulative hypotheses asynchronously; we surface them as
/// partial segments (captions) and convert confirmed transcriptions into final
/// segments. SFSpeech tends to mark `isFinal` only when audio ends, so for the
/// native engine final segments are typically committed at `stop()`. This is the
/// optional engine; the default (WhisperKit) commits finals incrementally.
public actor NativeSpeechEngine: TranscriptionEngine {

    public nonisolated let id = "native-sfspeech"

    private let locale: Locale
    private var sampleRate: Double = 16_000

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var pendingFinals: [Segment] = []
    private var latestPartial: Segment?
    private var lastEmittedPartialText: String = ""

    /// Seconds of audio committed in previous (finalized) recognition requests —
    /// added to per-request segment timestamps to keep offsets session-relative.
    private var baseOffset: TimeInterval = 0
    private var currentRequestSeconds: TimeInterval = 0
    private var finalIndex = 0

    public init(localeIdentifier: String? = nil) {
        if let id = localeIdentifier, id.lowercased() != "auto" {
            self.locale = Locale(identifier: id)
        } else {
            self.locale = Locale.current
        }
    }

    public func start(_ config: EngineConfig) async throws {
        sampleRate = config.sampleRate
        let chosenLocale: Locale = {
            if config.language.lowercased() == "auto" { return Locale.current }
            return Locale(identifier: config.language)
        }()

        guard let recognizer = SFSpeechRecognizer(locale: chosenLocale) ?? SFSpeechRecognizer() else {
            throw EngineError.initializationFailed("No SFSpeechRecognizer for locale \(chosenLocale.identifier).")
        }
        guard recognizer.isAvailable else {
            throw EngineError.initializationFailed("SFSpeechRecognizer is not available.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw EngineError.initializationFailed(
                "On-device recognition is not supported for \(chosenLocale.identifier); refusing to use network recognition."
            )
        }
        recognizer.defaultTaskHint = .dictation
        self.recognizer = recognizer
        startTask()
        Log.engine.info("NativeSpeechEngine started (locale=\(chosenLocale.identifier, privacy: .public)).")
    }

    public func push(_ buffer: AudioBuffer) async throws -> [Segment] {
        guard recognizer != nil else { throw EngineError.notStarted }
        if request == nil { startTask() }
        if let pcm = makePCMBuffer(from: buffer) {
            request?.append(pcm)
            currentRequestSeconds += buffer.duration
        }
        return drain()
    }

    public func stop() async throws -> [Segment] {
        request?.endAudio()
        // Give SFSpeech a brief moment to deliver the final transcription.
        for _ in 0..<15 {
            if !pendingFinals.isEmpty { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 s
        }
        var out = drain()
        // If a trailing partial never finalized, preserve it as a final segment.
        if let partial = latestPartial, !partial.text.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(Segment(index: finalIndex, timestamp: partial.timestamp, text: partial.text, isFinal: true))
            finalIndex += 1
            latestPartial = nil
        }
        teardownTask()
        recognizer = nil
        Log.engine.info("NativeSpeechEngine stopped (\(out.count, privacy: .public) trailing segments).")
        return out
    }

    // MARK: - Recognition task lifecycle

    private func startTask() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        self.request = req
        self.currentRequestSeconds = 0
        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let isFinal = result.isFinal
                let fullText = result.bestTranscription.formattedString
                let segs = result.bestTranscription.segments.map { (text: $0.substring, ts: TimeInterval($0.timestamp)) }
                Task { await self.ingest(fullText: fullText, segments: segs, isFinal: isFinal) }
            }
            if let error {
                Task { await self.ingestError(error) }
            }
        }
    }

    private func teardownTask() {
        task?.cancel()
        task = nil
        request = nil
    }

    private func ingest(fullText: String, segments: [(text: String, ts: TimeInterval)], isFinal: Bool) {
        if isFinal {
            if segments.isEmpty {
                let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    pendingFinals.append(Segment(index: finalIndex, timestamp: baseOffset, text: text, isFinal: true))
                    finalIndex += 1
                }
            } else {
                for s in segments {
                    let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    pendingFinals.append(Segment(index: finalIndex, timestamp: baseOffset + s.ts, text: text, isFinal: true))
                    finalIndex += 1
                }
            }
            latestPartial = nil
            lastEmittedPartialText = ""
            // Continue the session with a fresh request so subsequent audio is
            // still recognized (SFSpeech ends the task after a final result).
            baseOffset += currentRequestSeconds
            teardownTask()
            startTask()
        } else {
            let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            latestPartial = Segment(index: -1, timestamp: baseOffset, text: text, isFinal: false)
        }
    }

    private func ingestError(_ error: Error) {
        Log.engine.error("SFSpeech recognition error: \(error.localizedDescription)")
    }

    private func drain() -> [Segment] {
        var out = pendingFinals
        pendingFinals.removeAll(keepingCapacity: true)
        if let partial = latestPartial, partial.text != lastEmittedPartialText, !partial.text.isEmpty {
            lastEmittedPartialText = partial.text
            out.append(partial)
        }
        return out
    }

    // MARK: - Conversion

    private func makePCMBuffer(from buffer: AudioBuffer) -> AVAudioPCMBuffer? {
        guard !buffer.samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: buffer.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buffer.samples.count))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(buffer.samples.count)
        if let dst = pcm.floatChannelData?[0] {
            buffer.samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: src.count)
            }
        }
        return pcm
    }
}
