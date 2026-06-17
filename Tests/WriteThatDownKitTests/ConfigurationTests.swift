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

    func testStartConfirmDefaultAndValidation() throws {
        XCTAssertEqual(AppConfiguration.default.startConfirmMs, 3_000)
        var c = AppConfiguration.default
        c.startConfirmMs = 0 // allowed: start immediately on mic-on
        XCTAssertNoThrow(try c.validated())
        c.startConfirmMs = -1
        XCTAssertThrowsError(try c.validated())
    }

    func testEngineKindRawValues() {
        XCTAssertEqual(EngineKind(rawValue: "default"), .default)
        XCTAssertEqual(EngineKind(rawValue: "native"), .native)
        XCTAssertNil(EngineKind(rawValue: "bogus"))
    }

    func testTranscriptionEngineOptionFromWhisperConfig() {
        var c = AppConfiguration.default
        c.whisperModel = "openai_whisper-tiny"
        c.whisperModelFolder = URL(fileURLWithPath: "/tmp/openai_whisper-tiny")

        let option = TranscriptionEngineOption.from(c)

        XCTAssertEqual(option.engine, .default)
        XCTAssertEqual(option.id, "whisper:/tmp/openai_whisper-tiny")
        XCTAssertEqual(option.title, "WhisperKit tiny")
        XCTAssertEqual(option.whisperModel, "openai_whisper-tiny")
        XCTAssertEqual(option.whisperModelFolder?.path, "/tmp/openai_whisper-tiny")
    }

    func testTranscriptionEngineOptionFromNativeConfig() {
        var c = AppConfiguration.default
        c.engine = .native

        let option = TranscriptionEngineOption.from(c)

        XCTAssertEqual(option.id, "native")
        XCTAssertEqual(option.engine, .native)
        XCTAssertEqual(option.title, "Apple Speech")
    }
}
