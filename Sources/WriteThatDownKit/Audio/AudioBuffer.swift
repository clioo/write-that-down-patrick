import Foundation

/// A normalized block of PCM audio delivered from the capture layer to the
/// transcription engine (§7.2).
///
/// Format (implementation-defined, documented per §7.2):
/// - mono
/// - 32-bit float samples normalized to [-1, 1]
/// - `sampleRate` Hz (16 kHz by default — see `AppConfiguration.sampleRate`)
///
/// System and microphone audio are down-mixed into this single stream (v1 has no
/// diarization, §2.2), so one `AudioBuffer` carries the combined call audio.
public struct AudioBuffer: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { samples.count }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// Root-mean-square level of the block, used for inactivity detection (§7.3).
    /// Returns 0 for an empty buffer.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static let silent = AudioBuffer(samples: [], sampleRate: 16_000)
}
