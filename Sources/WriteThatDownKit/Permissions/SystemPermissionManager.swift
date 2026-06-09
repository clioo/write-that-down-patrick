import Foundation
import AVFoundation
import Speech
import CoreGraphics
import UserNotifications

/// Concrete `PermissionChecking` talking to the real OS permission systems:
/// microphone (AVFoundation), system-audio/screen-recording (CoreGraphics TCC),
/// notifications (UserNotifications), and speech (Speech, only when the native
/// engine is selected). Used to gate session starts (§10.2, §12).
public final class SystemPermissionManager: PermissionChecking, @unchecked Sendable {

    private let requiresSpeech: Bool
    private let isBundled = Bundle.main.bundlePath.hasSuffix(".app")

    public init(requiresSpeech: Bool) {
        self.requiresSpeech = requiresSpeech
    }

    public func currentStatus() async -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: Self.map(AVCaptureDevice.authorizationStatus(for: .audio)),
            screenCapture: CGPreflightScreenCaptureAccess() ? .granted : .denied,
            notifications: await notificationStatus(),
            speech: requiresSpeech ? Self.map(SFSpeechRecognizer.authorizationStatus()) : .notRequired
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
        if requiresSpeech, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
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

    private func notificationStatus() async -> PermissionStatus {
        guard isBundled else { return .notRequired }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
