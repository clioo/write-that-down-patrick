import AppKit
import SwiftUI

private let conversationLanguage = AppLanguage.current

/// The primary conversation window. Closing it leaves capture running and the
/// menu-bar surface available.
@MainActor
public final class MainWindowController {
    // Versioned so an older 760x420 dashboard frame cannot force the new
    // conversation workspace into an unusably small saved size.
    private static let frameAutosaveName = "WTDConversationWindowV3"

    private let statusModel: StatusModel
    private let captionModel: CaptionModel
    private let workspaceModel: ConversationWorkspaceModel
    private let conversationLibrary: ConversationLibraryModel
    private var window: NSWindow?

    // Existing actions remain available to the coordinator and status surface.
    var onStop: () -> Void = {}
    var onToggleCaptions: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onSelectEngineOption: (String) -> Void = { _ in }
    var onDownloadEngineOption: (String) -> Void = { _ in }
    var onDeleteEngineOption: (String) -> Void = { _ in }
    var onQuit: () -> Void = {}

    // Conversation-assistant actions. Credentials are collected by the Pi
    // bridge and are never retained by a presentation model.
    var onAsk: (String) -> Void = { _ in }
    var onSelectAssistantProvider: (String) -> Void = { _ in }
    var onSelectAssistantModel: (String) -> Void = { _ in }
    var onConnectAssistantProvider: (String, PiProviderAuthMethod.Kind) -> Void = { _, _ in }
    var onDisconnectAssistantProvider: (String) -> Void = { _ in }
    var onSubmitAuthPrompt: (String) -> Void = { _ in }
    var onCancelAuth: () -> Void = {}
    var onRefreshAssistantProviders: () -> Void = {}
    var onSelectConversation: (String?) -> Void = { _ in }
    var onRefreshConversations: () -> Void = {}
    var onGenerateSelectedSummary: () -> Void = {}
    var onRevealConversation: (String) -> Void = { _ in }

