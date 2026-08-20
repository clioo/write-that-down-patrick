import AppKit

/// Explicit screenshot fixtures. Detection is intentionally limited to the
/// documented flags and dedicated preview bundle names so a normal
/// `Write That Down.app` launch can never enter fixture mode accidentally.
public enum PresentationPreviewMode: Sendable {
    case chat
    case recordingPrompt
    case summary

    public static func current(
        arguments: [String] = CommandLine.arguments,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> PresentationPreviewMode? {
        if arguments.contains("--preview-recording-prompt") { return .recordingPrompt }
        if arguments.contains("--preview-summary") { return .summary }
        if arguments.contains("--preview-ui") { return .chat }

        let bundleName = bundleURL.deletingPathExtension().lastPathComponent.lowercased()
        if bundleName.contains("recordingpromptpreview") { return .recordingPrompt }
        if bundleName.contains("summarypreview") { return .summary }
        if bundleName.contains("conversationchatpreview") { return .chat }
        return nil
    }

    var showsConversationWindow: Bool {
        switch self {
        case .chat, .summary: true
        case .recordingPrompt: false
        }
    }
}

/// Implements `Presenting` (§3.1.5/§3.1.6) by coordinating the caption HUD, the
/// menu-bar status item, and notifications. Driven solely by the orchestrator;
/// holds no session-correctness state of its own (Appendix A).
@MainActor
public final class PresentationCoordinator: Presenting {

    private let captionModel = CaptionModel()
    private let statusModel = StatusModel()
    private let workspaceModel = ConversationWorkspaceModel()
    private let captionSurface: CaptionSurface
    private let statusSurface: StatusSurface
    private let mainWindow: MainWindowController
    private let notifications: NotificationService
    private let recordingPromptSurface = RecordingPromptSurface()
    private let outputDir: URL
    private let conversationAssistant: any ConversationAssistant
    private let credentialStore: OpenCodeGoCredentialStore
    private var assistantAPIKey: String?
    private var answerTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var conversationGeneration = UUID()

    private static let selectedAssistantModelKey = "openCodeGoAssistantModel"

    /// Wired to the orchestrator's non-blocking ambiguous-source decision APIs.
    public var onAcceptRecordingPrompt: ((UUID) -> Void)? {
        didSet {
            recordingPromptSurface.onAccept = { [weak self] id in
                self?.onAcceptRecordingPrompt?(id)
            }
        }
    }
    public var onDeclineRecordingPrompt: ((UUID) -> Void)? {
        didSet {
            recordingPromptSurface.onDecline = { [weak self] id in
                self?.onDeclineRecordingPrompt?(id)
            }
        }
    }

    /// Wired to the orchestrator's manual-stop entry point.
    public var onManualStop: (() -> Void)? {
        didSet {
            statusSurface.onManualStop = onManualStop
            mainWindow.onStop = { [weak self] in self?.onManualStop?() }
        }
    }
    /// Wired to the app's quit handler.
    public var onQuit: (() -> Void)? {
        didSet {
            statusSurface.onQuit = onQuit
            mainWindow.onQuit = { [weak self] in self?.onQuit?() }
        }
    }
    /// Wired to the app-layer settings persistence.
    public var onSelectEngineOption: ((String) -> Void)? {
        didSet {
            statusSurface.onSelectEngineOption = onSelectEngineOption
            mainWindow.onSelectEngineOption = { [weak self] id in self?.onSelectEngineOption?(id) }
        }
    }
    /// Starts installation for a downloadable catalog model.
    public var onDownloadEngineOption: ((String) -> Void)? {
        didSet {
            statusSurface.onDownloadEngineOption = onDownloadEngineOption
            mainWindow.onDownloadEngineOption = { [weak self] id in self?.onDownloadEngineOption?(id) }
        }
    }
    /// Removes an installed catalog model that is not currently selected.
    public var onDeleteEngineOption: ((String) -> Void)? {
        didSet {
            statusSurface.onDeleteEngineOption = onDeleteEngineOption
            mainWindow.onDeleteEngineOption = { [weak self] id in self?.onDeleteEngineOption?(id) }
        }
    }

