import XCTest
@testable import WriteThatDownKit

final class TranscriptWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wtd-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func fixedDate() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 6; c.hour = 14; c.minute = 25; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func makeSession(_ date: Date) -> RecordingSession {
        RecordingSession(id: RecordingSession.makeID(from: date), startedAt: date, status: .recording)
    }

    func testBeginCreatesDateFolderAndFile() throws {
        let writer = TranscriptWriter(outputDir: tempDir)
        let date = fixedDate()
        let url = try writer.begin(session: makeSession(date), title: "Call", startedAtLocal: date)

        let folder = tempDir.appendingPathComponent("2026-06-06", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "date folder must be created (§9.2)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("14-25_"), "name uses start time (§9.3)")
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))

        let header = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(header.contains("# Call"))
        XCTAssertTrue(header.contains("**Date:** 2026-06-06 14:25"))
        XCTAssertTrue(header.contains("## Transcript"))
    }

    func testIncrementalAppendPersistsImmediately() throws {
        let writer = TranscriptWriter(outputDir: tempDir)
        let date = fixedDate()
        let url = try writer.begin(session: makeSession(date), title: "Call", startedAtLocal: date)

        try writer.appendFinal(Segment(index: 0, timestamp: 5, text: "First line", isFinal: true))
        // Persisted before finalize (no-loss, §9.4/§10.3).
        var contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("[00:00:05] First line"))

        try writer.appendFinal(Segment(index: 1, timestamp: 70, text: "Second line", isFinal: true))
        contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("[00:01:10] Second line"))
    }

    func testNewlinesInSegmentAreFlattened() throws {
        let writer = TranscriptWriter(outputDir: tempDir)
        let date = fixedDate()
        let url = try writer.begin(session: makeSession(date), title: "Call", startedAtLocal: date)
        try writer.appendFinal(Segment(index: 0, timestamp: 0, text: "line one\nline two", isFinal: true))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("[00:00:00] line one line two"))
    }

    func testFinalizeUpdatesDurationAndRenames() throws {
        let writer = TranscriptWriter(outputDir: tempDir)
        let date = fixedDate()
        _ = try writer.begin(session: makeSession(date), title: "Call", startedAtLocal: date)
        try writer.appendFinal(Segment(index: 0, timestamp: 1, text: "hi", isFinal: true))

        let finalURL = try writer.finalize(duration: 185) // 3 min (rounded)
        XCTAssertEqual(finalURL.lastPathComponent, "14-25_3min.md", "name uses start time + duration (§9.3)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))

        let contents = try String(contentsOf: finalURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("**Duration:** 3 min"), "duration updated on finalize (§9.4)")
        XCTAssertFalse(contents.contains("recording…"))
        XCTAssertTrue(contents.contains("[00:00:01] hi"), "appended content preserved through finalize")
    }

    func testAppendBeforeBeginThrows() {
        let writer = TranscriptWriter(outputDir: tempDir)
        XCTAssertThrowsError(try writer.appendFinal(Segment(index: 0, timestamp: 0, text: "x", isFinal: true)))
    }

    func testEmptySegmentsAreSkipped() throws {
        let writer = TranscriptWriter(outputDir: tempDir)
        let date = fixedDate()
        let url = try writer.begin(session: makeSession(date), title: "Call", startedAtLocal: date)
        try writer.appendFinal(Segment(index: 0, timestamp: 0, text: "   ", isFinal: true))
        let contents = try String(contentsOf: url, encoding: .utf8)
        // No transcript line should have been written for whitespace-only text.
        XCTAssertFalse(contents.contains("[00:00:00]"))
    }
}
