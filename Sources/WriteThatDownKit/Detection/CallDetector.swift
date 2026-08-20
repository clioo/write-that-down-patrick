import Foundation
import CoreAudio
import AppKit
import CoreGraphics

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
    private var onSample: (@Sendable (MicActivitySample) -> Void)?
    /// Last observed app sets, for change-only logging.
    private var lastActiveApps: Set<String> = []
    private var lastIgnoredApps: Set<String> = []

    public init(pollIntervalMs: Int, excludedBundleIDs: [String] = AppConfiguration.defaultExcludedBundleIDs) {
        self.pollIntervalMs = max(1, pollIntervalMs)
        self.excludedBundleIDs = Set(excludedBundleIDs.map { $0.lowercased() })
    }

    public func start(onSample: @escaping @Sendable (MicActivitySample) -> Void) {
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

    private func pollMicrophone() -> MicActivitySample {
        if #available(macOS 14.0, *) {
            let sample = Self.activitySample(excluding: excludedBundleIDs, ownPID: ownPID)
            let active = Set(sample.sources.map(Self.logLabel))
            let ignored = Set(sample.ignoredSources.map(Self.logLabel))
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
            return sample
        }
        // macOS 13 fallback: no attribution available.
        return .unattributed(active: Self.anyInputDeviceRunning())
    }

    // MARK: - macOS 14+: per-process attribution

    /// Returns (active, ignored): bundle IDs of processes currently capturing
    /// input, split by the exclusion list. Our own process never counts.
    /// Processes without a bundle ID are reported as "pid:<n>" and count as
    /// active (an unknown recorder is more likely a call than a terminal).
    @available(macOS 14.0, *)
    public static func capturingApps(excluding excluded: Set<String>, ownPID: pid_t) -> (active: Set<String>, ignored: Set<String>) {
        let sample = activitySample(excluding: excluded, ownPID: ownPID)
        return (
            Set(sample.sources.map(logLabel)),
            Set(sample.ignoredSources.map(logLabel))
        )
    }

    /// Rich per-process sample used by the source-classification policy. The
    /// configured exclusion list retains its existing case-insensitive semantics
    /// and matches either the raw helper bundle or normalized top-level app.
    @available(macOS 14.0, *)
    public static func activitySample(excluding excluded: Set<String>, ownPID: pid_t) -> MicActivitySample {
        let loweredExcluded = Set(excluded.map { $0.lowercased() })
        var active: [MicActivitySource] = []
        var ignored: [MicActivitySource] = []
        for object in processObjects() {
            guard processBool(object, selector: kAudioProcessPropertyIsRunningInput) else { continue }
            let pid = processPID(object)
            if pid == ownPID { continue }
            let rawBundle = processBundleID(object)
            let rawBundleID = rawBundle.isEmpty ? nil : rawBundle
            let applicationBundleID = normalizedApplicationBundleID(rawBundleID)
            let app = runningApplication(for: applicationBundleID, fallbackPID: pid)
            let source = MicActivitySource(
                pid: pid,
                bundleID: rawBundleID,
                applicationBundleID: applicationBundleID,
                displayName: app?.localizedName,
                windowTitle: app.flatMap { frontmostWindowTitle(for: $0.processIdentifier) }
            )
            let identifiers = [rawBundleID, applicationBundleID]
                .compactMap { $0?.lowercased() }
            if identifiers.contains(where: loweredExcluded.contains) {
                ignored.append(source)
            } else {
                active.append(source)
            }
        }
        active.sort(by: sourceOrder)
        ignored.sort(by: sourceOrder)
        return MicActivitySample(
            isActive: !active.isEmpty,
            attribution: .attributed,
            sources: active,
            ignoredSources: ignored
        )
    }

    private static func logLabel(_ source: MicActivitySource) -> String {
        source.bundleID ?? source.applicationBundleID ?? "pid:\(source.pid)"
    }

    private static func sourceOrder(_ lhs: MicActivitySource, _ rhs: MicActivitySource) -> Bool {
        logLabel(lhs).localizedCaseInsensitiveCompare(logLabel(rhs)) == .orderedAscending
    }

    /// Chromium and similar apps attribute capture to nested helper bundles.
    /// Normalize only well-known families; an unknown helper remains unknown and
    /// therefore requires confirmation rather than being auto-recorded.
    private static func normalizedApplicationBundleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let id = raw.lowercased()
        if id == "us.zoom.xos" || id.hasPrefix("us.zoom.xos.") { return "us.zoom.xos" }
        if id == "com.microsoft.teams2" || id.hasPrefix("com.microsoft.teams2.") { return "com.microsoft.teams2" }
        if id == "com.microsoft.teams" || id.hasPrefix("com.microsoft.teams.") { return "com.microsoft.teams" }
        if id == "com.google.chrome" || id.hasPrefix("com.google.chrome.") { return "com.google.Chrome" }
        if id == "com.brave.browser" || id.hasPrefix("com.brave.browser.") { return "com.brave.Browser" }
        if id == "com.microsoft.edgemac" || id.hasPrefix("com.microsoft.edgemac.") { return "com.microsoft.edgemac" }
        if id == "org.mozilla.firefox" || id.hasPrefix("org.mozilla.firefox.") { return "org.mozilla.firefox" }
        if id == "company.thebrowser.browser" || id.hasPrefix("company.thebrowser.browser.") { return "company.thebrowser.Browser" }
        if id == "com.apple.safari" || id.hasPrefix("com.apple.safari.") { return "com.apple.Safari" }
        return raw
    }

    private static func runningApplication(
        for bundleID: String?,
        fallbackPID: pid_t
    ) -> NSRunningApplication? {
        if let bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        return NSRunningApplication(processIdentifier: fallbackPID)
    }

    /// Returns only the foremost on-screen window title for an app. Browser
    /// background tabs are deliberately not guessed: without a browser extension
    /// macOS exposes microphone ownership only at process level.
    private static func frontmostWindowTitle(for pid: pid_t) -> String? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(kCGNullWindowID)
        ) as? [[String: Any]] else { return nil }

        for window in info {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == pid,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let rawTitle = window[kCGWindowName as String] as? String
            else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
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
