import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures system audio (the output of call apps) via ScreenCaptureKit's
/// `SCStream` with `capturesAudio = true` (§7.1) — a native API that needs no
/// third-party audio driver (§7.1 SHOULD). Delivers mono float samples at
/// `targetSampleRate`.
///
/// Used internally by `AudioCapturer`. Video frames are requested at a minimal
/// size and ignored; only the audio output is consumed.
final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let targetSampleRate: Double
    private let outputQueue = DispatchQueue(label: "com.writethatdown.systemaudio")
    private let lock = NSLock()
    private var stream: SCStream?
    private var onSamples: (@Sendable ([Float]) -> Void)?

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
        super.init()
    }

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) async throws {
        store(onSamples: onSamples)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.systemAudioUnavailable(
                "Could not query shareable content — Screen Recording permission may be denied. \(error.localizedDescription)"
            )
        }
        guard let display = content.displays.first else {
            throw CaptureError.systemAudioUnavailable("No display available for system-audio capture.")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(targetSampleRate)
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        // Minimal video — we never read it.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        } catch {
            throw CaptureError.systemAudioUnavailable("addStreamOutput(audio) failed: \(error.localizedDescription)")
        }
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.systemAudioUnavailable("startCapture failed: \(error.localizedDescription)")
        }
        store(stream: stream)
        Log.capture.info("SystemAudioCapturer started.")
    }

    func stop() async {
        let s = takeStreamForStop()
        if let s { try? await s.stopCapture() }
        Log.capture.info("SystemAudioCapturer stopped.")
    }

    // MARK: Synchronous lock-guarded helpers (safe from async callers)

    private func store(onSamples: @escaping @Sendable ([Float]) -> Void) {
        lock.lock(); self.onSamples = onSamples; lock.unlock()
    }
    private func store(stream: SCStream) {
        lock.lock(); self.stream = stream; lock.unlock()
    }
    private func takeStreamForStop() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        let s = stream
        stream = nil
        onSamples = nil
        return s
    }
    private func currentSink() -> (@Sendable ([Float]) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return onSamples
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let samples = SystemAudioCapturer.floatSamples(from: sampleBuffer, targetSampleRate: targetSampleRate)
        guard !samples.isEmpty else { return }
        currentSink()?(samples)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("SCStream stopped with error: \(error.localizedDescription)")
    }

    // MARK: Conversion

    static func floatSamples(from sampleBuffer: CMSampleBuffer, targetSampleRate: Double) -> [Float] {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return [] }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return [] }
        guard let avFormat = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return [] }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else { return [] }
        return AudioConversion.monoFloatSamples(from: pcm, targetSampleRate: targetSampleRate)
    }
}
