import SwiftUI
import AppKit

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
    @Published public var detail: String = "Waiting for a call…"
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
    @Published public var engineHealth: EngineHealth = .untested

    /// Where transcripts are written (folder), for the open/copy actions.
    @Published public var outputDirPath = ""

    public init() {}

    /// Whether a manual stop is meaningful right now.
    public var canStop: Bool { status == .recording }

    /// The captions toggle is available during a live session AND while idle
    /// with content still in the model (user wants to re-read / copy).
    public var canToggleCaptions: Bool {
        status == .recording || status == .finalizing || hasSessionContent
    }

    public var headline: String {
        switch status {
        case .idle: return "Idle"
        case .detected: return "Call detected…"
        case .recording: return "Recording"
        case .finalizing: return "Saving…"
        case .saved: return "Saved"
        case .failed: return "Failed"
        }
    }
}

/// Menu-bar popover: status, engine/model health, manual stop (§16.1),
/// captions toggle, and transcript actions.
struct StatusPopoverView: View {
    @ObservedObject var model: StatusModel
    var onStop: () -> Void
    var onToggleCaptions: () -> Void
    var onOpenFolder: () -> Void
    var onQuit: () -> Void

    @State private var pathCopied = false
    @State private var copyResetTask: Task<Void, Never>?

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

            engineSection

            Divider()

            Button(action: onStop) {
                Label("Stop Recording", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.canStop)
            .keyboardShortcut(".", modifiers: [.command])

            Button(action: onToggleCaptions) {
                Label(model.captionsVisible ? "Hide Captions" : "Show Captions",
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
                Label("Reveal Latest Transcript", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.lastTranscriptPath == nil)

            Button(action: onOpenFolder) {
                Label("Open Transcripts Folder", systemImage: "folder")
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
                Label(pathCopied ? "Copied!" : "Copy Transcript Path",
                      systemImage: pathCopied ? "checkmark" : "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button(action: onQuit) {
                Label("Quit Write That Down", systemImage: "power")
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
            return "Not tested yet — starts with your first call"
        case let .healthy(date):
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "Working — verified \(f.string(from: date))"
        case let .failed(message):
            return "Failed: \(message)"
        case let .blocked(message):
            return "Blocked (engine untested): \(message)"
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
