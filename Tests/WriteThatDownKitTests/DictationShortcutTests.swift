import XCTest
@testable import WriteThatDownKit

final class DictationShortcutTests: XCTestCase {
    func testDefaultShortcutIsCommandE() {
        XCTAssertEqual(DictationShortcut.defaultValue.displayName, "⌘E")
        XCTAssertTrue(DictationShortcut.defaultValue.isValid)
    }

    func testShortcutDisplaysModifiersInStableMacOrder() {
        let shortcut = DictationShortcut(
            keyCode: 8,
            modifiers: [.shift, .command, .control, .option],
            keyLabel: "c"
        )
        XCTAssertEqual(shortcut.displayName, "⌃⌥⇧⌘C")
    }

    func testShortcutRequiresModifierAndKey() {
        XCTAssertFalse(DictationShortcut(keyCode: 14, modifiers: [], keyLabel: "E").isValid)
        XCTAssertFalse(DictationShortcut(keyCode: 14, modifiers: .command, keyLabel: " ").isValid)
    }

    func testShortcutRoundTripsThroughJSON() throws {
        let original = DictationShortcut(
            keyCode: 49,
            modifiers: [.control, .option],
            keyLabel: "Space"
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DictationShortcut.self, from: data), original)
        XCTAssertEqual(original.displayName, "⌃⌥Space")
    }
}
