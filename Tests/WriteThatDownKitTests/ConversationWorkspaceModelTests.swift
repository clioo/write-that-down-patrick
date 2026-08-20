import XCTest
@testable import WriteThatDownKit

final class ConversationWorkspaceModelTests: XCTestCase {
    @MainActor
    func testSavedThenIdleRetainsConversationAndSummary() {
        let model = ConversationWorkspaceModel()
        let startedAt = Date(timeIntervalSince1970: 10_000)

        model.updateSessionStatus(.detected, startedAt: startedAt)
        model.updateSessionStatus(.recording, startedAt: startedAt)
        model.appendUserMessage("¿Qué decidimos?")
        let responseID = model.beginAssistantResponse()
        model.appendAssistantDelta("Lanzar el piloto.", to: responseID)
        model.finishAssistantResponse(responseID)
        model.completeSummary("## Resumen\nLanzar el piloto.")

        model.updateSessionStatus(.saved)
        model.updateSessionStatus(.idle)

        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.summary, .ready("## Resumen\nLanzar el piloto."))
        XCTAssertEqual(model.selectedTab, .summary)
        XCTAssertEqual(model.sessionStartedAt, startedAt)
        XCTAssertNotNil(model.sessionEndedAt)
    }

    @MainActor
    func testRecordingReadyRebasesStartTimeOnce() {
        let model = ConversationWorkspaceModel()
        let detectedAt = Date(timeIntervalSinceReferenceDate: 100)
        let recordingReadyAt = Date(timeIntervalSinceReferenceDate: 112)

        model.beginConversation(startedAt: detectedAt)
        model.updateSessionStatus(.recording, startedAt: recordingReadyAt)

        XCTAssertEqual(model.sessionStartedAt, recordingReadyAt)

        let laterStatusRefresh = Date(timeIntervalSinceReferenceDate: 120)
        model.updateSessionStatus(.recording, startedAt: laterStatusRefresh)
        XCTAssertEqual(model.sessionStartedAt, recordingReadyAt)
    }

    @MainActor
    func testFinishedConfiguredConversationBeginsSummaryAndSurvivesIdle() {
        let model = ConversationWorkspaceModel()
        model.isConfigured = true
        model.updateSessionStatus(.recording, startedAt: Date())

        model.updateSessionStatus(.finalizing)
        model.updateSessionStatus(.idle)

        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.summary, .generating)
        XCTAssertEqual(model.selectedTab, .summary)
    }

    @MainActor
    func testNextDetectedConversationClearsPriorDerivedContent() {
        let model = ConversationWorkspaceModel()
        model.updateSessionStatus(.recording, startedAt: Date())
        model.appendUserMessage("Pregunta anterior")
        model.completeSummary("Resumen anterior")
        model.updateSessionStatus(.saved)
        model.updateSessionStatus(.idle)

        model.updateSessionStatus(.detected, startedAt: Date().addingTimeInterval(60))

        XCTAssertEqual(model.phase, .starting)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.summary, .locked)
        XCTAssertEqual(model.selectedTab, .chat)
    }

    @MainActor
    func testModelSelectionUsesOpenCodeGoCatalogType() {
        let model = ConversationWorkspaceModel()
        let models = [
            OpenCodeGoModelOption(id: "gpt-5.6-luna", title: "GPT-5.6 Luna"),
            OpenCodeGoModelOption(id: "glm-5.2", title: "GLM-5.2"),
        ]

        model.setAssistantModels(models, selectedID: "glm-5.2")

        XCTAssertEqual(model.selectedAssistantModel?.id, "glm-5.2")
    }
}