    public init(
        outputDir: URL,
        notifications: NotificationService = NotificationService(),
        conversationAssistant: any ConversationAssistant = PiOpenCodeGoAssistant(),
        credentialStore: OpenCodeGoCredentialStore = OpenCodeGoCredentialStore()
    ) {
        self.outputDir = outputDir
        self.notifications = notifications
        self.conversationAssistant = conversationAssistant
        self.credentialStore = credentialStore
        self.captionSurface = CaptionSurface(model: captionModel)
        self.statusSurface = StatusSurface(model: statusModel)
        self.mainWindow = MainWindowController(
            statusModel: statusModel,
            captionModel: captionModel,
            workspaceModel: workspaceModel
        )

        let openFolder: () -> Void = { [outputDir] in
            NSWorkspace.shared.open(outputDir)
        }
        self.statusSurface.onOpenFolder = openFolder
        self.mainWindow.onOpenFolder = openFolder
        self.mainWindow.onAsk = { [weak self] question in
            self?.askConversation(question)
        }
        self.mainWindow.onSelectAssistantModel = { [weak self] id in
            self?.selectAssistantModel(id)
        }
        self.mainWindow.onSaveAssistantAPIKey = { [weak self] key in
            self?.saveAssistantAPIKey(key)
        }

        // Toggle the caption panel mid-meeting without touching the session.
        // Show-on-start / hide-on-finalize (§15.5) still flow from the orchestrator.
        let toggleCaptions: () -> Void = { [weak self] in
            guard let self else { return }
            if self.captionSurface.isVisible {
                self.captionSurface.hide()
                self.statusModel.captionsVisible = false
            } else {
                self.captionSurface.show()
                self.statusModel.captionsVisible = true
            }
        }
        self.statusSurface.onToggleCaptions = toggleCaptions
        self.mainWindow.onToggleCaptions = toggleCaptions
        // Keep the menu-bar mirror in sync when the user closes the panel via
        // its title-bar X button (that path bypasses the toggle handler).
        self.captionSurface.onUserClosed = { [weak self] in
            self?.statusModel.captionsVisible = false
        }
    }

    /// Installs the menu-bar item and requests notification authorization.
    public func install() async {
        statusSurface.install()
        statusSurface.update(status: .idle, endReason: nil, detail: "Waiting for a call…")
        statusModel.outputDirPath = outputDir.path
        installAssistantConfiguration()
        await notifications.requestAuthorization()
    }

    /// Static engine/model info for the popover (set once by the composition
    /// root, which knows the resolved configuration).
    public func setEngineInfo(engineName: String, modelName: String, modelDetail: String) {
        statusModel.engineName = engineName
        statusModel.modelName = modelName
        statusModel.modelDetail = modelDetail
    }

    public func setEngineOptions(
        _ options: [TranscriptionEngineOption],
        selectedID: String,
        installStates: [String: ModelInstallState] = [:]
    ) {
        statusModel.engineOptions = options
        statusModel.selectedEngineOptionID = selectedID
        statusModel.modelInstallStates = installStates
        if let selected = options.first(where: { $0.id == selectedID }) {
            updateSelectedEngineOption(selected, resetHealth: false)
        }
    }

    public func updateModelInstallState(id: String, state: ModelInstallState) {
        statusModel.modelInstallStates[id] = state
    }

    public func updateSelectedEngineOption(_ option: TranscriptionEngineOption, resetHealth: Bool = true) {
        statusModel.selectedEngineOptionID = option.id
        switch option.engine {
        case .native:
            statusModel.engineName = "Apple Speech (on-device)"
            statusModel.modelName = "macOS dictation model"
        case .sherpa:
            statusModel.engineName = "sherpa-onnx (local)"
            statusModel.modelName = option.title
        case .default:
            statusModel.engineName = "WhisperKit (local)"
            statusModel.modelName = option.whisperModel
        }
        statusModel.modelDetail = option.detail
        if resetHealth {
            statusModel.engineHealth = .untested
        }
    }

    /// Shows (or brings forward) the desktop dashboard window — called on
    /// launch and whenever the user re-opens the app from Spotlight/Finder.
    public func showMainWindow() {
        mainWindow.show()
    }

    /// Deterministic, network-free fixture used to compare the native window
    /// with the approved product mockup (`WriteThatDown --preview-ui`).
    public func showConversationPreview() {
        let startedAt = prepareConversationPreview()
        statusSurface.update(
            status: .recording,
            endReason: nil,
            detail: "Transcribing this call locally.",
            recordingSince: startedAt
        )

        workspaceModel.beginConversation(startedAt: startedAt)
        workspaceModel.updateSessionStatus(.recording, startedAt: startedAt)
        workspaceModel.appendUserMessage("¿Qué acordamos sobre el piloto?")
        let responseID = workspaceModel.beginAssistantResponse()
        workspaceModel.appendAssistantDelta(
            "Hasta ahora acordaron lanzar el piloto el lunes. Marcos preparará el dashboard y tú revisarás las métricas.",
            to: responseID
        )
        workspaceModel.finishAssistantResponse(responseID)
        mainWindow.show()
    }

