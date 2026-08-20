import XCTest
@testable import WriteThatDownKit

final class AppLanguageTests: XCTestCase {
    func testSpanishVariantsSelectSpanish() {
        for identifier in ["es", "es-MX", "es_419"] {
            XCTAssertEqual(resolve(identifier), .spanish)
        }
    }

    func testEnglishVariantsSelectEnglish() {
        for identifier in ["en", "en-US", "en_GB"] {
            XCTAssertEqual(resolve(identifier), .english)
        }
    }

    func testUnsupportedPrimaryLanguageFallsBackToEnglish() {
        XCTAssertEqual(
            AppLanguage.resolve(
                arguments: [],
                environment: [:],
                preferredLanguages: ["fr-FR", "es-MX"]
            ),
            .english
        )
    }

    func testPreviewOverrideWinsOverSystemLanguage() {
        XCTAssertEqual(
            AppLanguage.resolve(
                arguments: ["WriteThatDown", "--ui-language=en"],
                environment: ["WTD_UI_LANGUAGE": "es"],
                preferredLanguages: ["es-MX"]
            ),
            .english
        )
    }

    func testLocalizedTextUsesSelectedLanguage() {
        XCTAssertEqual(AppLanguage.english.text("Record", spanish: "Grabar"), "Record")
        XCTAssertEqual(AppLanguage.spanish.text("Record", spanish: "Grabar"), "Grabar")
    }

    private func resolve(_ identifier: String) -> AppLanguage {
        AppLanguage.resolve(
            arguments: [],
            environment: [:],
            preferredLanguages: [identifier]
        )
    }
}
