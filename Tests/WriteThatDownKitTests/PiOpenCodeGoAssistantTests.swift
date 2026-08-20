import Foundation
import XCTest
@testable import WriteThatDownKit

final class PiOpenCodeGoAssistantTests: XCTestCase {
    func testAnswerPinsSelectedProviderAndIsolatesPi() async throws {
        let fixture = try PiFixture()
        defer { fixture.remove() }
        let secret = "test-key-that-must-not-be-an-argument"
        let credentials = PiProviderCredentialStore(serviceName: "com.writethatdown.tests.\(UUID().uuidString)")
        let credentialData = try JSONSerialization.data(withJSONObject: ["type": "api_key", "key": secret])
        try credentials.saveCredentialData(credentialData, for: "opencode-go")
        defer { try? credentials.deleteCredential(for: "opencode-go") }
        let assistant = PiOpenCodeGoAssistant(
            piExecutable: fixture.executable,
            runtimeDirectory: fixture.runtimeDirectory,
            credentialStore: credentials,
            requestTimeout: 10
        )

        let answer = try await assistant.answer(
            transcript: "PRIVATE TRANSCRIPT SENTINEL",
            conversation: [.init(role: .assistant, text: "Earlier answer")],
            question: "QUESTION SENTINEL",
            providerID: "opencode-go",
            modelID: "gpt-5.6-luna"
        )

        XCTAssertEqual(answer, "Verified response")
        XCTAssertTrue(try fixture.read("auth.txt").contains(secret))

        let arguments = try fixture.read("arguments.txt")
        XCTAssertTrue(arguments.contains("<--provider>\n<opencode-go>"))
        XCTAssertTrue(arguments.contains("<--model>\n<gpt-5.6-luna>"))
        XCTAssertTrue(arguments.contains("<--no-tools>"))
        XCTAssertTrue(arguments.contains("<--no-extensions>"))
        XCTAssertTrue(arguments.contains("<--no-skills>"))
        XCTAssertTrue(arguments.contains("<--no-prompt-templates>"))
        XCTAssertTrue(arguments.contains("<--no-context-files>"))
        XCTAssertTrue(arguments.contains("<--no-session>"))
        XCTAssertTrue(arguments.contains("<--no-approve>"))
        XCTAssertTrue(arguments.contains("<--offline>"))
        XCTAssertFalse(arguments.contains("<--api-key>"))
        XCTAssertFalse(arguments.contains(secret))
        XCTAssertFalse(arguments.contains("PRIVATE TRANSCRIPT SENTINEL"))
        XCTAssertFalse(arguments.contains("QUESTION SENTINEL"))

        let standardInput = try fixture.read("stdin.txt")
        XCTAssertTrue(standardInput.contains("PRIVATE TRANSCRIPT SENTINEL"))
        XCTAssertTrue(standardInput.contains("QUESTION SENTINEL"))
        XCTAssertFalse(standardInput.contains(secret))

        let piDirectory = try fixture.read("pi-dir.txt")
        let sessionDirectory = try fixture.read("session-dir.txt")
        XCTAssertTrue(piDirectory.contains("wtd-pi-"))
        XCTAssertTrue(sessionDirectory.contains("wtd-pi-"))
        XCTAssertNotEqual(piDirectory, fixture.runtimeDirectory.path)
        XCTAssertNotEqual(sessionDirectory, fixture.runtimeDirectory.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: piDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory))
    }

    func testModelListParserFiltersSelectedProviderAndDeduplicates() {
        let output = """
        provider     model
        opencode-go  gpt-5.6-luna
        openai       gpt-from-another-provider
        opencode-go  glm-5.3
        opencode-go  gpt-5.6-luna
        """
        let models = PiOpenCodeGoAssistant.parseModelList(output, provider: "opencode-go")
        XCTAssertEqual(models, [
            .init(id: "gpt-5.6-luna", title: "GPT-5.6 Luna"),
            .init(id: "glm-5.3", title: "Glm 5.3"),
        ])
        XCTAssertFalse(models.contains { $0.id == "gpt-from-another-provider" })
    }

    func testProviderAndModelValidationRejectOptionInjection() throws {
        XCTAssertEqual(try PiOpenCodeGoAssistant.validatedModelID("openai/gpt-5.6"), "openai/gpt-5.6")
        XCTAssertEqual(try PiOpenCodeGoAssistant.validatedProviderID("openai-codex"), "openai-codex")
        XCTAssertThrowsError(try PiOpenCodeGoAssistant.validatedModelID("--provider"))
        XCTAssertThrowsError(try PiOpenCodeGoAssistant.validatedModelID("model\n--tools"))
        XCTAssertThrowsError(try PiOpenCodeGoAssistant.validatedModelID("model --tools"))
        XCTAssertThrowsError(try PiOpenCodeGoAssistant.validatedProviderID("--provider"))
        XCTAssertThrowsError(try PiOpenCodeGoAssistant.validatedProviderID("openai/codex"))
    }

    func testQuestionPromptUsesOnlyRecentHistory() {
        let turns = (0..<14).map { index in
            ConversationAssistantTurn(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "turn-\(index)"
            )
        }

        let prompt = PiOpenCodeGoAssistant.questionPrompt(
            transcript: "meeting facts",
            conversation: turns,
            question: "What was decided?"
        )

        XCTAssertFalse(prompt.contains("turn-0\n"))
        XCTAssertFalse(prompt.contains("turn-1\n"))
        XCTAssertTrue(prompt.contains("turn-2"))
        XCTAssertTrue(prompt.contains("turn-13"))
        XCTAssertTrue(prompt.contains("meeting facts"))
        XCTAssertTrue(prompt.contains("What was decided?"))
    }

    func testAssistantJSONParserUsesFinalAssistantText() throws {
        let events = """
        {"type":"message_start","message":{"role":"assistant"}}
        {"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":" First response "}]}}
        {"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"ignore me"}]}}
        {"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Final "},{"type":"text","text":"answer"}]}}
        """

        XCTAssertEqual(try PiOpenCodeGoAssistant.parseAssistantText(events), "Final answer")
    }

    func testAssistantJSONParserSurfacesProviderError() {
        let event = """
        {"type":"message_end","message":{"role":"assistant","errorMessage":"upstream rejected request","content":[]}}
        """

        XCTAssertThrowsError(try PiOpenCodeGoAssistant.parseAssistantText(event)) { error in
            XCTAssertEqual(
                error as? ConversationAssistantError,
                .requestFailed("upstream rejected request")
            )
        }
    }
}

private final class PiFixture {
    let root: URL
    let executable: URL
    let runtimeDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtd-pi-tests-\(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("fake-pi")
        runtimeDirectory = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: runtimeDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static let script = #"""
    #!/bin/sh
    printf '<%s>\n' "$@" > "$PWD/arguments.txt"
    printf '%s' "${PI_CODING_AGENT_DIR-}" > "$PWD/pi-dir.txt"
    printf '%s' "${PI_CODING_AGENT_SESSION_DIR-}" > "$PWD/session-dir.txt"
    cp "${PI_CODING_AGENT_DIR}/auth.json" "$PWD/auth.txt"
    cat > "$PWD/stdin.txt"

    case " $* " in
      *" --list-models opencode-go "*)
        printf '%s\n' \
          'provider     model                       context  max-out  thinking  images' \
          'opencode-go  gpt-5.6-luna                200K     64K      yes       yes' \
          'openai       gpt-from-another-provider   128K     32K      yes       no' \
          'opencode-go  glm-5.3                     200K     64K      yes       no' \
          'opencode-go  gpt-5.6-luna                200K     64K      yes       yes'
        ;;
      *)
        printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Verified response"}]}}'
        ;;
    esac
    """#
}