    /// Finished-summary fixture (`--preview-summary` / `SummaryPreview.app`).
    /// It writes no files and never loads credentials or starts Pi.
    public func showConversationSummaryPreview() {
        let startedAt = prepareConversationPreview()
        statusSurface.update(
            status: .saved,
            endReason: .manual,
            detail: "Transcript saved."
        )

        workspaceModel.beginConversation(startedAt: startedAt)
        workspaceModel.updateSessionStatus(.recording, startedAt: startedAt)
        workspaceModel.finishConversation(endedAt: startedAt.addingTimeInterval(24 * 60 + 18))
        workspaceModel.completeSummary(
            """
            Resumen
            El equipo acordó lanzar el piloto el lunes después de revisar las métricas principales.

            Decisiones
            • El piloto comienza el lunes.
            • El dashboard será la referencia para evaluar los resultados.

            Próximos pasos
            • Marcos preparará el dashboard.
            • Tú revisarás las métricas antes del lanzamiento.
            """
        )
        mainWindow.show()
    }

    /// Ambiguous-source fixture (`--preview-recording-prompt` /
    /// `RecordingPromptPreview.app`). Accepting or declining exits cleanly.
    public func showRecordingPromptPreview() {
        recordingPromptSurface.onAccept = { _ in NSApp.terminate(nil) }
        recordingPromptSurface.onDecline = { _ in NSApp.terminate(nil) }
        recordingPromptSurface.show(
            RecordingPrompt(
                context: DetectedCallContext(
                    fingerprint: "whatsApp|net.whatsapp.WhatsApp",
                    kind: .whatsApp,
                    sourceName: "WhatsApp",
                    sourceBundleIDs: ["net.whatsapp.WhatsApp"]
                )
            )
        )
    }

    private func prepareConversationPreview() -> Date {
        // Preview windows are visual fixtures, not a second application mode.
        // Keep their controls inert so clicking around cannot touch Pi,
        // Keychain, UserDefaults, or Finder.
        mainWindow.onAsk = { _ in }
        mainWindow.onSelectAssistantModel = { _ in }
        mainWindow.onSaveAssistantAPIKey = { _ in }
        mainWindow.onOpenFolder = {}

        let startedAt = Self.previewStartedAt
        captionModel.reset()
        captionModel.sessionStartedAt = startedAt
        [
            Segment(index: 0, timestamp: 0, text: "Ana: Entonces lanzamos el piloto el lunes.", isFinal: true),
            Segment(index: 1, timestamp: 60, text: "Tú: Sí, pero primero necesitamos revisar las métricas.", isFinal: true),
            Segment(index: 2, timestamp: 120, text: "Marcos: Yo preparo el dashboard.", isFinal: true),
        ].forEach(captionModel.appendFinal)
        statusModel.hasSessionContent = true
        workspaceModel.isConfigured = true
        workspaceModel.setAssistantModels(
            [
                .init(id: "gpt-5.6-luna", title: "GPT-5.6 Luna", detail: "OpenCode Go"),
                .init(id: "glm-5.2", title: "GLM-5.2", detail: "OpenCode Go"),
            ],
            selectedID: "gpt-5.6-luna"
        )
        return startedAt
    }

    private static var previewStartedAt: Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 5
        components.day = 20
        components.hour = 10
        components.minute = 14
        return components.date ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    // MARK: Presenting

    /// True between a session attempt starting and returning to idle — used to
    /// tell pipeline failures apart from pre-pipeline permission blocks.
    private var sessionAttempted = false

    public func sessionWillStart(session: RecordingSession) {
        conversationGeneration = UUID()
        answerTask?.cancel()
        summaryTask?.cancel()
        captionSurface.reset()
        statusModel.hasSessionContent = false
        sessionAttempted = true
        captionModel.statusText = "Starting…"
        captionModel.sessionStartedAt = session.startedAt
        workspaceModel.beginConversation(startedAt: session.startedAt)
        mainWindow.showForConversation()
    }

    public func showCaptions() {
        // Do NOT set statusText here — updateStatus is the single writer.
        captionSurface.show()
        statusModel.captionsVisible = true
    }

    public func hideCaptions() {
        captionSurface.hide()
        statusModel.captionsVisible = false
        captionModel.sessionStartedAt = nil
        // Preserve hasSessionContent so the idle toggle can reopen the panel
        // for review/copy until the next session starts.
    }

    public func showPartial(_ segment: Segment) {
        captionSurface.showPartial(segment.text)
    }

    public func commitFinal(_ segment: Segment) {
        captionSurface.commitFinal(segment)
        statusModel.hasSessionContent = true
    }

