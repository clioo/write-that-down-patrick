import XCTest
@testable import WriteThatDownKit

/// Covers the config-resolution pipeline that backs the JSON config file and
/// the `WTD_*` environment variables: decoding, parsing, override semantics,
/// and precedence. (The app layer only does the I/O around these.)
final class ConfigOverridesTests: XCTestCase {

    // MARK: - JSON decoding (config file format)

    func testDecodeAllKeys() throws {
        let json = """
        {
          "outputDir": "~/CallNotes",
          "language": "es",
          "engine": "native",
          "inactivityTimeoutMs": 600000,
          "pollIntervalMs": 1000,
          "startConfirmMs": 5000,
          "whisperModel": "small",
          "whisperModelFolder": "~/Models/small"
        }
        """
        let o = try ConfigOverrides.decode(fromJSON: Data(json.utf8))
        XCTAssertEqual(o.outputDir, "~/CallNotes")
        XCTAssertEqual(o.language, "es")
        XCTAssertEqual(o.engine, "native")
        XCTAssertEqual(o.inactivityTimeoutMs, 600_000)
        XCTAssertEqual(o.pollIntervalMs, 1_000)
        XCTAssertEqual(o.startConfirmMs, 5_000)
        XCTAssertEqual(o.whisperModel, "small")
        XCTAssertEqual(o.whisperModelFolder, "~/Models/small")
    }

