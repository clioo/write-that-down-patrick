import Foundation
@preconcurrency import AVFoundation

/// Single-use holder for the converter input block (see `monoFloatSamples`).
/// `@unchecked Sendable` is sound: the block runs synchronously on one thread.
private final class ConversionInput: @unchecked Sendable {
    var supplied = false
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Helpers to normalize captured audio into the engine format: mono, 32-bit
/// float, target sample rate (§7.2). Both the microphone (AVAudioEngine) and
/// system-audio (ScreenCaptureKit) paths funnel through here.
enum AudioConversion {

    /// Converts an `AVAudioPCMBuffer` (any format) to a mono `[Float]` at
    /// `targetSampleRate`. Returns an empty array on failure.
    static func monoFloatSamples(
        from buffer: AVAudioPCMBuffer,
        targetSampleRate: Double
    ) -> [Float] {
        let inFormat = buffer.format

        // Fast path: already mono float at the target rate.
        if inFormat.commonFormat == .pcmFormatFloat32,
           inFormat.channelCount == 1,
           abs(inFormat.sampleRate - targetSampleRate) < 0.5,
           let ch = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: ch[0], count: n))
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return [] }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return [] }

        let ratio = targetSampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
        else { return [] }

        // The conversion block runs synchronously on this thread, but its type is
        // `@Sendable`; route the one-shot input + flag through a box so capturing
        // them is concurrency-clean.
        let box = ConversionInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if box.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            box.supplied = true
            outStatus.pointee = .haveData
            return box.buffer
        }

        guard status != .error, conversionError == nil, let ch = outBuffer.floatChannelData else {
            return []
        }
        let n = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }
}