    public func updateStatus(_ status: SessionStatus, endReason: EndReason?) {
        if status == .recording {
            // Re-baseline BOTH visible clocks (menu bar + caption header) at
            // recording-ready: model load can take seconds and must not show as
            // pre-elapsed time. This also keeps the clocks consistent with the
            // capture-relative segment offsets in the transcript.
            captionModel.sessionStartedAt = Date()
        }
        statusSurface.update(
            status: status,
            endReason: endReason,
            detail: Self.detail(for: status, reason: endReason),
            recordingSince: status == .recording ? captionModel.sessionStartedAt : nil
        )
        captionModel.statusText = statusModel.headline
        workspaceModel.updateSessionStatus(
            status,
            startedAt: captionModel.sessionStartedAt,
            error: status == .failed ? statusModel.detail : nil
        )
        // Pipeline health, derived from session outcomes: reaching Recording
        // proves engine + capture + writer all initialized.
        if status == .recording {
            statusModel.engineHealth = .healthy(Date())
            // Recording also proves the model is on disk now; freshen a stale
            // "not downloaded yet" hint from launch time.
            if statusModel.modelDetail.hasPrefix("Not downloaded") {
                statusModel.modelDetail = "Downloaded · loads offline"
            }
        }
        if status == .idle {
            // Next presentError before any sessionWillStart is a pre-pipeline
            // block (permissions), not an engine failure.
            sessionAttempted = false
        }
        if status == .saved {
            generateFinalSummaryIfConfigured()
        }
    }

    public func notifyCallStarted(session: RecordingSession) {
        notifications.notifyCallStarted(session: session)
    }

    public func showRecordingPrompt(_ prompt: RecordingPrompt) {
        recordingPromptSurface.show(prompt)
    }

    public func hideRecordingPrompt(id: UUID) {
        recordingPromptSurface.hide(id: id)
    }

    public func updateTranscriptPath(_ path: String?) {
        statusModel.lastTranscriptPath = path
    }

    public func presentError(_ message: String) {
        Log.presentation.error("User-visible error: \(message, privacy: .public)")
        // Permission blocks happen BEFORE any session attempt — the engine was
        // never tested, so don't label it "Failed".
        statusModel.engineHealth = sessionAttempted ? .failed(message) : .blocked(message)
        // Surface via the status item (already done by the caller setting .failed)
        // and a notification banner — both are visible without stealing focus.
        // A modal NSAlert with NSApp.activate would yank keyboard focus away from
        // the meeting app at exactly the wrong moment (spec §10.2 only requires
        // the error be visible, not blocking).
        statusSurface.update(status: .failed, endReason: .error, detail: message)
        notifications.notify(title: "Write That Down — Error", body: message)
    }

    // MARK: OpenCode Go meeting assistant

    private func installAssistantConfiguration() {
        let fallback = PiOpenCodeGoAssistant.fallbackModels.map {
            ConversationWorkspaceModel.AssistantModel(
                id: $0.id,
                title: $0.title,
                detail: "OpenCode Go"
            )
        }
        let preferred = UserDefaults.standard.string(forKey: Self.selectedAssistantModelKey)
            ?? PiOpenCodeGoAssistant.defaultModelID
        workspaceModel.setAssistantModels(fallback, selectedID: preferred)

        do {
            assistantAPIKey = try credentialStore.loadAPIKey()
            workspaceModel.isConfigured = assistantAPIKey?.isEmpty == false
            workspaceModel.configurationError = nil
        } catch {
            assistantAPIKey = nil
            workspaceModel.isConfigured = false
            workspaceModel.configurationError = error.localizedDescription
        }

        if workspaceModel.isConfigured {
            refreshAssistantModels()
        }
    }

    private func saveAssistantAPIKey(_ rawKey: String) {
        do {
            try credentialStore.saveAPIKey(rawKey)
            assistantAPIKey = try credentialStore.loadAPIKey()
            workspaceModel.isConfigured = assistantAPIKey?.isEmpty == false
            workspaceModel.configurationError = nil
            refreshAssistantModels()
        } catch {
            workspaceModel.isConfigured = false
            workspaceModel.configurationError = error.localizedDescription
        }
    }

