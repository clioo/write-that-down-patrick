import Foundation
import AVFoundation

/// Captures microphone audio via `AVAudioEngine` (§7.1) and delivers mono float
/// samples at `targetSampleRate` to a sink closure.
///
/// Used internally by `AudioCapturer`; not a standalone `AudioCapturing`.
final class MicrophoneCapturer: @unchecked Sendable {
    private let targetSampleRate: Double
    private let engine = AVAudioEngine()
    private var installed = false
    private let lock = NSLock()

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
    }

    /// Installs a tap on the input node and starts the engine. `onSamples` is
    /// invoked on the audio render thread for each tap buffer.
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable("Input node has no valid format (sampleRate=\(format.sampleRate)).")
        }

        let target = targetSampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let samples = AudioConversion.monoFloatSamples(from: buffer, targetSampleRate: target)
            if !samples.isEmpty { onSamples(samples) }
        }
        installed = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            installed = false
            throw CaptureError.microphoneUnavailable(error.localizedDescription)
        }
        Log.capture.info("MicrophoneCapturer started.")
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard installed else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        installed = false
        Log.capture.info("MicrophoneCapturer stopped.")
    }
}
