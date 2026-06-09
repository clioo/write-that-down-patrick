import Foundation

/// A `Transcript Segment` — the atomic unit of transcribed output (§4.1.3).
///
/// Partial segments (`isFinal == false`) are hypotheses shown only in captions
/// and MUST NOT be written to disk (§8.3). Final segments (`isFinal == true`)
/// are confirmed text that MUST be written to the transcript document (§8.3).
public struct Segment: Sendable, Equatable, Identifiable {
    /// Monotonically increasing index from 0, assigned authoritatively by the
    /// orchestrator when a final segment is persisted (§4.1.3).
    public let index: Int

    /// Offset relative to session start, in seconds — NOT wall-clock time (§4.2).
    public let timestamp: TimeInterval

    /// The transcribed text.
    public let text: String

    /// `false` for partial hypotheses (captions only); `true` for confirmed
    /// text written to the document.
    public let isFinal: Bool

    public var id: Int { index }

    public init(index: Int, timestamp: TimeInterval, text: String, isFinal: Bool) {
        self.index = index
        self.timestamp = timestamp
        self.text = text
        self.isFinal = isFinal
    }

    /// Returns a copy with a new `index` (used by the orchestrator to assign the
    /// authoritative monotonic index to a final segment).
    public func reindexed(_ newIndex: Int) -> Segment {
        Segment(index: newIndex, timestamp: timestamp, text: text, isFinal: isFinal)
    }

    /// Returns a copy with a new `timestamp` offset.
    public func restamped(_ newOffset: TimeInterval) -> Segment {
        Segment(index: index, timestamp: newOffset, text: text, isFinal: isFinal)
    }

    /// The segment offset formatted as `HH:MM:SS` for the Markdown line (§9.1).
    public var formattedOffset: String {
        Segment.format(offset: timestamp)
    }

    /// Formats a non-negative time offset (seconds) as `HH:MM:SS`.
    public static func format(offset: TimeInterval) -> String {
        let total = Int(max(0, offset).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
