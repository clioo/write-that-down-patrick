import Foundation

/// Concrete `TranscriptWriting` (§3.1.7, §9). Writes a Markdown transcript with
/// the §9.1 structure, organizes files by date folder (§9.2), names them by
/// start time + duration (§9.3), and persists final segments incrementally to
/// honor the no-loss invariant (§9.4, §10.3).
///
/// While recording, the file is named `HH-MM_recording.md` (duration unknown).
/// On `finalize` the duration header is filled in and the file is renamed to
/// `HH-MM_<n>min.md`. If finalize fails, the provisional file is left in place
/// with all already-appended segments intact (never silently lost, §10.2).
public final class TranscriptWriter: TranscriptWriting, @unchecked Sendable {

    /// Sentinel written in place of the duration until finalization.
    private static let durationPlaceholder = "recording…"

    private let outputDir: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    private var handle: FileHandle?
    private var fileURL: URL?
    private var startedAt: Date?

    public init(outputDir: URL, fileManager: FileManager = .default) {
        self.outputDir = outputDir
        self.fileManager = fileManager
    }

    public var currentFileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return fileURL
    }

    // MARK: - begin

    @discardableResult
    public func begin(session: RecordingSession, title: String, startedAtLocal: Date) throws -> URL {
        lock.lock(); defer { lock.unlock() }

        // 1. Date folder (§9.2) — created if it does not exist.
        let folder = outputDir.appendingPathComponent(Self.dateFolderName(startedAtLocal), isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.folderCreationFailed("\(folder.path): \(error.localizedDescription)")
        }

        // 2. Provisional file name (§9.3, sanitized §4.2).
        let name = Self.sanitize("\(Self.timeName(startedAtLocal))_\(Self.durationPlaceholder).md")
        let url = folder.appendingPathComponent(name, isDirectory: false)

        // 3. Header (§9.1) with provisional duration.
        let header = """
        # \(title)
        **Date:** \(Self.headerDate(startedAtLocal))
        **Duration:** \(Self.durationPlaceholder)

        ## Transcript

        """
        do {
            try header.data(using: .utf8)!.write(to: url, options: .atomic)
            let h = try FileHandle(forWritingTo: url)
            do {
                try h.seekToEnd()
            } catch {
                // Don't leak the descriptor or leave an orphaned placeholder file.
                try? h.close()
                try? fileManager.removeItem(at: url)
                throw error
            }
            self.handle = h
        } catch {
            // If the header file was created before the failure, remove it so no
            // orphaned "recording…" placeholder is left behind.
            try? fileManager.removeItem(at: url)
            throw PersistenceError.writeFailed("\(url.path): \(error.localizedDescription)")
        }

        self.fileURL = url
        self.startedAt = startedAtLocal
        Log.persistence.info("Transcript begun at \(url.path, privacy: .public).")
        return url
    }

    // MARK: - appendFinal

    public func appendFinal(_ segment: Segment) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw PersistenceError.notBegun }

        // One final segment per line, with its timestamp (§9.1). Newlines inside
        // text are flattened so each segment stays on one line.
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let line = "[\(segment.formattedOffset)] \(oneLine)\n"
        do {
            try handle.write(contentsOf: Data(line.utf8))
            try handle.synchronize() // flush to disk now (no-loss, §10.3)
        } catch {
            throw PersistenceError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - finalize

    @discardableResult
    public func finalize(duration: TimeInterval) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL else { throw PersistenceError.notBegun }

        try? handle?.synchronize()
        try? handle?.close()
        handle = nil

        let minutes = max(0, Int((duration / 60).rounded()))

        // Update the duration header in place (§9.4).
        do {
            var contents = try String(contentsOf: url, encoding: .utf8)
            contents = contents.replacingOccurrences(
                of: "**Duration:** \(Self.durationPlaceholder)",
                with: "**Duration:** \(minutes) min"
            )
            try contents.data(using: .utf8)!.write(to: url, options: .atomic)
        } catch {
            // Leave the provisional file intact — content is preserved (§10.2).
            throw PersistenceError.finalizeFailed("updating duration: \(error.localizedDescription)")
        }

        // Rename to include duration (§9.3).
        let startedAt = self.startedAt ?? Date(timeIntervalSinceReferenceDate: 0)
        let finalName = Self.sanitize("\(Self.timeName(startedAt))_\(minutes)min.md")
        let finalURL = url.deletingLastPathComponent().appendingPathComponent(finalName, isDirectory: false)

        if finalURL != url {
            // If a same-named file somehow exists, disambiguate rather than clobber.
            var target = finalURL
            var counter = 2
            while fileManager.fileExists(atPath: target.path) {
                let alt = Self.sanitize("\(Self.timeName(startedAt))_\(minutes)min_\(counter).md")
                target = url.deletingLastPathComponent().appendingPathComponent(alt, isDirectory: false)
                counter += 1
            }
            do {
                try fileManager.moveItem(at: url, to: target)
                self.fileURL = target
            } catch {
                // Rename failure is non-fatal: the (duration-updated) provisional
                // file is fully preserved.
                Log.persistence.error("Rename to \(target.lastPathComponent, privacy: .public) failed: \(error.localizedDescription)")
            }
        }

        Log.persistence.info("Transcript finalized at \(self.fileURL?.path ?? "?", privacy: .public) (\(minutes) min).")
        return self.fileURL ?? url
    }

    // MARK: - Formatting helpers

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current // local time (§4.2, §9.2)
        f.dateFormat = format
        return f
    }

    static func dateFolderName(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
    static func timeName(_ date: Date) -> String { formatter("HH-mm").string(from: date) }
    static func headerDate(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: date) }

    /// Replaces any character outside `[A-Za-z0-9._-]` with `_` (§4.2).
    static func sanitize(_ name: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return String(name.map { allowed.contains($0) ? $0 : "_" })
    }
}
