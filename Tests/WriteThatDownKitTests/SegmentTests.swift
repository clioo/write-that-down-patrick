import XCTest
@testable import WriteThatDownKit

final class SegmentTests: XCTestCase {

    func testFormatOffset() {
        XCTAssertEqual(Segment.format(offset: 0), "00:00:00")
        XCTAssertEqual(Segment.format(offset: 61), "00:01:01")
        XCTAssertEqual(Segment.format(offset: 3661), "01:01:01")
        XCTAssertEqual(Segment.format(offset: 3599), "00:59:59")
    }

    func testFormatOffsetClampsNegative() {
        XCTAssertEqual(Segment.format(offset: -5), "00:00:00")
    }

    func testFormattedOffsetOnSegment() {
        let seg = Segment(index: 0, timestamp: 125, text: "hello", isFinal: true)
        XCTAssertEqual(seg.formattedOffset, "00:02:05")
    }

    func testReindexAndRestamp() {
        let seg = Segment(index: 0, timestamp: 1, text: "x", isFinal: true)
        XCTAssertEqual(seg.reindexed(7).index, 7)
        XCTAssertEqual(seg.restamped(9).timestamp, 9)
        // Other fields preserved.
        XCTAssertEqual(seg.reindexed(7).text, "x")
        XCTAssertTrue(seg.reindexed(7).isFinal)
    }

    func testSanitizeFilename() {
        XCTAssertEqual(TranscriptWriter.sanitize("a b/c:d"), "a_b_c_d")
        XCTAssertEqual(TranscriptWriter.sanitize("14-25_3min.md"), "14-25_3min.md")
        // Every disallowed character (space, slash, colon, star, question mark)
        // becomes a single underscore; allowed punctuation (. _ -) is kept.
        XCTAssertEqual(TranscriptWriter.sanitize("a/b*c?d e.md"), "a_b_c_d_e.md")
    }

    func testSanitizeKeepsAllowedSet() {
        let allowed = "ABZabz0-9._-"
        XCTAssertEqual(TranscriptWriter.sanitize(allowed), allowed)
    }

    func testSessionIDFormat() {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 6; c.hour = 14; c.minute = 25; c.second = 30
        let date = Calendar.current.date(from: c)!
        let id = RecordingSession.makeID(from: date)
        XCTAssertEqual(id, "session-20260606-142530")
    }

    func testAudioBufferRMS() {
        XCTAssertEqual(AudioBuffer(samples: [], sampleRate: 16_000).rms, 0)
        XCTAssertEqual(AudioBuffer(samples: [0, 0, 0], sampleRate: 16_000).rms, 0)
        let half = AudioBuffer(samples: [0.5, -0.5, 0.5, -0.5], sampleRate: 16_000)
        XCTAssertEqual(half.rms, 0.5, accuracy: 0.0001)
    }
}
