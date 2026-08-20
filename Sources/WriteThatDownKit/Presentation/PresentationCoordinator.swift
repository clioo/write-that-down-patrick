import AppKit

private let presentationLanguage = AppLanguage.current

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

    private let captionModel: CaptionModel
    private let statusModel: StatusModel
    private let workspaceModel: ConversationWorkspaceModel
    private let conversationLibrary: ConversationLibraryModel
    private let captionSurface: CaptionSurface
    private let statusSurface: StatusSurface
    private let mainWindow: MainWindowController
    private let notifications: NotificationService
    private let recordingPromptSurface = RecordingPromptSurface()
    private let outputDir: URL
    private let conversationAssistant: any ConversationAssistant
    private let credentialStore: OpenCodeGoCredentialStore
    private var assistantAPIKey: String?
    private var answerTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var summaryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
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
        let captionModel = CaptionModel()
        let statusModel = StatusModel()
        let workspaceModel = ConversationWorkspaceModel()
        let conversationLibrary = ConversationLibraryModel(
            outputDir: outputDir,
            currentWorkspace: workspaceModel,
            selectMostRecent: PresentationPreviewMode.current() == nil
        )
        self.captionModel = captionModel
        self.statusModel = statusModel
        self.workspaceModel = workspaceModel
        self.conversationLibrary = conversationLibrary
        self.captionSurface = CaptionSurface(model: captionModel)
        self.statusSurface = StatusSurface(model: statusModel)
        self.mainWindow = MainWindowController(
            statusModel: statusModel,
            captionModel: captionModel,
            workspaceModel: workspaceModel,
            conversationLibrary: conversationLibrary
        )

        let openFolder: () -> Void = { [outputDir] in
            NSWorkspace.shared.open(outputDir)
        }
        self.statusSurface.onOpenFolder = openFolder
        self.statusSurface.onOpenApp = { [weak self] in self?.mainWindow.show() }
        self.mainWindow.onOpenFolder = openFolder
        self.mainWindow.onRevealConversation = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        self.mainWindow.onAsk = { [weak self] question in
            self?.askConversation(question)
        }
        self.mainWindow.onSelectAssistantModel = { [weak self] id in
            self?.selectAssistantModel(id)
        }
        self.mainWindow.onSaveAssistantAPIKey = { [weak self] key in
            self?.saveAssistantAPIKey(key)
        }
        self.mainWindow.onSelectConversation = { [weak self] id in
            self?.selectConversation(id: id)
        }
        self.mainWindow.onRefreshConversations = { [weak self] in
            self?.refreshConversations()
        }
        self.mainWindow.onGenerateSelectedSummary = { [weak self] in
            self?.generateSelectedSummary()
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
        statusSurface.update(
            status: .idle,
            endReason: nil,
            detail: presentationLanguage.text("Waiting for a call…", spanish: "Esperando una llamada…")
        )
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
            statusModel.engineName = presentationLanguage.text("Apple Speech (on-device)", spanish: "Apple Speech (en el dispositivo)")
            statusModel.modelName = presentationLanguage.text("macOS dictation model", spanish: "modelo de dictado de macOS")
        case .sherpa:
            statusModel.engineName = presentationLanguage.text("sherpa-onnx (local)", spanish: "sherpa-onnx (local)")
            statusModel.modelName = option.title
        case .default:
            statusModel.engineName = presentationLanguage.text("WhisperKit (local)", spanish: "WhisperKit (local)")
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
        refreshConversations()
        mainWindow.show()
    }

    private func selectConversation(id: String?) {
        conversationLibrary.selectConversation(id: id)
        if PresentationPreviewMode.current() == nil {
            synchronizeAssistantConfiguration()
        }
    }

    private func refreshConversations() {
        conversationLibrary.refresh()
        if PresentationPreviewMode.current() == nil {
            synchronizeAssistantConfiguration()
        }
    }

    /// Deterministic, network-free fixture used to compare the native window
    /// with the approved product mockup (`WriteThatDown --preview-ui`).
    public func showConversationPreview() {
        let startedAt = prepareConversationPreview()
        statusSurface.update(
            status: .recording,
            endReason: nil,
            detail: presentationLanguage.text("Transcribing this call locally.", spanish: "Transcribiendo esta llamada localmente."),
            recordingSince: startedAt
        )

        workspaceModel.beginConversation(startedAt: startedAt)
        workspaceModel.updateSessionStatus(.recording, startedAt: startedAt)
        workspaceModel.appendUserMessage(presentationLanguage.text(
            "What did we agree about the pilot?",
            spanish: "¿Qué acordamos sobre el piloto?"
        ))
        let responseID = workspaceModel.beginAssistantResponse()
        workspaceModel.appendAssistantDelta(
            presentationLanguage.text(
                "So far, you agreed to launch the pilot on Monday. Marcos will prepare the dashboard, and you will review the metrics.",
                spanish: "Hasta ahora acordaron lanzar el piloto el lunes. Marcos preparará el dashboard y tú revisarás las métricas."
            ),
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
            detail: presentationLanguage.text("Transcript saved.", spanish: "Transcripción guardada.")
        )

        workspaceModel.beginConversation(startedAt: startedAt)
        workspaceModel.updateSessionStatus(.recording, startedAt: startedAt)
        workspaceModel.finishConversation(endedAt: startedAt.addingTimeInterval(24 * 60 + 18))
        workspaceModel.completeSummary(
            presentationLanguage.text(
                """
                Summary
                The team agreed to launch the pilot on Monday after reviewing the key metrics.

                Decisions
                • The pilot starts on Monday.
                • The dashboard will be the reference for evaluating results.

                Next steps
                • Marcos will prepare the dashboard.
                • You will review the metrics before launch.
                """,
                spanish: """
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
        conversationLibrary.installPreviewConversations([
            StoredConversation(
                fileURL: URL(fileURLWithPath: "/tmp/wtd-preview/2026-05-19/15-30_32min.md"),
                title: presentationLanguage.text("Product review", spanish: "Revisión de producto"),
                startedAt: startedAt.addingTimeInterval(-18 * 60 * 60),
                duration: 32 * 60,
                segments: [Segment(index: 0, timestamp: 0, text: presentationLanguage.text("We approved the onboarding update.", spanish: "Aprobamos la actualización de onboarding."), isFinal: true)]
            ),
            StoredConversation(
                fileURL: URL(fileURLWithPath: "/tmp/wtd-preview/2026-05-18/11-00_45min.md"),
                title: presentationLanguage.text("Weekly planning", spanish: "Planeación semanal"),
                startedAt: startedAt.addingTimeInterval(-47 * 60 * 60),
                duration: 45 * 60,
                segments: [Segment(index: 0, timestamp: 0, text: presentationLanguage.text("The team reviewed next week's priorities.", spanish: "El equipo revisó las prioridades de la próxima semana."), isFinal: true)]
            ),
            StoredConversation(
                fileURL: URL(fileURLWithPath: "/tmp/wtd-preview/2026-05-16/09-15_18min.md"),
                title: presentationLanguage.text("Design sync", spanish: "Sincronización de diseño"),
                startedAt: startedAt.addingTimeInterval(-94 * 60 * 60),
                duration: 18 * 60,
                segments: [Segment(index: 0, timestamp: 0, text: presentationLanguage.text("The navigation direction was confirmed.", spanish: "Se confirmó la dirección de navegación."), isFinal: true)]
            ),
        ])
        captionModel.reset()
        captionModel.sessionStartedAt = startedAt
        [
            Segment(index: 0, timestamp: 0, text: presentationLanguage.text("Ana: Then we launch the pilot on Monday.", spanish: "Ana: Entonces lanzamos el piloto el lunes."), isFinal: true),
            Segment(index: 1, timestamp: 60, text: presentationLanguage.text("You: Yes, but first we need to review the metrics.", spanish: "Tú: Sí, pero primero necesitamos revisar las métricas."), isFinal: true),
            Segment(index: 2, timestamp: 120, text: presentationLanguage.text("Marcos: I'll prepare the dashboard.", spanish: "Marcos: Yo preparo el dashboard."), isFinal: true),
        ].forEach(captionModel.appendFinal)
        statusModel.hasSessionContent = true
        for workspace in conversationLibrary.allWorkspaces {
            workspace.isConfigured = true
            workspace.setAssistantModels(
                [
                    .init(id: "gpt-5.6-luna", title: "GPT-5.6 Luna", detail: "OpenCode Go"),
                    .init(id: "glm-5.2", title: "GLM-5.2", detail: "OpenCode Go"),
                ],
                selectedID: "gpt-5.6-luna"
            )
        }
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
        answerTasks.values.forEach { $0.cancel() }
        summaryTasks.values.forEach { $0.cancel() }
        answerTasks.removeAll()
        summaryTasks.removeAll()
        conversationLibrary.selectConversation(id: nil)
        captionSurface.reset()
        statusModel.hasSessionContent = false
        sessionAttempted = true
        captionModel.statusText = presentationLanguage.text("Starting…", spanish: "Iniciando…")
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
                statusModel.modelDetail = presentationLanguage.text(
                    "Downloaded · loads offline",
                    spanish: "Descargado · se carga sin conexión"
                )
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
        conversationLibrary.refresh()
        synchronizeAssistantConfiguration()
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
        notifications.notify(
            title: presentationLanguage.text("Write That Down — Error", spanish: "Write That Down — Error"),
            body: message
        )
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
        for workspace in conversationLibrary.allWorkspaces {
            workspace.setAssistantModels(fallback, selectedID: preferred)
        }

        do {
            assistantAPIKey = try credentialStore.loadAPIKey()
            synchronizeAssistantConfiguration(error: nil)
        } catch {
            assistantAPIKey = nil
            synchronizeAssistantConfiguration(error: error.localizedDescription)
        }

        if assistantAPIKey?.isEmpty == false {
            refreshAssistantModels()
        }
    }

    private func saveAssistantAPIKey(_ rawKey: String) {
        do {
            try credentialStore.saveAPIKey(rawKey)
            assistantAPIKey = try credentialStore.loadAPIKey()
            synchronizeAssistantConfiguration(error: nil)
            refreshAssistantModels()
        } catch {
            assistantAPIKey = nil
            synchronizeAssistantConfiguration(error: error.localizedDescription)
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
                for workspace in self.conversationLibrary.allWorkspaces {
                    workspace.setAssistantModels(options, selectedID: preferred)
                    workspace.configurationError = nil
                }
            } catch {
                self?.synchronizeAssistantConfiguration(error: error.localizedDescription)
            }
        }
    }

    private func selectAssistantModel(_ id: String) {
        guard conversationLibrary.selectedWorkspace.assistantModels.contains(where: { $0.id == id }) else { return }
        for workspace in conversationLibrary.allWorkspaces
        where workspace.assistantModels.contains(where: { $0.id == id }) {
            workspace.selectedAssistantModelID = id
        }
        UserDefaults.standard.set(id, forKey: Self.selectedAssistantModelKey)
    }

    private func synchronizeAssistantConfiguration(error: String? = nil) {
        let configured = assistantAPIKey?.isEmpty == false
        let sourceModels = workspaceModel.assistantModels.isEmpty
            ? PiOpenCodeGoAssistant.fallbackModels.map {
                ConversationWorkspaceModel.AssistantModel(id: $0.id, title: $0.title, detail: "OpenCode Go")
            }
            : workspaceModel.assistantModels
        let preferred = UserDefaults.standard.string(forKey: Self.selectedAssistantModelKey)
            ?? workspaceModel.selectedAssistantModelID
        for workspace in conversationLibrary.allWorkspaces {
            workspace.isConfigured = configured
            workspace.configurationError = error
            workspace.setAssistantModels(sourceModels, selectedID: preferred)
        }
    }

    private func askConversation(_ rawQuestion: String) {
        let workspace = conversationLibrary.selectedWorkspace
        let transcript = conversationLibrary.selectedConversation?.transcriptText
            ?? captionModel.fullTranscriptText
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let apiKey = assistantAPIKey, !apiKey.isEmpty else {
            workspace.configurationError = ConversationAssistantError.missingAPIKey.localizedDescription
            workspace.isConfigured = false
            return
        }
        guard !transcript.isEmpty else {
            workspace.failAssistantResponse(presentationLanguage.text(
                "There is not enough transcript content to answer yet.",
                spanish: "Aún no hay suficiente transcripción para responder."
            ))
            return
        }
        guard !workspace.isAnswering else { return }

        let modelID = workspace.selectedAssistantModelID.isEmpty
            ? PiOpenCodeGoAssistant.defaultModelID
            : workspace.selectedAssistantModelID
        let priorConversation = workspace.messages.compactMap { message -> ConversationAssistantTurn? in
            guard message.errorMessage == nil, !message.content.isEmpty else { return nil }
            return ConversationAssistantTurn(
                role: message.role == .user ? .user : .assistant,
                text: message.content
            )
        }
        workspace.appendUserMessage(question)
        let responseID = workspace.beginAssistantResponse()
        let generation = conversationGeneration
        let assistant = conversationAssistant
        let workspaceID = ObjectIdentifier(workspace)

        answerTasks[workspaceID]?.cancel()
        answerTasks[workspaceID] = Task { [weak self, workspace] in
            do {
                let answer = try await assistant.answer(
                    transcript: transcript,
                    conversation: priorConversation,
                    question: question,
                    modelID: modelID,
                    apiKey: apiKey
                )
                guard let self, self.conversationGeneration == generation else { return }
                workspace.appendAssistantDelta(answer, to: responseID)
                workspace.finishAssistantResponse(responseID)
                self.answerTasks[workspaceID] = nil
            } catch is CancellationError {
                workspace.finishAssistantResponse(responseID)
                self?.answerTasks[workspaceID] = nil
                return
            } catch {
                guard let self, self.conversationGeneration == generation else { return }
                workspace.failAssistantResponse(error.localizedDescription, responseID: responseID)
                self.answerTasks[workspaceID] = nil
            }
        }
    }

    private func generateFinalSummaryIfConfigured() {
        generateSummary(
            transcript: captionModel.fullTranscriptText,
            transcriptPath: statusModel.lastTranscriptPath,
            workspace: workspaceModel
        )
    }

    private func generateSelectedSummary() {
        guard let conversation = conversationLibrary.selectedConversation else { return }
        generateSummary(
            transcript: conversation.transcriptText,
            transcriptPath: conversation.fileURL.path,
            workspace: conversationLibrary.selectedWorkspace
        )
    }

    private func generateSummary(
        transcript: String,
        transcriptPath: String?,
        workspace: ConversationWorkspaceModel
    ) {
        guard let apiKey = assistantAPIKey, !apiKey.isEmpty else {
            workspace.configurationError = ConversationAssistantError.missingAPIKey.localizedDescription
            workspace.isConfigured = false
            return
        }
        guard !transcript.isEmpty else {
            workspace.completeSummary("")
            return
        }
        let modelID = workspace.selectedAssistantModelID.isEmpty
            ? PiOpenCodeGoAssistant.defaultModelID
            : workspace.selectedAssistantModelID
        let generation = conversationGeneration
        let assistant = conversationAssistant
        let workspaceID = ObjectIdentifier(workspace)
        workspace.beginSummary()

        summaryTasks[workspaceID]?.cancel()
        summaryTasks[workspaceID] = Task { [weak self, workspace] in
            do {
                let summary = try await assistant.summarize(
                    transcript: transcript,
                    modelID: modelID,
                    apiKey: apiKey
                )
                guard let self, self.conversationGeneration == generation else { return }
                workspace.completeSummary(summary)
                Self.persistSummary(summary, nextTo: transcriptPath)
                if let transcriptPath {
                    self.conversationLibrary.updatePersistedSummary(summary, transcriptPath: transcriptPath)
                    self.synchronizeAssistantConfiguration()
                }
                self.summaryTasks[workspaceID] = nil
            } catch is CancellationError {
                self?.summaryTasks[workspaceID] = nil
                return
            } catch {
                guard let self, self.conversationGeneration == generation else { return }
                workspace.failSummary(error.localizedDescription)
                self.summaryTasks[workspaceID] = nil
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
            if let reason {
                return presentationLanguage.text(
                    "Last session ended (\(reason.rawValue)). Waiting for a call…",
                    spanish: "La última sesión terminó (\(reason.rawValue)). Esperando una llamada…"
                )
            }
            return presentationLanguage.text("Waiting for a call…", spanish: "Esperando una llamada…")
        case .detected:
            return presentationLanguage.text("Call detected — starting capture…", spanish: "Llamada detectada — iniciando captura…")
        case .recording:
            return presentationLanguage.text("Transcribing this call locally.", spanish: "Transcribiendo esta llamada localmente.")
        case .finalizing:
            return presentationLanguage.text("Saving transcript…", spanish: "Guardando transcripción…")
        case .saved:
            return presentationLanguage.text("Transcript saved.", spanish: "Transcripción guardada.")
        case .failed:
            return presentationLanguage.text("Session failed. Click for details.", spanish: "La sesión falló. Haz clic para ver los detalles.")
        }
    }
}