    private func refreshAssistantModels() {
        guard let apiKey = assistantAPIKey, !apiKey.isEmpty else { return }
        let assistant = conversationAssistant
        Task { [weak self] in
            do {
                let models = try await assistant.availableModels(apiKey: apiKey)
                guard let self else { return }
                let options = models.map {
                    ConversationWorkspaceModel.AssistantModel(
                        id: $0.id,
                        title: $0.title,
                        detail: "OpenCode Go"
                    )
                }
                let preferred = UserDefaults.standard.string(forKey: Self.selectedAssistantModelKey)
                    ?? PiOpenCodeGoAssistant.defaultModelID
                self.workspaceModel.setAssistantModels(options, selectedID: preferred)
                self.workspaceModel.configurationError = nil
            } catch {
                self?.workspaceModel.configurationError = error.localizedDescription
            }
        }
    }

    private func selectAssistantModel(_ id: String) {
        guard workspaceModel.assistantModels.contains(where: { $0.id == id }) else { return }
        workspaceModel.selectedAssistantModelID = id
        UserDefaults.standard.set(id, forKey: Self.selectedAssistantModelKey)
    }

    private func askConversation(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let apiKey = assistantAPIKey, !apiKey.isEmpty else {
            workspaceModel.configurationError = ConversationAssistantError.missingAPIKey.localizedDescription
            workspaceModel.isConfigured = false
            return
        }
        guard !captionModel.fullTranscriptText.isEmpty else {
            workspaceModel.failAssistantResponse("Aún no hay suficiente transcripción para responder.")
            return
        }
        guard !workspaceModel.isAnswering else { return }

        let modelID = workspaceModel.selectedAssistantModelID.isEmpty
            ? PiOpenCodeGoAssistant.defaultModelID
            : workspaceModel.selectedAssistantModelID
        let transcript = captionModel.fullTranscriptText
        let priorConversation = workspaceModel.messages.compactMap { message -> ConversationAssistantTurn? in
            guard message.errorMessage == nil, !message.content.isEmpty else { return nil }
            return ConversationAssistantTurn(
                role: message.role == .user ? .user : .assistant,
                text: message.content
            )
        }
        workspaceModel.appendUserMessage(question)
        let responseID = workspaceModel.beginAssistantResponse()
        let generation = conversationGeneration
        let assistant = conversationAssistant

        answerTask?.cancel()
        answerTask = Task { [weak self] in
            do {
                let answer = try await assistant.answer(
                    transcript: transcript,
                    conversation: priorConversation,
                    question: question,
                    modelID: modelID,
                    apiKey: apiKey
                )
                guard let self, self.conversationGeneration == generation else { return }
                self.workspaceModel.appendAssistantDelta(answer, to: responseID)
                self.workspaceModel.finishAssistantResponse(responseID)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.conversationGeneration == generation else { return }
                self.workspaceModel.failAssistantResponse(error.localizedDescription, responseID: responseID)
            }
        }
    }

    private func generateFinalSummaryIfConfigured() {
        guard let apiKey = assistantAPIKey, !apiKey.isEmpty else { return }
        let transcript = captionModel.fullTranscriptText
        guard !transcript.isEmpty else {
            workspaceModel.completeSummary("")
            return
        }
        let modelID = workspaceModel.selectedAssistantModelID.isEmpty
            ? PiOpenCodeGoAssistant.defaultModelID
            : workspaceModel.selectedAssistantModelID
        let generation = conversationGeneration
        let transcriptPath = statusModel.lastTranscriptPath
        let assistant = conversationAssistant
        workspaceModel.beginSummary()

        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            do {
                let summary = try await assistant.summarize(
                    transcript: transcript,
                    modelID: modelID,
                    apiKey: apiKey
                )
                guard let self, self.conversationGeneration == generation else { return }
                self.workspaceModel.completeSummary(summary)
                Self.persistSummary(summary, nextTo: transcriptPath)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.conversationGeneration == generation else { return }
                self.workspaceModel.failSummary(error.localizedDescription)
            }
        }
    }

    private nonisolated static func persistSummary(_ summary: String, nextTo transcriptPath: String?) {
        guard let transcriptPath else { return }
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        let base = transcriptURL.deletingPathExtension().lastPathComponent
        let summaryURL = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("\(base)-summary.md")
        let document = "# Meeting summary\n\n\(summary)\n"
        do {
            try document.write(to: summaryURL, atomically: true, encoding: .utf8)
        } catch {
            Log.persistence.error("Could not persist AI summary: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func detail(for status: SessionStatus, reason: EndReason?) -> String {
        switch status {
        case .idle:
            if let reason { return "Last session ended (\(reason.rawValue)). Waiting for a call…" }
            return "Waiting for a call…"
        case .detected: return "Call detected — starting capture…"
        case .recording: return "Transcribing this call locally."
        case .finalizing: return "Saving transcript…"
        case .saved: return "Transcript saved."
        case .failed: return "Session failed. Click for details."
        }
    }
}
