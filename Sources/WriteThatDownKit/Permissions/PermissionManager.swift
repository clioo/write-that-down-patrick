import Foundation

/// Status of a single OS permission.
public enum PermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// Permission not applicable to the current configuration (e.g. speech
    /// permission when the native engine is not selected).
    case notRequired
}

/// Snapshot of the permissions the service needs (§3.3, §12).
public struct PermissionSnapshot: Sendable, Equatable {
    public var microphone: PermissionStatus
    public var screenCapture: PermissionStatus
    public var notifications: PermissionStatus
    public var speech: PermissionStatus

    public init(
        microphone: PermissionStatus,
        screenCapture: PermissionStatus,
        notifications: PermissionStatus,
        speech: PermissionStatus
    ) {
        self.microphone = microphone
        self.screenCapture = screenCapture
        self.notifications = notifications
        self.speech = speech
    }

    /// Whether the permissions strictly required to start a session are granted:
    /// microphone (§7.1) and screen capture for system audio (§7.1). Speech is
    /// only required when the native engine is selected.
    public var canStartSession: Bool {
        microphone == .granted
            && screenCapture == .granted
            && (speech == .granted || speech == .notRequired)
    }

    /// Human-readable description of what is blocking a session start.
    public var blockingReason: String? {
        guard !canStartSession else { return nil }
        var missing: [String] = []
        if microphone != .granted { missing.append("Microphone") }
        if screenCapture != .granted { missing.append("Screen Recording (for system audio)") }
        if speech == .denied { missing.append("Speech Recognition") }
        return "Permission required: \(missing.joined(separator: ", ")). "
            + "Grant access in System Settings → Privacy & Security, then start a call again."
    }
}

/// Contract the orchestrator uses to gate session starts on permissions (§10.2).
/// The concrete `SystemPermissionManager` lives alongside this file and talks to
/// AVFoundation / ScreenCaptureKit / UserNotifications / Speech.
public protocol PermissionChecking: AnyObject, Sendable {
    /// Returns the current snapshot without prompting.
    func currentStatus() async -> PermissionSnapshot

    /// Requests any not-yet-determined permissions (used on first launch, §12)
    /// and returns the resulting snapshot.
    func requestAll() async -> PermissionSnapshot
}
