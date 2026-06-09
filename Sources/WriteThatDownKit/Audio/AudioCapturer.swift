import Foundation

/// The concrete `AudioCapturing` (§3.1.2). Combines system audio (ScreenCaptureKit)
/// and microphone (AVAudioEngine), down-mixes both into a single normalized mono
/// float stream (§7.2), and delivers fixed-size `AudioBuffer`s on a steady cadence.
///
/// ## Mixing strategy (implementation-defined, §7.2)
/// Each source's resampled mono samples are appended to its own ring buffer. A
/// drain timer fires every `captureBufferSeconds` and pulls up to `chunkFrames`
/// from each ring, sums them sample-wise (padding the shorter with silence),
/// clamps to [-1, 1], and emits one `AudioBuffer`. This yields a steady, time-
/// stable mixed stream regardless of how the two OS sources schedule delivery.
/// Rings are capped at 5 s to bound memory if a source bursts.
public final class AudioCapturer: AudioCapturing, @unchecked Sendable {
    private let config: AppConfiguration
    private let mic: MicrophoneCapturer
    private let system: SystemAudioCapturer

    private let drainQueue = DispatchQueue(label: "com.writethatdown.audiomixer")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var systemRing: [Float] = []
    private var micRing: [Float] = []
    private var onBuffer: (@Sendable (AudioBuffer) -> Void)?
    private var started = false

    public init(config: AppConfiguration) {
        self.config = config
        self.mic = MicrophoneCapturer(targetSampleRate: config.sampleRate)
        self.system = SystemAudioCapturer(targetSampleRate: config.sampleRate)
    }

    public func start(onBuffer: @escaping @Sendable (AudioBuffer) -> Void) async throws {
        beginState(onBuffer: onBuffer)

        // System audio first (slower to spin up; failure is a capture failure §10.2).
        do {
            try await system.start { [weak self] samples in self?.appendSystem(samples) }
        } catch {
            clearState()
            throw error
        }
        // Microphone.
        do {
            try mic.start { [weak self] samples in self?.appendMic(samples) }
        } catch {
            await system.stop()
            clearState()
            throw error
        }

        let chunkFrames = max(1, Int(config.sampleRate * config.captureBufferSeconds))
        let intervalMs = max(10, Int(config.captureBufferSeconds * 1000))
        let t = DispatchSource.makeTimerSource(queue: drainQueue)
        t.schedule(deadline: .now() + .milliseconds(intervalMs),
                   repeating: .milliseconds(intervalMs),
                   leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.drainAndEmit(chunkFrames: chunkFrames) }
        storeTimer(t)
        t.resume()
        Log.capture.info("AudioCapturer started (chunk \(chunkFrames) frames).")
    }

    public func stop() async {
        teardown()
        mic.stop()
        await system.stop()
        Log.capture.info("AudioCapturer stopped.")
    }

    // MARK: - Synchronous lock-guarded helpers (safe from async callers)

    private func beginState(onBuffer: @escaping @Sendable (AudioBuffer) -> Void) {
        lock.lock(); self.onBuffer = onBuffer; started = true; lock.unlock()
    }
    private func clearState() {
        lock.lock(); onBuffer = nil; started = false; lock.unlock()
    }
    private func storeTimer(_ t: DispatchSourceTimer) {
        lock.lock(); self.timer = t; lock.unlock()
    }
    private func teardown() {
        lock.lock()
        timer?.cancel(); timer = nil
        onBuffer = nil; started = false
        systemRing.removeAll(keepingCapacity: false)
        micRing.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    // MARK: - Ring buffers (called from capture threads — synchronous)

    private func appendSystem(_ s: [Float]) {
        lock.lock(); systemRing.append(contentsOf: s); cap(&systemRing); lock.unlock()
    }
    private func appendMic(_ s: [Float]) {
        lock.lock(); micRing.append(contentsOf: s); cap(&micRing); lock.unlock()
    }
    private func cap(_ ring: inout [Float]) {
        let maxFrames = Int(config.sampleRate * 5)
        if ring.count > maxFrames { ring.removeFirst(ring.count - maxFrames) }
    }

    private func drainAndEmit(chunkFrames: Int) {
        lock.lock()
        guard started, let sink = onBuffer else { lock.unlock(); return }
        let sysCount = min(chunkFrames, systemRing.count)
        let micCount = min(chunkFrames, micRing.count)
        let sys = sysCount > 0 ? Array(systemRing.prefix(sysCount)) : []
        let m = micCount > 0 ? Array(micRing.prefix(micCount)) : []
        if sysCount > 0 { systemRing.removeFirst(sysCount) }
        if micCount > 0 { micRing.removeFirst(micCount) }
        let rate = config.sampleRate
        lock.unlock()

        var mixed = [Float](repeating: 0, count: chunkFrames)
        for i in 0..<sys.count { mixed[i] += sys[i] }
        for i in 0..<m.count { mixed[i] += m[i] }
        for i in 0..<chunkFrames {
            if mixed[i] > 1 { mixed[i] = 1 } else if mixed[i] < -1 { mixed[i] = -1 }
        }
        sink(AudioBuffer(samples: mixed, sampleRate: rate))
    }
}
