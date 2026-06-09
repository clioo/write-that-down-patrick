import XCTest
@testable import WriteThatDownKit

final class ConfigurationTests: XCTestCase {

    func testDefaults() {
        let c = AppConfiguration.default
        XCTAssertEqual(c.engine, .default)
        XCTAssertEqual(c.inactivityTimeoutMs, 900_000)
        XCTAssertEqual(c.pollIntervalMs, 2_000)
        XCTAssertTrue(c.outputDir.path.hasSuffix("Transcripts"))
        XCTAssertFalse(c.outputDir.path.contains("~"))
        XCTAssertFalse(c.language.isEmpty)
    }

    func testTildeExpansion() {
        let url = AppConfiguration.expandTilde("~/Transcripts")
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertTrue(url.path.hasSuffix("/Transcripts"))
        XCTAssertTrue(url.path.hasPrefix("/"))
    }

    func testValidatedSucceedsForDefault() throws {
        XCTAssertNoThrow(try AppConfiguration.default.validated())
    }

    func testValidationRejectsNonPositivePoll() {
        var c = AppConfiguration.default
        c.pollIntervalMs = 0
        XCTAssertThrowsError(try c.validated()) { error in
            XCTAssertEqual(error as? ConfigurationError, .nonPositive(field: "poll_interval_ms", value: 0))
        }
    }

    func testValidationRejectsNonPositiveInactivity() {
        var c = AppConfiguration.default
        c.inactivityTimeoutMs = -1
        XCTAssertThrowsError(try c.validated())
    }

    func testValidationRejectsEmptyLanguage() {
        var c = AppConfiguration.default
        c.language = "   "
        XCTAssertThrowsError(try c.validated()) { error in
            XCTAssertEqual(error as? ConfigurationError, .emptyLanguage)
        }
    }

    func testValidationRejectsOutOfRangeThreshold() {
        var c = AppConfiguration.default
        c.activityThresholdRMS = 5
        XCTAssertThrowsError(try c.validated())
    }

    func testEngineKindRawValues() {
        XCTAssertEqual(EngineKind(rawValue: "default"), .default)
        XCTAssertEqual(EngineKind(rawValue: "native"), .native)
        XCTAssertNil(EngineKind(rawValue: "bogus"))
    }
}
