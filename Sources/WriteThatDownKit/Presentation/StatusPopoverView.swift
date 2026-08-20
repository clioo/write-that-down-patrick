import SwiftUI
import AppKit

private let statusLanguage = AppLanguage.current

/// Pipeline health shown in the popover, derived from session outcomes.
public enum EngineHealth: Equatable, Sendable {
    /// No session has run yet this launch.
    case untested
    /// A session reached Recording (engine + capture verified) at this time.
    case healthy(Date)
    /// The last session attempt failed; message is the user-visible error.
    case failed(String)
    /// Sessions are blocked before the pipeline runs (missing permissions);
    /// the engine itself has not been tested.
    case blocked(String)
}

/// Observable model backing the menu-bar popover.
@MainActor
public final class StatusModel: ObservableObject {
    @Published public var status: SessionStatus = .idle
    @Published public var endReason: EndReason?
    @Published public var detail: String = statusLanguage.text("Waiting for a call…", spanish: "Esperando una llamada…")
    /// Absolute path of the current/last transcript file (provisional while
    /// recording, final after save). Kept after the session so the user can
    /// reveal/copy it post-call.
    @Published public var lastTranscriptPath: String?
    /// Mirrors the caption panel's visibility (drives the toggle's title).
    @Published public var captionsVisible = false
    /// True once the first final segment has been committed this session;
    /// lets the user re-open captions while idle to review the last meeting.
    @Published public var hasSessionContent = false

    // Engine / model info (set once at launch by the composition root).
    @Published public var engineName = ""
    @Published public var modelName = ""
    @Published public var modelDetail = ""
    @Published public var engineOptions: [TranscriptionEngineOption] = []
    @Published public var selectedEngineOptionID = ""
    @Published public var modelInstallStates: [String: ModelInstallState] = [:]
    @Published public var engineHealth: EngineHealth = .untested

    /// Where transcripts are written (folder), for the open/copy actions.
    @Published public var outputDirPath = ""

    public init() {}

    /// Whether a manual stop is meaningful right now.
    public var canStop: Bool { status == .recording }

    /// Engine/model changes apply to the next session, so keep them out of the
    /// middle of a live recording/finalize.
    public var canChangeEngine: Bool {
        status == .idle || status == .saved || status == .failed
    }

    public var selectedEngineOption: TranscriptionEngineOption? {
        engineOptions.first { $0.id == selectedEngineOptionID }
    }

    public func installState(for option: TranscriptionEngineOption) -> ModelInstallState {
        modelInstallStates[option.id] ?? (option.isDownloadable ? .notDownloaded : .ready)
    }

    /// The captions toggle is available during a live session AND while idle
    /// with content still in the model (user wants to re-read / copy).
    public var canToggleCaptions: Bool {
        status == .recording || status == .finalizing || hasSessionContent
    }

    public var headline: String {
        switch status {
        case .idle: return statusLanguage.text("Idle", spanish: "En espera")
        case .detected: return statusLanguage.text("Call detected…", spanish: "Llamada detectada…")
        case .recording: return statusLanguage.text("Recording", spanish: "Grabando")
        case .finalizing: return statusLanguage.text("Saving…", spanish: "Guardando…")
        case .saved: return statusLanguage.text("Saved", spanish: "Guardado")
        case .failed: return statusLanguage.text("Failed", spanish: "Falló")
        }
    }
}

/// Menu-bar popover: status, engine/model health, manual stop (§16.1),
/// captions toggle, and transcript actions.
struct StatusPopoverView: View {
    @ObservedObject var model: StatusModel
    var onOpenApp: () -> Void
    var onStop: () -> Void
    var onToggleCaptions: () -> Void
    var onOpenFolder: () -> Void
    var onSelectEngineOption: (String) -> Void
    var onDownloadEngineOption: (String) -> Void
    var onDeleteEngineOption: (String) -> Void
    var onQuit: () -> Void

