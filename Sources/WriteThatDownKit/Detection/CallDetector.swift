import Foundation
import CoreAudio

/// Concrete `MicSignalSource` (§3.1.1, §5.1). Polls CoreAudio on a fixed
/// cadence (`poll_interval_ms`) for "is a microphone in use".
///
/// On macOS 14+ it attributes mic use to the OWNING PROCESS via CoreAudio
/// process objects, so apps on the exclusion list (terminals, editors — voice
/// commands to coding agents) never count as a call. Our own capture (PID) is
/// always ignored. On macOS 13 it falls back to device-level detection ("any
/// input device running"), which cannot attribute and therefore cannot exclude.
///
/// Thread-safety: all mutable state is confined to a private serial queue,
/// which also runs the poll timer and invokes `onSample`.
public final class CallDetector: MicSignalSource, @unchecked Sendable {
    private let pollIntervalMs: Int
    /// Lowercased bundle IDs whose mic use is NOT a call.
    private let excludedBundleIDs: Set<String>
    private let ownPID = getpid()

    private let queue = DispatchQueue(label: "com.writethatdown.calldetector")
    private var timer: DispatchSourceTimer?
    private var onSample: (@Sendable (Bool) -> Void)?
    /// Last observed app sets, for change-only logging.
    private var lastActiveApps: Set<String> = []
    private var lastIgnoredApps: Set<String> = []

    public init(pollIntervalMs: Int, excludedBundleIDs: [String] = AppConfiguration.defaultExcludedBundleIDs) {
        self.pollIntervalMs = max(1, pollIntervalMs)
        self.excludedBundleIDs = Set(excludedBundleIDs.map { $0.lowercased() })
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
                self.onSample?(self.pollMicrophone())
            }
            self.timer = t
            t.resume()
            Log.detection.notice("CallDetector started (poll \(self.pollIntervalMs, privacy: .public) ms, \(self.excludedBundleIDs.count, privacy: .public) excluded apps).")
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.onSample = nil
            Log.detection.notice("CallDetector stopped.")
        }
    }

    // MARK: - Polling (runs on `queue`)

    private func pollMicrophone() -> Bool {
        if #available(macOS 14.0, *) {
            let (active, ignored) = Self.capturingApps(excluding: excludedBundleIDs, ownPID: ownPID)
            // Log only when the picture changes — one line per transition.
            if active != lastActiveApps || ignored != lastIgnoredApps {
                if !active.isEmpty {
                    Log.detection.notice("Mic in use by: \(active.sorted().joined(separator: ", "), privacy: .public)")
                }
                if !ignored.isEmpty && active.isEmpty {
                    Log.detection.notice("Ignoring mic use by excluded apps: \(ignored.sorted().joined(separator: ", "), privacy: .public)")
                }
                if active.isEmpty && ignored.isEmpty && !(lastActiveApps.isEmpty && lastIgnoredApps.isEmpty) {
                    Log.detection.notice("Microphone released.")
                }
                lastActiveApps = active
                lastIgnoredApps = ignored
            }
            return !active.isEmpty
        }
        // macOS 13 fallback: no attribution available.
        return Self.anyInputDeviceRunning()
    }

    // MARK: - macOS 14+: per-process attribution

    /// Returns (active, ignored): bundle IDs of processes currently capturing
    /// input, split by the exclusion list. Our own process never counts.
    /// Processes without a bundle ID are reported as "pid:<n>" and count as
    /// active (an unknown recorder is more likely a call than a terminal).
    @available(macOS 14.0, *)
    public static func capturingApps(excluding excluded: Set<String>, ownPID: pid_t) -> (active: Set<String>, ignored: Set<String>) {
        var active: Set<String> = []
        var ignored: Set<String> = []
        for object in processObjects() {
            guard processBool(object, selector: kAudioProcessPropertyIsRunningInput) else { continue }
            let pid = processPID(object)
            if pid == ownPID { continue }
            let bundle = processBundleID(object)
            let label = bundle.isEmpty ? "pid:\(pid)" : bundle
            if excluded.contains(bundle.lowercased()) && !bundle.isEmpty {
                ignored.insert(label)
            } else {
                active.insert(label)
            }
        }
        return (active, ignored)
    }

    @available(macOS 14.0, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }
        return objects
    }

    @available(macOS 14.0, *)
    private static func processBool(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    @available(macOS 14.0, *)
    private static func processPID(_ object: AudioObjectID) -> pid_t {
        var pid = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        return pid
    }

    @available(macOS 14.0, *)
    private static func processBundleID(_ object: AudioObjectID) -> String {
        var bundleRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundleRef) == noErr,
              let ref = bundleRef else { return "" }
        return ref.takeRetainedValue() as String
    }

    // MARK: - macOS 13 fallback: device-level detection (no attribution)

    /// Returns true if ANY input-capable audio device is currently in use by
    /// some process (§5.1) — not just the system default input.
    public static func anyInputDeviceRunning() -> Bool {
        for device in allDevices() where hasInputStreams(device) {
            if isRunningSomewhere(device) { return true }
        }
        return false
    }

    /// Every audio device known to the system.
    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    /// Whether the device has at least one INPUT stream (i.e. it is a mic or
    /// other capture device, not output-only speakers).
    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Whether ANY process currently has the device running.
    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var isRunning = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
}