    public init(
        statusModel: StatusModel,
        captionModel: CaptionModel,
        workspaceModel: ConversationWorkspaceModel = ConversationWorkspaceModel(),
        conversationLibrary: ConversationLibraryModel
    ) {
        self.statusModel = statusModel
        self.captionModel = captionModel
        self.workspaceModel = workspaceModel
        self.conversationLibrary = conversationLibrary
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Write That Down"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1_180, height: 620)
        if ConversationPreviewArguments.isEnabled {
            window.appearance = NSAppearance(named: .aqua)
        }
        window.contentView = NSHostingView(
            rootView: MainWindowView(
                statusModel: statusModel,
                captionModel: captionModel,
                workspaceModel: workspaceModel,
                conversationLibrary: conversationLibrary,
                onStop: { [weak self] in self?.onStop() },
                onOpenFolder: { [weak self] in self?.onOpenFolder() },
                onSelectEngineOption: { [weak self] id in self?.onSelectEngineOption(id) },
                onDownloadEngineOption: { [weak self] id in self?.onDownloadEngineOption(id) },
                onDeleteEngineOption: { [weak self] id in self?.onDeleteEngineOption(id) },
                onAsk: { [weak self] question in self?.onAsk(question) },
                onSelectAssistantProvider: { [weak self] id in self?.onSelectAssistantProvider(id) },
                onSelectAssistantModel: { [weak self] id in self?.onSelectAssistantModel(id) },
                onConnectAssistantProvider: { [weak self] provider, type in self?.onConnectAssistantProvider(provider, type) },
                onDisconnectAssistantProvider: { [weak self] provider in self?.onDisconnectAssistantProvider(provider) },
                onSubmitAuthPrompt: { [weak self] value in self?.onSubmitAuthPrompt(value) },
                onCancelAuth: { [weak self] in self?.onCancelAuth() },
                onRefreshAssistantProviders: { [weak self] in self?.onRefreshAssistantProviders() },
                onSelectConversation: { [weak self] id in self?.onSelectConversation(id) },
                onRefreshConversations: { [weak self] in self?.onRefreshConversations() },
                onGenerateSelectedSummary: { [weak self] in self?.onGenerateSelectedSummary() },
                onRevealConversation: { [weak self] path in self?.onRevealConversation(path) }
            )
            .preferredColorScheme(ConversationPreviewArguments.isEnabled ? .light : nil)
        )
        let isPreview = ConversationPreviewArguments.isEnabled
        if isPreview {
            window.center()
        } else {
            if !window.setFrameUsingName(Self.frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        self.window = window
    }

    /// User-initiated show: activates the accessory app and focuses the window.
    public func show() {
        makeWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Automatic meeting show: makes the workspace visible without pulling the
    /// keyboard away from Zoom, Meet, Teams, or another active call app.
    public func showForConversation() {
        makeWindowIfNeeded()
        window?.orderFrontRegardless()
    }
}

// MARK: - Window composition

private struct MainWindowView: View {
    @ObservedObject var statusModel: StatusModel
    @ObservedObject var captionModel: CaptionModel
    @ObservedObject var workspaceModel: ConversationWorkspaceModel
    @ObservedObject var conversationLibrary: ConversationLibraryModel
    var onStop: () -> Void
    var onOpenFolder: () -> Void
    var onSelectEngineOption: (String) -> Void
    var onDownloadEngineOption: (String) -> Void
    var onDeleteEngineOption: (String) -> Void
    var onAsk: (String) -> Void
    var onSelectAssistantProvider: (String) -> Void
    var onSelectAssistantModel: (String) -> Void
    var onConnectAssistantProvider: (String, PiProviderAuthMethod.Kind) -> Void
    var onDisconnectAssistantProvider: (String) -> Void
    var onSubmitAuthPrompt: (String) -> Void
    var onCancelAuth: () -> Void
    var onRefreshAssistantProviders: () -> Void
    var onSelectConversation: (String?) -> Void
    var onRefreshConversations: () -> Void
    var onGenerateSelectedSummary: () -> Void
    var onRevealConversation: (String) -> Void

    @State private var transcriptCopied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var settingsSheetShown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                ConversationSidebar(
                    model: conversationLibrary,
                    isRecording: statusModel.canStop,
                    onSelect: onSelectConversation,
                    onRefresh: onRefreshConversations
                )

                Divider()

                ConversationTranscriptPane(
                    segments: displayedSegments,
                    partial: displayedPartial,
                    startedAt: effectiveStartedAt
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ConversationAssistantPane(
                    model: selectedWorkspace,
                    onAsk: onAsk,
                    onSelectModel: { id in
                        selectedWorkspace.selectedAssistantModelID = id
                        onSelectAssistantModel(id)
                    },
                    onConfigure: { settingsSheetShown = true },
                    canGenerateSummary: conversationLibrary.selectedConversation != nil,
                    onGenerateSummary: onGenerateSelectedSummary
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            privacyFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $settingsSheetShown) {
            ApplicationSettingsSheet(
                workspace: selectedWorkspace,
                statusModel: statusModel,
                onSelectProvider: onSelectAssistantProvider,
                onConnectProvider: onConnectAssistantProvider,
                onDisconnectProvider: onDisconnectAssistantProvider,
                onSubmitAuthPrompt: onSubmitAuthPrompt,
                onCancelAuth: onCancelAuth,
                onRefreshProviders: onRefreshAssistantProviders,
                onSelectEngine: onSelectEngineOption,
                onDownloadEngine: onDownloadEngineOption,
                onDeleteEngine: onDeleteEngineOption
            )
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private var effectiveStartedAt: Date? {
        selectedWorkspace.sessionStartedAt ?? captionModel.sessionStartedAt
    }

    private var selectedWorkspace: ConversationWorkspaceModel {
        conversationLibrary.selectedWorkspace
    }

    private var displayedSegments: [Segment] {
        conversationLibrary.selectedConversation?.segments ?? captionModel.finals
    }

    private var displayedPartial: String {
        conversationLibrary.selectedConversation == nil ? captionModel.partial : ""
    }

    private var selectedTranscriptText: String {
        conversationLibrary.selectedConversation?.transcriptText ?? captionModel.fullTranscriptText
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 10) {
                    statusBadge
                    if effectiveStartedAt != nil {
                        durationBadge
                    }
                }
            }

            Spacer(minLength: 24)

            Button {
                settingsSheetShown = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(conversationLanguage.text("Settings", spanish: "Configuración"))

            Button(action: copyTranscript) {
                Label(
                    transcriptCopied
                        ? conversationLanguage.text("Copied", spanish: "Copiado")
                        : conversationLanguage.text("Copy", spanish: "Copiar"),
                    systemImage: transcriptCopied ? "checkmark" : "doc.on.doc"
                )
                    .frame(minWidth: 82)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(displayedSegments.isEmpty)
            .accessibilityLabel(conversationLanguage.text("Copy transcript", spanish: "Copiar transcripción"))

            if statusModel.canStop && conversationLibrary.selectedConversation == nil {
                Button(action: onStop) {
                    Label(conversationLanguage.text("End", spanish: "Terminar"), systemImage: "stop.fill")
                        .frame(minWidth: 94)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: [.command])
            } else if selectedWorkspace.phase == .finished {
                Button(action: revealSelectedConversation) {
                    Label(conversationLanguage.text("View file", spanish: "Ver archivo"), systemImage: "doc.text")
                        .frame(minWidth: 94)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(minHeight: 128)
    }

    private var title: String {
        switch selectedWorkspace.phase {
        case .idle: return conversationLanguage.text("Ready for a conversation", spanish: "Listo para una conversación")
        case .starting: return conversationLanguage.text("Preparing the conversation", spanish: "Preparando la conversación")
        case .live: return conversationLanguage.text("Conversation in progress", spanish: "Conversación en curso")
        case .finalizing: return conversationLanguage.text("Finishing the conversation", spanish: "Terminando la conversación")
        case .finished: return conversationLanguage.text("Conversation finished", spanish: "Conversación terminada")
        case .failed: return conversationLanguage.text("The conversation ended with an error", spanish: "La conversación terminó con un error")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let presentation = statusPresentation
        Label(presentation.text, systemImage: presentation.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(presentation.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(presentation.color.opacity(0.11), in: Capsule())
    }

    private var statusPresentation: (text: String, symbol: String, color: Color) {
        switch selectedWorkspace.phase {
        case .idle: return (conversationLanguage.text("Waiting", spanish: "Esperando"), "waveform", .secondary)
        case .starting: return (conversationLanguage.text("Starting", spanish: "Iniciando"), "waveform", .orange)
        case .live: return (conversationLanguage.text("Transcribing", spanish: "Transcribiendo"), "waveform", .green)
        case .finalizing: return (conversationLanguage.text("Saving", spanish: "Guardando"), "square.and.arrow.down", .orange)
        case .finished: return (conversationLanguage.text("Saved", spanish: "Guardada"), "checkmark.circle.fill", .green)
        case .failed: return (conversationLanguage.text("Error", spanish: "Error"), "exclamationmark.triangle.fill", .red)
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock")
            if ConversationPreviewArguments.isEnabled {
                Text("24:18")
                    .monospacedDigit()
            } else if let startedAt = effectiveStartedAt,
               selectedWorkspace.phase == .live || selectedWorkspace.phase == .starting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.formatDuration(context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                }
            } else {
                Text(Self.formatDuration(selectedWorkspace.duration ?? 0))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private var privacyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text(conversationLanguage.text("Audio and files stay on your Mac", spanish: "El audio y el archivo permanecen en tu Mac"))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(conversationLanguage.text(
                "AI context is sent to the selected provider",
                spanish: "El contexto de IA se envía al proveedor seleccionado"
            ))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedTranscriptText, forType: .string)
        transcriptCopied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { transcriptCopied = false }
        }
    }

    private func revealSelectedConversation() {
        if let path = conversationLibrary.selectedConversation?.fileURL.path {
            onRevealConversation(path)
        } else {
            onOpenFolder()
        }
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Conversation navigation

private struct ConversationSidebar: View {
    @ObservedObject var model: ConversationLibraryModel
    let isRecording: Bool
    let onSelect: (String?) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(conversationLanguage.text("Conversations", spanish: "Conversaciones"))
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(conversationLanguage.text("Refresh conversations", spanish: "Actualizar conversaciones"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            conversationButton(
                id: nil,
                title: conversationLanguage.text("Current conversation", spanish: "Conversación actual"),
                subtitle: isRecording
                    ? conversationLanguage.text("Recording now", spanish: "Grabando ahora")
                    : conversationLanguage.text("Ready to record", spanish: "Lista para grabar"),
                symbol: isRecording ? "waveform.circle.fill" : "waveform",
                tint: isRecording ? .red : .secondary
            )
            .padding(.horizontal, 8)

            HStack {
                Text(conversationLanguage.text("Recent", spanish: "Recientes"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 7)

            if model.conversations.isEmpty {
                Text(conversationLanguage.text(
                    "Saved conversations will appear here.",
                    spanish: "Las conversaciones guardadas aparecerán aquí."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.conversations) { conversation in
                            conversationButton(
                                id: conversation.id,
                                title: Self.dateFormatter.string(from: conversation.startedAt),
                                subtitle: durationText(conversation.duration),
                                symbol: "text.document",
                                tint: ConversationPalette.accent
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 228)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.035))
    }

    private func conversationButton(
        id: String?,
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color
    ) -> some View {
        let selected = model.selectedConversationID == id
        return Button {
            onSelect(id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                selected ? ConversationPalette.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int((duration / 60).rounded()))
        if minutes == 1 {
            return conversationLanguage.text("1 minute", spanish: "1 minuto")
        }
        return conversationLanguage.text("\(minutes) minutes", spanish: "\(minutes) minutos")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, HH:mm")
        return formatter
    }()
}

// MARK: - Transcript pane

private struct ConversationTranscriptPane: View {
    let segments: [Segment]
    let partial: String
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(conversationLanguage.text("Live transcript", spanish: "Transcripción en vivo"))
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 22)

            if segments.isEmpty && partial.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(conversationLanguage.text("The transcript will appear here", spanish: "La transcripción aparecerá aquí"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(conversationLanguage.text(
                        "Write That Down will start showing text when it detects the conversation.",
                        spanish: "Write That Down comenzará a mostrar texto cuando detecte la conversación."
                    ))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 310)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(segments) { segment in
                                transcriptRow(segment)
                                    .id(segment.id)
                            }

                            if !partial.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 18) {
                                    Text("…")
                                        .frame(width: 48, alignment: .leading)
                                        .foregroundStyle(.tertiary)
                                    Text(partial)
                                        .foregroundStyle(.secondary)
                                        .italic()
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 14))
                                .padding(.vertical, 15)
                                .id("conversation-partial")
                            }

                            Color.clear.frame(height: 1).id("conversation-live-edge")
                        }
                        .padding(.horizontal, 32)
                    }
                    .onChange(of: segments.count) { _ in
                        DispatchQueue.main.async {
                            proxy.scrollTo("conversation-live-edge", anchor: .bottom)
                        }
                    }
                    .onChange(of: partial) { _ in
                        DispatchQueue.main.async {
                            proxy.scrollTo("conversation-live-edge", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func transcriptRow(_ segment: Segment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(displayTime(for: segment))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
                .textSelection(.enabled)

            Text(segment.text)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 17)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func displayTime(for segment: Segment) -> String {
        guard let startedAt else {
            let total = max(0, Int(segment.timestamp.rounded(.down)))
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return Self.timeFormatter.string(from: startedAt.addingTimeInterval(segment.timestamp))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - Assistant pane

private struct ConversationAssistantPane: View {
    @ObservedObject var model: ConversationWorkspaceModel
    var onAsk: (String) -> Void
    var onSelectModel: (String) -> Void
    var onConfigure: () -> Void
    var canGenerateSummary: Bool
    var onGenerateSummary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(conversationLanguage.text("Ask the conversation", spanish: "Pregúntale a la conversación"))
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.78)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                providerControl
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 8)

            HStack(spacing: 24) {
                tabButton(.chat, title: "Chat")
                HStack(spacing: 7) {
                    tabButton(.summary, title: conversationLanguage.text("Summary", spanish: "Resumen"))
                    if model.phase == .live || model.phase == .starting || model.phase == .finalizing {
                        Text(conversationLanguage.text("when finished", spanish: "al terminar"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(height: 52, alignment: .bottom)
            .overlay(alignment: .bottom) { Divider() }

            switch model.selectedTab {
            case .chat:
                ConversationChatView(model: model, onAsk: onAsk, onConfigure: onConfigure)
            case .summary:
                ConversationSummaryView(
                    model: model,
                    onConfigure: onConfigure,
                    canGenerateSummary: canGenerateSummary,
                    onGenerateSummary: onGenerateSummary
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var providerControl: some View {
        if model.isConfigured {
            HStack(spacing: 4) {
                Menu {
                    if model.assistantModels.isEmpty {
                        Text(conversationLanguage.text("No models available", spanish: "No hay modelos disponibles"))
                    } else {
                        ForEach(model.assistantModels) { option in
                            Button {
                                onSelectModel(option.id)
                            } label: {
                                if option.id == model.selectedAssistantModelID {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(ConversationPalette.accent)
                        Text(providerLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isAnswering)

                Button(action: onConfigure) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(conversationLanguage.text("Configure AI providers", spanish: "Configurar proveedores de IA"))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .font(.system(size: 12))
            .background(Color.secondary.opacity(0.06), in: Capsule())
            .overlay { Capsule().stroke(Color.secondary.opacity(0.18)) }
        } else {
            Button(action: onConfigure) {
                Label(conversationLanguage.text("Connect a provider", spanish: "Conectar un proveedor"), systemImage: "sparkles")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var providerLabel: String {
        if let option = model.selectedAssistantModel {
            return "\(model.selectedAssistantProvider?.name ?? "Pi") · \(option.title)"
        }
        return model.selectedAssistantProvider?.name ?? "Pi"
    }

    private func tabButton(_ tab: ConversationWorkspaceModel.Tab, title: String) -> some View {
        Button {
            model.selectedTab = tab
        } label: {
            Text(title)
                .font(.system(size: 14, weight: model.selectedTab == tab ? .semibold : .regular))
                .foregroundStyle(model.selectedTab == tab ? ConversationPalette.accent : Color.secondary)
                .padding(.bottom, 11)
                .overlay(alignment: .bottom) {
                    if model.selectedTab == tab {
                        Rectangle()
                            .fill(ConversationPalette.accent)
                            .frame(height: 2)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationChatView: View {
    @ObservedObject var model: ConversationWorkspaceModel
    var onAsk: (String) -> Void
    var onConfigure: () -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !model.isConfigured {
                AssistantConfigurationEmptyState(
                    title: conversationLanguage.text("Connect an AI provider to chat", spanish: "Conecta un proveedor de IA para chatear"),
                    detail: conversationLanguage.text(
                        "Provider connections and models come directly from your installed Pi catalog.",
                        spanish: "Las conexiones y modelos vienen directamente del catálogo de Pi instalado."
                    ),
                    action: onConfigure
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty {
                VStack(spacing: 11) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 26))
                        .foregroundStyle(ConversationPalette.accent)
                    Text(conversationLanguage.text("Ask about this conversation", spanish: "Pregunta sobre esta conversación"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(conversationLanguage.text(
                        "Ask about decisions, action items, or any detail in the transcript.",
                        spanish: "Puedes preguntar por decisiones, pendientes o cualquier detalle de la transcripción."
                    ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 330)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messages
            }

            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(model.messages) { message in
                        ConversationMessageBubble(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("chat-live-edge")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .onChange(of: model.messages) { _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("chat-live-edge", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                conversationLanguage.text("Ask about this conversation…", spanish: "Pregunta sobre esta conversación…"),
                text: $draft,
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($composerFocused)
                .disabled(!model.isConfigured || model.isAnswering)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(ConversationPalette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.45)
            .accessibilityLabel(conversationLanguage.text("Send question", spanish: "Enviar pregunta"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var canSubmit: Bool {
        model.isConfigured && !model.isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isConfigured, !model.isAnswering, !question.isEmpty else { return }
        draft = ""
        onAsk(question)
    }
}

private struct ConversationMessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationWorkspaceModel.Message

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 70)
                bubble
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                    .background(
                        ConversationPalette.accent.opacity(colorScheme == .dark ? 0.42 : 0.13),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                    )
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(ConversationPalette.accent)
                    .frame(width: 30, height: 30)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .overlay { Circle().stroke(Color.secondary.opacity(0.2)) }

                bubble
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                Spacer(minLength: 48)
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
            if let error = message.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct ConversationSummaryView: View {
    @ObservedObject var model: ConversationWorkspaceModel
    var onConfigure: () -> Void
    var canGenerateSummary: Bool
    var onGenerateSummary: () -> Void

    var body: some View {
        Group {
            if !model.isConfigured {
                AssistantConfigurationEmptyState(
                    title: conversationLanguage.text("Connect an AI provider to generate a summary", spanish: "Conecta un proveedor de IA para generar el resumen"),
                    detail: conversationLanguage.text("The summary will be created when the conversation ends.", spanish: "El resumen se creará al terminar la conversación."),
                    action: onConfigure
                )
            } else {
                summaryContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var summaryContent: some View {
        switch model.summary {
        case .locked:
            VStack(spacing: 11) {
                Image(systemName: "lock")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text(model.phase == .finished
                    ? conversationLanguage.text("Summary pending", spanish: "Resumen pendiente")
                    : conversationLanguage.text("Available when finished", spanish: "Disponible al terminar"))
                    .font(.system(size: 15, weight: .semibold))
                Text(conversationLanguage.text(
                    "\(model.selectedAssistantProvider?.name ?? "The selected provider") will summarize key points, decisions, and next steps.",
                    spanish: "\(model.selectedAssistantProvider?.name ?? "El proveedor seleccionado") resumirá los puntos importantes, decisiones y próximos pasos."
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                if canGenerateSummary && model.phase == .finished {
                    Button(
                        conversationLanguage.text("Generate summary", spanish: "Generar resumen"),
                        action: onGenerateSummary
                    )
                    .buttonStyle(.borderedProminent)
                    .tint(ConversationPalette.accent)
                }
            }

        case .generating:
            VStack(spacing: 12) {
                ProgressView()
                Text(conversationLanguage.text("Preparing the summary…", spanish: "Preparando el resumen…"))
                    .font(.system(size: 14, weight: .medium))
                Text(conversationLanguage.text("The transcript is already saved on your Mac.", spanish: "La transcripción ya está guardada en tu Mac."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case let .ready(text):
            ScrollView {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }

        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 25))
                    .foregroundStyle(.tertiary)
                Text(conversationLanguage.text("There was not enough content to summarize", spanish: "No hubo suficiente contenido para resumir"))
                    .font(.system(size: 14, weight: .semibold))
            }

        case let .failed(message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 25))
                    .foregroundStyle(.red)
                Text(conversationLanguage.text("The summary could not be generated", spanish: "No se pudo generar el resumen"))
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
    }
}

private struct AssistantConfigurationEmptyState: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(ConversationPalette.accent)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button(conversationLanguage.text("Configure providers", spanish: "Configurar proveedores"), action: action)
                .buttonStyle(.borderedProminent)
                .tint(ConversationPalette.accent)
        }
        .padding(28)
    }
}

// MARK: - Settings

private struct ApplicationSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: ConversationWorkspaceModel
    @ObservedObject var statusModel: StatusModel
    let onSelectProvider: (String) -> Void
    let onConnectProvider: (String, PiProviderAuthMethod.Kind) -> Void
    let onDisconnectProvider: (String) -> Void
    let onSubmitAuthPrompt: (String) -> Void
    let onCancelAuth: () -> Void
    let onRefreshProviders: () -> Void
    let onSelectEngine: (String) -> Void
    let onDownloadEngine: (String) -> Void
    let onDeleteEngine: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(conversationLanguage.text("Settings", spanish: "Configuración"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(conversationLanguage.text("Done", spanish: "Listo")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()

            TabView {
                ProviderSettingsView(
                    workspace: workspace,
                    onSelectProvider: onSelectProvider,
                    onConnectProvider: onConnectProvider,
                    onDisconnectProvider: onDisconnectProvider,
                    onSubmitAuthPrompt: onSubmitAuthPrompt,
                    onCancelAuth: onCancelAuth,
                    onRefreshProviders: onRefreshProviders
                )
                .tabItem {
                    Label(conversationLanguage.text("AI Providers", spanish: "Proveedores de IA"), systemImage: "sparkles")
                }

                TranscriptionSettingsView(
                    model: statusModel,
                    onSelect: onSelectEngine,
                    onDownload: onDownloadEngine,
                    onDelete: onDeleteEngine
                )
                .tabItem {
                    Label(conversationLanguage.text("Transcription", spanish: "Transcripción"), systemImage: "waveform")
                }
            }
            .padding(16)
        }
        .frame(width: 820, height: 620)
        .onDisappear { if workspace.isConnectingProvider { onCancelAuth() } }
    }
}

private struct ProviderSettingsView: View {
    @ObservedObject var workspace: ConversationWorkspaceModel
    let onSelectProvider: (String) -> Void
    let onConnectProvider: (String, PiProviderAuthMethod.Kind) -> Void
    let onDisconnectProvider: (String) -> Void
    let onSubmitAuthPrompt: (String) -> Void
    let onCancelAuth: () -> Void
    let onRefreshProviders: () -> Void
    @State private var search = ""
    @State private var promptValue = ""

    private var filteredProviders: [PiProviderOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspace.assistantProviders }
        return workspace.assistantProviders.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                TextField(conversationLanguage.text("Search providers", spanish: "Buscar proveedores"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                List(filteredProviders, selection: Binding(
                    get: { workspace.selectedAssistantProviderID },
                    set: { id in if !id.isEmpty { onSelectProvider(id) } }
                )) { provider in
                    HStack(spacing: 8) {
                        Image(systemName: provider.isConfigured ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(provider.isConfigured ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).lineLimit(1)
                            Text("\(provider.models.count) \(conversationLanguage.text("models", spanish: "modelos"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(provider.id)
                }
                .listStyle(.sidebar)
            }
            .frame(width: 260)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if workspace.isLoadingProviders {
                        ProgressView(conversationLanguage.text("Reading Pi's provider catalog…", spanish: "Leyendo el catálogo de proveedores de Pi…"))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if let provider = workspace.selectedAssistantProvider {
                        providerDetail(provider)
                    } else {
                        Text(workspace.configurationError ?? conversationLanguage.text(
                            "No providers were found. Make sure Pi is installed.",
                            spanish: "No se encontraron proveedores. Asegúrate de que Pi esté instalado."
                        ))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRefreshProviders) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .padding(12)
                .help(conversationLanguage.text("Refresh Pi catalog", spanish: "Actualizar catálogo de Pi"))
        }
    }

    @ViewBuilder
    private func providerDetail(_ provider: PiProviderOption) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name).font(.title2.weight(.semibold))
                    Text(provider.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if provider.isConfigured {
                    Label(conversationLanguage.text("Connected", spanish: "Conectado"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Text(conversationLanguage.text(
                "Authentication methods and compatible models are read from your installed Pi version.",
                spanish: "Los métodos de autenticación y modelos compatibles se leen de tu versión instalada de Pi."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

            if workspace.isConnectingProvider {
                authProgress
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(conversationLanguage.text("Connect with", spanish: "Conectar con"))
                        .font(.headline)
                    ForEach(provider.authMethods) { method in
                        Button {
                            onConnectProvider(provider.id, method.kind)
                        } label: {
                            HStack {
                                Image(systemName: method.kind == .oauth ? "person.crop.circle.badge.checkmark" : "key.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(method.loginLabel ?? method.name)
                                    if method.isSubscription {
                                        Text(conversationLanguage.text("Uses your provider subscription", spanish: "Usa tu suscripción del proveedor"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!method.isInteractive)
                    }
                }

                if provider.isConfigured {
                    Button(role: .destructive) {
                        onDisconnectProvider(provider.id)
                    } label: {
                        Text(conversationLanguage.text("Disconnect \(provider.name)", spanish: "Desconectar \(provider.name)"))
                    }
                }
            }

            if let error = workspace.configurationError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()
            Text("\(provider.models.count) \(conversationLanguage.text("compatible models", spanish: "modelos compatibles"))")
                .font(.headline)
            Text(provider.models.prefix(8).map(\.title).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if provider.models.count > 8 {
                Text(conversationLanguage.text(
                    "Choose the complete model list from the conversation toolbar after connecting.",
                    spanish: "Elige de la lista completa de modelos en la barra de la conversación después de conectar."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var authProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(workspace.authStatusMessage ?? conversationLanguage.text("Signing in…", spanish: "Iniciando sesión…"))
            }
            if let prompt = workspace.pendingAuthPrompt {
                Text(prompt.message).font(.callout)
                if prompt.kind == .select {
                    ForEach(prompt.options) { option in
                        Button(option.label) { onSubmitAuthPrompt(option.id) }
                            .buttonStyle(.bordered)
                    }
                } else if prompt.kind == .secret {
                    SecureField(prompt.placeholder ?? "", text: $promptValue)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(prompt.placeholder ?? "", text: $promptValue)
                        .textFieldStyle(.roundedBorder)
                }
                if prompt.kind != .select {
                    Button(conversationLanguage.text("Continue", spanish: "Continuar")) {
                        let value = promptValue
                        promptValue = ""
                        onSubmitAuthPrompt(value)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(promptValue.isEmpty)
                }
            }
            Button(conversationLanguage.text("Cancel sign-in", spanish: "Cancelar inicio de sesión"), action: onCancelAuth)
                .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TranscriptionSettingsView: View {
    @ObservedObject var model: StatusModel
    let onSelect: (String) -> Void
    let onDownload: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(conversationLanguage.text("Transcription engine", spanish: "Motor de transcripción"))
                .font(.title2.weight(.semibold))
            Text(conversationLanguage.text(
                "Choose the local engine used for the next conversation. Downloaded models stay on this Mac.",
                spanish: "Elige el motor local para la próxima conversación. Los modelos descargados permanecen en esta Mac."
            ))
            .foregroundStyle(.secondary)

            List(model.engineOptions) { option in
                HStack(spacing: 12) {
                    Image(systemName: model.selectedEngineOptionID == option.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.selectedEngineOptionID == option.id ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.title).font(.headline)
                        Text(option.summary.isEmpty ? option.detail : option.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    engineAction(option)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.installState(for: option).isReady && model.canChangeEngine { onSelect(option.id) }
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)

            if !model.canChangeEngine {
                Label(conversationLanguage.text(
                    "Finish the current recording before changing engines.",
                    spanish: "Termina la grabación actual antes de cambiar de motor."
                ), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func engineAction(_ option: TranscriptionEngineOption) -> some View {
        let state = model.installState(for: option)
        switch state {
        case .notDownloaded:
            Button(conversationLanguage.text("Download", spanish: "Descargar")) { onDownload(option.id) }
                .disabled(!model.canChangeEngine)
        case let .downloading(progress):
            ProgressView(value: progress).frame(width: 90)
        case .failed:
            Button(conversationLanguage.text("Retry", spanish: "Reintentar")) { onDownload(option.id) }
        case .ready:
            if option.isDownloadable && model.selectedEngineOptionID != option.id {
                Button(role: .destructive) { onDelete(option.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            } else {
                Text(conversationLanguage.text("Ready", spanish: "Listo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum ConversationPalette {
    static let accent = Color(red: 0.35, green: 0.29, blue: 0.70)
}

private enum ConversationPreviewArguments {
    static var isEnabled: Bool {
        PresentationPreviewMode.current()?.showsConversationWindow == true
    }
}