    @State private var pathCopied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var modelPickerShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(model.headline).font(.headline)
                Spacer()
            }
            Text(model.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(action: onOpenApp) {
                Label(
                    statusLanguage.text("Open Write That Down", spanish: "Abrir Write That Down"),
                    systemImage: "macwindow"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("o", modifiers: [.command])

            Divider()

            engineSection

            Divider()

            Button(action: onStop) {
                Label(statusLanguage.text("Stop Recording", spanish: "Detener grabación"), systemImage: "stop.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.canStop)
            .keyboardShortcut(".", modifiers: [.command])

            Button(action: onToggleCaptions) {
                Label(model.captionsVisible
                      ? statusLanguage.text("Hide Captions", spanish: "Ocultar subtítulos")
                      : statusLanguage.text("Show Captions", spanish: "Mostrar subtítulos"),
                      systemImage: model.captionsVisible ? "captions.bubble.fill" : "captions.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.canToggleCaptions)

            Divider()

            Button {
                // Reveal the latest transcript file (select it in Finder);
                // fall back to opening the folder if no file exists yet.
                if let path = model.lastTranscriptPath,
                   FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else {
                    onOpenFolder()
                }
            } label: {
                Label(statusLanguage.text("Reveal Latest Transcript", spanish: "Mostrar la última transcripción"), systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.lastTranscriptPath == nil)

            Button(action: onOpenFolder) {
                Label(statusLanguage.text("Open Transcripts Folder", spanish: "Abrir carpeta de transcripciones"), systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                let path = model.lastTranscriptPath ?? model.outputDirPath
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(path, forType: .string)
                pathCopied = true
                copyResetTask?.cancel()
                copyResetTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled { pathCopied = false }
                }
            } label: {
                Label(pathCopied
                      ? statusLanguage.text("Copied!", spanish: "¡Copiado!")
                      : statusLanguage.text("Copy Transcript Path", spanish: "Copiar ruta de la transcripción"),
                      systemImage: pathCopied ? "checkmark" : "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button(action: onQuit) {
                Label(statusLanguage.text("Quit Write That Down", spanish: "Salir de Write That Down"), systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Engine / model health

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.engineOptions.isEmpty {
                Button {
                    modelPickerShown.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(model.selectedEngineOption?.title ?? statusLanguage.text("Select model", spanish: "Seleccionar modelo"))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canChangeEngine)
                .popover(isPresented: $modelPickerShown, arrowEdge: .trailing) {
                    SpeechModelPickerView(
                        model: model,
                        isPresented: $modelPickerShown,
                        onSelect: onSelectEngineOption,
                        onDownload: onDownloadEngineOption,
                        onDelete: onDeleteEngineOption
                    )
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(model.engineName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(model.modelName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Text(model.modelDetail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                Circle().fill(healthColor).frame(width: 7, height: 7)
                Text(healthText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var healthText: String {
        switch model.engineHealth {
        case .untested:
            return statusLanguage.text(
                "Not tested yet — starts with your first call",
                spanish: "Aún no probado — se inicia con tu primera llamada"
            )
        case let .healthy(date):
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return statusLanguage.text(
                "Working — verified \(f.string(from: date))",
                spanish: "Funcionando — verificado \(f.string(from: date))"
            )
        case let .failed(message):
            return statusLanguage.text("Failed: \(message)", spanish: "Falló: \(message)")
        case let .blocked(message):
            return statusLanguage.text(
                "Blocked (engine untested): \(message)",
                spanish: "Bloqueado (motor no probado): \(message)"
            )
        }
    }

    private var healthColor: Color {
        switch model.engineHealth {
        case .untested: return .secondary
        case .healthy: return .green
        case .failed: return .red
        case .blocked: return .orange
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: return .secondary
        case .detected, .finalizing: return .orange
        case .recording: return .red
        case .saved: return .green
        case .failed: return .red
        }
    }
}

/// Rich model catalog inspired by Orca's open-source speech-model picker:
/// installation state, progress, metadata, selection, and deletion all live in
/// one compact surface while the app layer owns the actual side effects.
private struct SpeechModelPickerView: View {
    @ObservedObject var model: StatusModel
    @Binding var isPresented: Bool
    var onSelect: (String) -> Void
    var onDownload: (String) -> Void
    var onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(statusLanguage.text("Speech Model", spanish: "Modelo de voz"))
                    .font(.headline)
                Text(statusLanguage.text(
                    "Downloaded models run entirely on this Mac.",
                    spanish: "Los modelos descargados se ejecutan completamente en esta Mac."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.engineOptions) { option in
                        modelRow(option)
                        if option.id != model.engineOptions.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
        }
        .frame(width: 440, height: 330)
    }

    private func modelRow(_ option: TranscriptionEngineOption) -> some View {
        let state = model.installState(for: option)
        let selected = model.selectedEngineOptionID == option.id
        let busy: Bool = {
            if case .downloading = state { return true }
            return false
        }()

        return HStack(alignment: .center, spacing: 8) {
            Button {
                guard model.canChangeEngine else { return }
                if state.isReady {
                    onSelect(option.id)
                    isPresented = false
                } else if option.isDownloadable && !busy {
                    onDownload(option.id)
                }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    ZStack {
                        if selected && state.isReady {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        } else if busy {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 16, height: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(option.title)
                                .font(.system(size: 13, weight: .semibold))
                            badge(option.isStreaming
                                  ? statusLanguage.text("streaming", spanish: "en vivo")
                                  : statusLanguage.text("offline", spanish: "sin conexión"), color: .secondary)
                            if option.isRecommended {
                                badge(statusLanguage.text("recommended", spanish: "recomendado"), color: .green)
                            }
                            if let bytes = option.sizeBytes {
                                Text(Self.formattedSize(bytes))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            if case let .downloading(progress) = state {
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !option.summary.isEmpty {
                            Text(option.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if case let .failed(message) = state {
                            Text(message)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canChangeEngine || (!state.isReady && !option.isDownloadable) || busy)

            trailingAction(for: option, state: state, selected: selected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func trailingAction(
        for option: TranscriptionEngineOption,
        state: ModelInstallState,
        selected: Bool
    ) -> some View {
        if option.isDownloadable && state.isReady && !selected {
            Button {
                onDelete(option.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(statusLanguage.text("Delete \(option.title)", spanish: "Eliminar \(option.title)"))
            .disabled(!model.canChangeEngine)
        } else if option.isDownloadable {
            switch state {
            case .notDownloaded, .failed:
                Button {
                    onDownload(option.id)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(statusLanguage.text("Download \(option.title)", spanish: "Descargar \(option.title)"))
                .disabled(!model.canChangeEngine)
            case .downloading:
                EmptyView()
            case .ready:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }
}
