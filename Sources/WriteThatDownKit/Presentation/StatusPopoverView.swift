import SwiftUI

/// Observable model backing the menu-bar popover.
@MainActor
public final class StatusModel: ObservableObject {
    @Published public var status: SessionStatus = .idle
    @Published public var endReason: EndReason?
    @Published public var detail: String = "Waiting for a call…"
    @Published public var lastTranscriptPath: String?

    public init() {}

    /// Whether a manual stop is meaningful right now.
    public var canStop: Bool { status == .recording }

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

/// Menu-bar popover content: status, manual stop (§16.1), and quick actions.
struct StatusPopoverView: View {
    @ObservedObject var model: StatusModel
    var onStop: () -> Void
    var onOpenFolder: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(model.headline).font(.headline)
                Spacer()
            }
            Text(model.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(action: onStop) {
                Label("Stop Recording", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.canStop)
            .keyboardShortcut(".", modifiers: [.command])

            Button(action: onOpenFolder) {
                Label("Open Transcripts Folder", systemImage: "folder")
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
        .frame(width: 260)
    }

    private var color: Color {
        switch model.status {
        case .idle: return .secondary
        case .detected, .finalizing: return .orange
        case .recording: return .red
        case .saved: return .green
        case .failed: return .red
        }
    }
}
