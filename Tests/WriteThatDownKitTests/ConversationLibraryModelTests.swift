import XCTest
@testable import WriteThatDownKit

final class ConversationLibraryModelTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtd-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testStoreLoadsConversationsNewestFirstAndRestoresSummary() throws {
        let older = try writeTranscript(
            folder: "2026-08-18",
            name: "09-30_12min.md",
            date: "2026-08-18 09:30",
            duration: "12 min",
            lines: ["[00:00:02] Older decision"]
        )
        let newer = try writeTranscript(
            folder: "2026-08-19",
            name: "14-05_3min.md",
            date: "2026-08-19 14:05",
            duration: "3 min",
            lines: ["[00:00:01] Newer line", "[00:01:02] Follow-up"]
        )
        let summaryURL = newer.deletingLastPathComponent()
            .appendingPathComponent("14-05_3min-summary.md")
        try "# Meeting summary\n\nA concise summary.\n".write(to: summaryURL, atomically: true, encoding: .utf8)

        let loaded = ConversationLibraryStore(outputDir: tempDir).load()

        XCTAssertEqual(
            loaded.map { $0.fileURL.standardizedFileURL },
            [newer, older].map { $0.standardizedFileURL }
        )
        XCTAssertEqual(loaded[0].duration, 180)
        XCTAssertEqual(loaded[0].segments.map(\.text), ["Newer line", "Follow-up"])
        XCTAssertEqual(loaded[0].segments[1].timestamp, 62)
        XCTAssertEqual(loaded[0].savedSummary, "A concise summary.")
    }

    func testStoreIgnoresEmptyProvisionalSummaryAndUnrelatedMarkdown() throws {
        _ = try writeTranscript(
            folder: "2026-08-19",
            name: "10-00_0min.md",
            date: "2026-08-19 10:00",
            duration: "0 min",
            lines: []
        )
        _ = try writeTranscript(
            folder: "2026-08-19",
            name: "10-01_recording_.md",
            date: "2026-08-19 10:01",
            duration: "recording…",
            lines: ["[00:00:01] Still recording"]
        )
        try "# unrelated".write(
            to: tempDir.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(ConversationLibraryStore(outputDir: tempDir).load().isEmpty)
    }

    @MainActor
    func testLibrarySelectsMostRecentAndCanReturnToCurrentConversation() throws {
        let url = try writeTranscript(
            folder: "2026-08-19",
            name: "14-05_3min.md",
            date: "2026-08-19 14:05",
            duration: "3 min",
            lines: ["[00:00:01] Saved line"]
        )
        let current = ConversationWorkspaceModel()
        let library = ConversationLibraryModel(outputDir: tempDir, currentWorkspace: current)

        XCTAssertEqual(library.selectedConversationID, url.standardizedFileURL.path)
        XCTAssertEqual(library.selectedWorkspace.phase, .finished)
        XCTAssertEqual(library.selectedTranscriptText, "[00:00:01] Saved line")

        library.selectConversation(id: nil)
        XCTAssertNil(library.selectedConversationID)
        XCTAssertTrue(library.selectedWorkspace === current)
    }

    @discardableResult
    private func writeTranscript(
        folder: String,
        name: String,
        date: String,
        duration: String,
        lines: [String]
    ) throws -> URL {
        let folderURL = tempDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let url = folderURL.appendingPathComponent(name)
        let body = ([
            "# Call \(date)",
            "**Date:** \(date)",
            "**Duration:** \(duration)",
            "",
            "## Transcript",
        ] + lines).joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
