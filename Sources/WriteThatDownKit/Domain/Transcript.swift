import Foundation

/// Metadata for the document produced by a session (§4.1.2). The list of
/// segments is not held here — final segments are streamed to disk incrementally
/// by `TranscriptWriter`; this struct carries the header/identity information.
public struct TranscriptMetadata: Sendable, Equatable {
    public let sessionID: String
    public var title: String
    /// Local date of the session start (used for the date folder, §9.2).
    public let date: Date
    /// Local start time (used in the header and file name).
    public let startedAtLocal: Date
    /// Duration; nil until finalized (§4.1.2 / §9.4).
    public var duration: TimeInterval?
    /// Absolute path; nil until the first write (§4.1.2).
    public var filePath: URL?

    public init(
        sessionID: String,
        title: String,
        date: Date,
        startedAtLocal: Date,
        duration: TimeInterval? = nil,
        filePath: URL? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.date = date
        self.startedAtLocal = startedAtLocal
        self.duration = duration
        self.filePath = filePath
    }
}
