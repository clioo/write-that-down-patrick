import AppKit
import SwiftUI

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
    private var window: NSWindow?

    // Existing actions remain available to the coordinator and status surface.
    var onStop: () -> Void = {}
    var onToggleCaptions: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onSelectEngineOption: (String) -> Void = { _ in }
    var onDownloadEngineOption: (String) -> Void = { _ in }
    var onDeleteEngineOption: (String) -> Void = { _ in }
    var onQuit: () -> Void = {}

    // Conversation-assistant actions. The API key is handed directly to the
    // app layer and is never retained by a presentation model.
    var onAsk: (String) -> Void = { _ in }
    var onSelectAssistantModel: (String) -> Void = { _ in }
    var onSaveAssistantAPIKey: (String) -> Void = { _ in }

    public init(
        statusModel: StatusModel,
        captionModel: CaptionModel,
        workspaceModel: ConversationWorkspaceModel = ConversationWorkspaceModel()
    ) {
        self.statusModel = statusModel
        self.captionModel = captionModel
        self.workspaceModel = workspaceModel
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_260, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Write That Down"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 980, height: 580)
        if ConversationPreviewArguments.isEnabled {
            window.appearance = NSAppearance(named: .aqua)
        }
        window.contentView = NSHostingView(
            rootView: MainWindowView(
                statusModel: statusModel,
                captionModel: captionModel,
                workspaceModel: workspaceModel,
                onStop: { [weak self] in self?.onStop() },
                onOpenFolder: { [weak self] in self?.onOpenFolder() },
                onAsk: { [weak self] question in self?.onAsk(question) },
                onSelectAssistantModel: { [weak self] id in self?.onSelectAssistantModel(id) },
                onSaveAssistantAPIKey: { [weak self] key in self?.onSaveAssistantAPIKey(key) }
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
    var onStop: () -> Void
    var onOpenFolder: () -> Void
    var onAsk: (String) -> Void
    var onSelectAssistantModel: (String) -> Void
    var onSaveAssistantAPIKey: (String) -> Void

    @State private var transcriptCopied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var apiKeySheetShown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                ConversationTranscriptPane(model: captionModel, startedAt: effectiveStartedAt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ConversationAssistantPane(
                    model: workspaceModel,
                    onAsk: onAsk,
                    onSelectModel: { id in
                        workspaceModel.selectedAssistantModelID = id
                        onSelectAssistantModel(id)
                    },
                    onConfigure: { apiKeySheetShown = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            privacyFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $apiKeySheetShown) {
            AssistantAPIKeySheet(
                errorMessage: workspaceModel.configurationError,
                onSave: onSaveAssistantAPIKey
            )
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private var effectiveStartedAt: Date? {
        workspaceModel.sessionStartedAt ?? captionModel.sessionStartedAt
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

            Button(action: copyTranscript) {
                Label(transcriptCopied ? "Copiado" : "Copiar", systemImage: transcriptCopied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 82)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(captionModel.finals.isEmpty)
            .accessibilityLabel("Copiar transcripción")

            if statusModel.canStop {
                Button(action: onStop) {
                    Label("Terminar", systemImage: "stop.fill")
                        .frame(minWidth: 94)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: [.command])
            } else if workspaceModel.phase == .finished {
                Button(action: onOpenFolder) {
                    Label("Ver archivo", systemImage: "doc.text")
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
        switch workspaceModel.phase {
        case .idle: return "Listo para una conversación"
        case .starting: return "Preparando la conversación"
        case .live: return "Conversación en curso"
        case .finalizing: return "Terminando la conversación"
        case .finished: return "Conversación terminada"
        case .failed: return "La conversación terminó con un error"
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
        switch workspaceModel.phase {
        case .idle: return ("Esperando", "waveform", .secondary)
        case .starting: return ("Iniciando", "waveform", .orange)
        case .live: return ("Transcribiendo", "waveform", .green)
        case .finalizing: return ("Guardando", "square.and.arrow.down", .orange)
        case .finished: return ("Guardada", "checkmark.circle.fill", .green)
        case .failed: return ("Error", "exclamationmark.triangle.fill", .red)
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
               workspaceModel.phase == .live || workspaceModel.phase == .starting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.formatDuration(context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                }
            } else {
                Text(Self.formatDuration(workspaceModel.duration ?? 0))
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
            Text("El audio y el archivo permanecen en tu Mac")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("El contexto de IA se envía a OpenCode Go")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(captionModel.fullTranscriptText, forType: .string)
        transcriptCopied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { transcriptCopied = false }
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

// MARK: - Transcript pane

private struct ConversationTranscriptPane: View {
    @ObservedObject var model: CaptionModel
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcripción en vivo")
                .font(.system(size: 18, weight: .bold))
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 22)

            if model.finals.isEmpty && model.partial.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("La transcripción aparecerá aquí")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Write That Down comenzará a mostrar texto cuando detecte la conversación.")
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
                            ForEach(model.finals) { segment in
                                transcriptRow(segment)
                                    .id(segment.id)
                            }

                            if !model.partial.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 18) {
                                    Text("…")
                                        .frame(width: 48, alignment: .leading)
                                        .foregroundStyle(.tertiary)
                                    Text(model.partial)
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
                    .onChange(of: model.finals.count) { _ in
                        DispatchQueue.main.async {
                            proxy.scrollTo("conversation-live-edge", anchor: .bottom)
                        }
                    }
                    .onChange(of: model.partial) { _ in
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("Pregúntale a la conversación")
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
                    tabButton(.summary, title: "Resumen")
                    if model.phase == .live || model.phase == .starting || model.phase == .finalizing {
                        Text("al terminar")
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
                ConversationSummaryView(model: model, onConfigure: onConfigure)
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
                        Text("No hay modelos disponibles")
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
                .help("Configurar OpenCode Go")
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .font(.system(size: 12))
            .background(Color.secondary.opacity(0.06), in: Capsule())
            .overlay { Capsule().stroke(Color.secondary.opacity(0.18)) }
        } else {
            Button(action: onConfigure) {
                Label("Conectar OpenCode Go", systemImage: "sparkles")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var providerLabel: String {
        if let option = model.selectedAssistantModel {
            return "OpenCode Go · \(option.title)"
        }
        return "OpenCode Go"
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
                    title: "Conecta OpenCode Go para chatear",
                    detail: "Tus preguntas usan únicamente el proveedor y modelo que elijas en OpenCode Go.",
                    action: onConfigure
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty {
                VStack(spacing: 11) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 26))
                        .foregroundStyle(ConversationPalette.accent)
                    Text("Pregunta sobre esta conversación")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Puedes preguntar por decisiones, pendientes o cualquier detalle de la transcripción.")
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
            TextField("Pregunta sobre esta conversación…", text: $draft, axis: .vertical)
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
            .accessibilityLabel("Enviar pregunta")
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

    var body: some View {
        Group {
            if !model.isConfigured {
                AssistantConfigurationEmptyState(
                    title: "Conecta OpenCode Go para generar el resumen",
                    detail: "El resumen se creará al terminar la conversación.",
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
                Text(model.phase == .finished ? "Resumen pendiente" : "Disponible al terminar")
                    .font(.system(size: 15, weight: .semibold))
                Text("OpenCode Go resumirá los puntos importantes, decisiones y próximos pasos.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

        case .generating:
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparando el resumen…")
                    .font(.system(size: 14, weight: .medium))
                Text("La transcripción ya está guardada en tu Mac.")
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
                Text("No hubo suficiente contenido para resumir")
                    .font(.system(size: 14, weight: .semibold))
            }

        case let .failed(message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 25))
                    .foregroundStyle(.red)
                Text("No se pudo generar el resumen")
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
            Button("Configurar OpenCode Go", action: action)
                .buttonStyle(.borderedProminent)
                .tint(ConversationPalette.accent)
        }
        .padding(28)
    }
}

// MARK: - API-key sheet

private struct AssistantAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @FocusState private var keyFieldFocused: Bool

    let errorMessage: String?
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(ConversationPalette.accent)
                Text("Conectar OpenCode Go")
                    .font(.title2.weight(.semibold))
            }

            Text("Añade tu API key para hacer preguntas y generar resúmenes. Write That Down la guarda en el Keychain de este Mac y sólo la entrega al proceso aislado de Pi.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .focused($keyFieldFocused)
                .onSubmit(save)

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancelar") {
                    apiKey = ""
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Guardar") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(ConversationPalette.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 450)
        .onAppear { keyFieldFocused = true }
        .onDisappear { apiKey = "" }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        apiKey = ""
        onSave(key)
        dismiss()
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
