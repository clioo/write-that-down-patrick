import Foundation

/// Record of one detected call from start to finish (§4.1.1).
public struct RecordingSession: Sendable, Identifiable, Equatable {
    /// Stable session identifier, derived from the start date and time (§4.2).
    public let id: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var audioSources: [AudioSource]
    /// Absolute path of the associated transcript, or nil until the first write.
    public var transcriptRef: String?
    public var endReason: EndReason?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        status: SessionStatus = .detected,
        audioSources: [AudioSource] = [
            AudioSource(kind: .system, active: false),
            AudioSource(kind: .microphone, active: false),
        ],
        transcriptRef: String? = nil,
        endReason: EndReason? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.audioSources = audioSources
        self.transcriptRef = transcriptRef
        self.endReason = endReason
    }

    /// Derives a stable session id from a start instant, e.g. `session-20260606-142530`.
    /// Uses the POSIX/local calendar so the id matches the on-disk folder/file names.
    public static func makeID(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "session-%04d%02d%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    /// Elapsed time since session start relative to `now`.
    public func elapsed(asOf now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }
}
