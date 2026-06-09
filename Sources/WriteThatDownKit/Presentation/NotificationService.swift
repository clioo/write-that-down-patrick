import Foundation
import UserNotifications

/// Wraps `UserNotifications` to post the "call detected and started" alert (§5.2,
/// §16.1). `UNUserNotificationCenter.current()` requires the process to be a real
/// `.app` bundle; when the executable is run bare (e.g. directly from
/// `swift run`), notification APIs are unavailable, so every call is guarded to
/// degrade to a log line instead of crashing.
@MainActor
public final class NotificationService {

    /// True only when running inside a packaged `.app` bundle.
    private let isBundled: Bool = Bundle.main.bundlePath.hasSuffix(".app")

    public init() {}

    public func requestAuthorization() async {
        guard isBundled else {
            Log.presentation.notice("Notifications unavailable (not running as a .app bundle).")
            return
        }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.presentation.error("Notification authorization failed: \(error.localizedDescription)")
        }
    }

    public func currentAuthorization() async -> UNAuthorizationStatus {
        guard isBundled else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func notifyCallStarted(session: RecordingSession) {
        post(title: "Recording started",
             body: "Write That Down is transcribing this call locally.",
             id: "call-started-\(session.id)")
    }

    public func notify(title: String, body: String) {
        post(title: title, body: body, id: UUID().uuidString)
    }

    private func post(title: String, body: String, id: String) {
        guard isBundled else {
            Log.presentation.notice("Notification (suppressed, not bundled): \(title, privacy: .public)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.presentation.error("Notification post failed: \(error.localizedDescription)") }
        }
    }
}
