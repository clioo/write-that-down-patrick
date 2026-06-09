import Foundation

/// Errors raised by the persistence layer (§10.1 Persistence Failures).
public enum PersistenceError: Error, LocalizedError {
    case notBegun
    case folderCreationFailed(String)
    case writeFailed(String)
    case finalizeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notBegun: return "Transcript writer used before begin()."
        case let .folderCreationFailed(m): return "Could not create transcript folder: \(m)"
        case let .writeFailed(m): return "Could not write transcript: \(m)"
        case let .finalizeFailed(m): return "Could not finalize transcript: \(m)"
        }
    }
}

/// Contract for the Transcript Writer (§3.1.7, §9). Writes final segments to a
/// Markdown document incrementally, applying the folder structure and naming
/// convention. Behind a protocol so the orchestrator is testable without disk.
public protocol TranscriptWriting: AnyObject, Sendable {
    /// Creates the date folder (§9.2) and the file with a provisional header,
    /// then returns the file URL. Must be called once before `appendFinal`.
    @discardableResult
    func begin(session: RecordingSession, title: String, startedAtLocal: Date) throws -> URL

    /// Appends one final segment as its own timestamped line (§9.1), flushing to
    /// disk to honor the no-loss invariant (§10.3). Must follow `begin`.
    func appendFinal(_ segment: Segment) throws

    /// Updates the duration metadata (§9.4) and renames the file to include the
    /// duration (§9.3). Returns the final file URL.
    @discardableResult
    func finalize(duration: TimeInterval) throws -> URL

    /// The current file URL (provisional until finalized), or nil before `begin`.
    var currentFileURL: URL? { get }
}
