import Foundation
import CoreAudio

/// Concrete `MicSignalSource` (§3.1.1, §5.1). Polls CoreAudio's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the system default input
/// device — a process-agnostic "the microphone is in use" signal (§5.1) — on a
/// fixed cadence (`poll_interval_ms`).
///
/// Thread-safety: all mutable state is confined to a private serial queue, which
/// also runs the poll timer and invokes `onSample`.
public final class CallDetector: MicSignalSource, @unchecked Sendable {
    private let pollIntervalMs: Int
    private let queue = DispatchQueue(label: "com.writethatdown.calldetector")
    private var timer: DispatchSourceTimer?
    private var onSample: (@Sendable (Bool) -> Void)?

    public init(pollIntervalMs: Int) {
        self.pollIntervalMs = max(1, pollIntervalMs)
    }

    public func start(onSample: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onSample = onSample
            self.timer?.cancel()

            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(self.pollIntervalMs), leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let active = CallDetector.microphoneInUse()
                self.onSample?(active)
            }
            self.timer = t
            t.resume()
            Log.detection.info("CallDetector started (poll \(self.pollIntervalMs, privacy: .public) ms).")
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.onSample = nil
            Log.detection.info("CallDetector stopped.")
        }
    }

    // MARK: - CoreAudio queries

    /// The system default input device, or nil if none.
    private static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(0) else { return nil }
        return deviceID
    }

    /// Returns true if the default input device is currently running in any
    /// process (i.e. some app is using the microphone) — §5.1.
    static func microphoneInUse() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var isRunning = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &isRunning)
        guard status == noErr else { return false }
        return isRunning != 0
    }
}
