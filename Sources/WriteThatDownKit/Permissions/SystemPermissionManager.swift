import Foundation
import AVFoundation
import Speech
import CoreGraphics

/// Concrete `PermissionChecking` talking to the real OS permission systems:
/// microphone (AVFoundation), system-audio/screen-recording (CoreGraphics TCC),
/// notifications (UserNotifications), and speech (Speech, only when the native
/// engine is selected). Used to gate session starts (§10.2, §12).
public final class SystemPermissionManager: PermissionChecking, @unchecked Sendable {

    private let requiresSpeechProvider: @Sendable () -> Bool

    public init(requiresSpeech: Bool) {
        self.requiresSpeechProvider = { requiresSpeech }
    }

    public init(requiresSpeech: @escaping @Sendable () -> Bool) {
        self.requiresSpeechProvider = requiresSpeech
    }

    public func currentStatus() async -> PermissionSnapshot {
        // NOTE: deliberately does NOT query UNUserNotificationCenter. This
        // method runs on the orchestrator's serial event loop before every
        // session start; notificationSettings() is async-XPC and has been
        // observed to hang, which would stall the loop forever and stop ALL
        // further call detection. Notifications never gate `canStartSession`
        // anyway — authorization is requested once via NotificationService.
        PermissionSnapshot(
            microphone: Self.map(AVCaptureDevice.authorizationStatus(for: .audio)),
            screenCapture: CGPreflightScreenCaptureAccess() ? .granted : .denied,
            notifications: .notRequired,
            speech: requiresSpeechProvider() ? Self.map(SFSpeechRecognizer.authorizationStatus()) : .notRequired
        )
    }

    public func requestAll() async -> PermissionSnapshot {
        // Microphone (§7.1, §12).
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { _ in c.resume() }
            }
        }
        // Screen recording for system audio (§7.1). Prompts on first call;
        // no-op once the user has decided.
        _ = CGRequestScreenCaptureAccess()

        // Speech (only when the native engine needs it).
        if requiresSpeechProvider(), SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        }
        return await currentStatus()
    }

    // MARK: - Mapping

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

}