    func testDecodePartialFileLeavesOtherKeysNil() throws {
        let o = try ConfigOverrides.decode(fromJSON: Data(#"{"startConfirmMs": 0}"#.utf8))
        XCTAssertEqual(o.startConfirmMs, 0)
        XCTAssertNil(o.engine)
        XCTAssertNil(o.outputDir)
    }

    func testDecodeMalformedJSONThrows() {
        XCTAssertThrowsError(try ConfigOverrides.decode(fromJSON: Data("{not json".utf8)))
    }

    func testDecodeWrongTypedValueThrows() {
        // A wrong-typed key must fail the decode (loud), not be half-applied.
        XCTAssertThrowsError(try ConfigOverrides.decode(fromJSON: Data(#"{"pollIntervalMs": "2000"}"#.utf8)))
    }

    // MARK: - Environment parsing

    func testFromEnvironmentParsesAllKeys() {
        let env = [
            "WTD_OUTPUT_DIR": "~/Elsewhere",
            "WTD_LANGUAGE": "de",
            "WTD_ENGINE": "default",
            "WTD_INACTIVITY_TIMEOUT_MS": "120000",
            "WTD_POLL_INTERVAL_MS": "500",
            "WTD_START_CONFIRM_MS": "2500",
            "WTD_WHISPER_MODEL": "tiny",
            "WTD_WHISPER_MODEL_FOLDER": "~/Models/tiny",
        ]
        let (o, warnings) = ConfigOverrides.fromEnvironment(env)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(o.outputDir, "~/Elsewhere")
        XCTAssertEqual(o.language, "de")
        XCTAssertEqual(o.engine, "default")
        XCTAssertEqual(o.inactivityTimeoutMs, 120_000)
        XCTAssertEqual(o.pollIntervalMs, 500)
        XCTAssertEqual(o.startConfirmMs, 2_500)
        XCTAssertEqual(o.whisperModel, "tiny")
        XCTAssertEqual(o.whisperModelFolder, "~/Models/tiny")
    }

    func testFromEnvironmentWarnsOnUnparsableInteger() {
        let (o, warnings) = ConfigOverrides.fromEnvironment(["WTD_POLL_INTERVAL_MS": "abc"])
        XCTAssertNil(o.pollIntervalMs, "unparsable integer must not apply")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("WTD_POLL_INTERVAL_MS"), "warning names the offending variable")
    }

    func testFromEnvironmentIgnoresUnrelatedVariables() {
        let (o, warnings) = ConfigOverrides.fromEnvironment(["PATH": "/usr/bin", "HOME": "/Users/x"])
        XCTAssertEqual(o, ConfigOverrides())
        XCTAssertTrue(warnings.isEmpty)
    }

    // MARK: - Applying overrides

    func testApplyingAppliesEachKeyWithTildeExpansion() {
        let base = AppConfiguration.default
        let o = ConfigOverrides(
            outputDir: "~/CallNotes",
            language: "es",
            engine: "native",
            inactivityTimeoutMs: 600_000,
            pollIntervalMs: 1_000,
            startConfirmMs: 5_000,
            whisperModel: "small",
            whisperModelFolder: "~/Models/small"
        )
        let (c, warnings) = base.applying(o)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(c.outputDir.path.contains("~"), "tilde expanded")
        XCTAssertTrue(c.outputDir.path.hasSuffix("/CallNotes"))
        XCTAssertEqual(c.language, "es")
        XCTAssertEqual(c.engine, .native)
        XCTAssertEqual(c.inactivityTimeoutMs, 600_000)
        XCTAssertEqual(c.pollIntervalMs, 1_000)
        XCTAssertEqual(c.startConfirmMs, 5_000)
        XCTAssertEqual(c.whisperModel, "small")
        XCTAssertEqual(c.whisperModelFolder?.path.hasSuffix("/Models/small"), true)
        XCTAssertEqual(c.whisperModelFolder?.path.contains("~"), false)
    }

    func testApplyingEmptyOverridesChangesNothing() {
        let base = AppConfiguration.default
        let (c, warnings) = base.applying(ConfigOverrides())
        XCTAssertEqual(c, base)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testApplyingRejectsEmptyStrings() {
        let base = AppConfiguration.default
        let (c, _) = base.applying(ConfigOverrides(outputDir: "", language: "", whisperModel: ""))
        XCTAssertEqual(c, base, "empty strings must not clobber existing values")
    }

    func testUnknownEngineWarnsAndKeepsCurrent() {
        let base = AppConfiguration.default
        let (c, warnings) = base.applying(ConfigOverrides(engine: "whisperkit"))
        XCTAssertEqual(c.engine, base.engine, "unknown engine string keeps the current engine")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("whisperkit"), "warning names the bad value")
        XCTAssertTrue(warnings[0].contains("default") && warnings[0].contains("native"),
                      "warning lists the valid values")
    }

    func testEngineRawValuesAreCaseSensitive() {
        let base = AppConfiguration.default
        let (c, warnings) = base.applying(ConfigOverrides(engine: "Native"))
        XCTAssertEqual(c.engine, base.engine)
        XCTAssertEqual(warnings.count, 1)
    }

    // MARK: - Excluded apps (call-detection exclusion list)

    func testDefaultExclusionsCoverTerminalsAndSystemAudioHelpers() {
        let defaults = AppConfiguration.default.excludedBundleIDs
        XCTAssertTrue(defaults.contains("com.writethatdown.app"))
        XCTAssertTrue(defaults.contains("com.apple.CoreSpeech"))
        XCTAssertTrue(defaults.contains("com.apple.replayd"))
        XCTAssertTrue(defaults.contains("dev.warp.Warp-Stable"))
        XCTAssertTrue(defaults.contains("com.mitchellh.ghostty"))
        XCTAssertTrue(defaults.contains("com.apple.Terminal"))
        XCTAssertFalse(defaults.isEmpty)
    }

    func testExcludedAppsDecodeFromJSON() throws {
        let o = try ConfigOverrides.decode(fromJSON: Data(#"{"excludedApps": ["com.example.one", "com.example.two"]}"#.utf8))
        XCTAssertEqual(o.excludedApps, ["com.example.one", "com.example.two"])
    }

    func testExcludedAppsFromEnvCommaSeparated() {
        let (o, warnings) = ConfigOverrides.fromEnvironment(
            ["WTD_EXCLUDED_APPS": " com.example.a , com.example.b ,, "])
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(o.excludedApps, ["com.example.a", "com.example.b"], "trims whitespace, drops empties")
    }

    func testExcludedAppsOverrideReplacesDefaults() {
        let base = AppConfiguration.default
        let (c, warnings) = base.applying(ConfigOverrides(excludedApps: ["com.only.this"]))
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(c.excludedBundleIDs, ["com.only.this"], "override REPLACES the default list")
    }

    func testExcludedAppsAbsentKeepsDefaults() {
        let base = AppConfiguration.default
        let (c, _) = base.applying(ConfigOverrides())
        XCTAssertEqual(c.excludedBundleIDs, AppConfiguration.defaultExcludedBundleIDs)
    }

    // MARK: - Precedence (defaults < file < environment)

    func testEnvironmentBeatsFile() {
        let base = AppConfiguration.default
        let fileOverrides = ConfigOverrides(language: "es", startConfirmMs: 5_000)
        let envOverrides = ConfigOverrides(startConfirmMs: 1_000)

        var (c, _) = base.applying(fileOverrides)   // file over defaults
        (c, _) = c.applying(envOverrides)            // env over file

        XCTAssertEqual(c.startConfirmMs, 1_000, "env wins where both set a key")
        XCTAssertEqual(c.language, "es", "file value survives where env is silent")
    }
}
