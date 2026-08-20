import AppKit
import SwiftUI

private let recordingPromptLanguage = AppLanguage.current

/// Small Granola-style confirmation surface for ambiguous microphone use.
/// It intentionally does not activate the app or steal focus from the app in
/// which the user is speaking.
@MainActor
final class RecordingPromptSurface {
    private var panel: NSPanel?
    private var promptID: UUID?

    var onAccept: (UUID) -> Void = { _ in }
    var onDecline: (UUID) -> Void = { _ in }

    func show(_ prompt: RecordingPrompt) {
        promptID = prompt.id
        let view = RecordingPromptView(
            sourceName: prompt.context.sourceName,
            onAccept: { [weak self] in self?.accept() },
            onDecline: { [weak self] in self?.decline() }
        )

        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: view)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        promptID = nil
        panel?.orderOut(nil)
    }

    func hide(id: UUID) {
        guard promptID == id else { return }
        hide()
    }

    private func accept() {
        guard let id = promptID else { return }
        hide()
        onAccept(id)
    }

    private func decline() {
        guard let id = promptID else { return }
        hide()
        onDecline(id)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 126),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 22,
            y: visibleFrame.maxY - size.height - 22
        )
        panel.setFrameOrigin(origin)
    }
}

private struct RecordingPromptView: View {
    let sourceName: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(recordingPromptLanguage.text("Are you in a conversation?", spanish: "¿Estás en una conversación?"))
                    .font(.system(size: 15, weight: .semibold))
                Text(recordingPromptLanguage.text(
                    "\(sourceName) is using the microphone. Do you want to transcribe it?",
                    spanish: "\(sourceName) está usando el micrófono. ¿Quieres transcribirla?"
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 7) {
                Button(recordingPromptLanguage.text("Record", spanish: "Grabar"), action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                Button(recordingPromptLanguage.text("Not now", spanish: "Ahora no"), action: onDecline)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .frame(width: 78)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 430, height: 126)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(recordingPromptLanguage.text(
            "Recording confirmation for \(sourceName)",
            spanish: "Confirmación de grabación para \(sourceName)"
        ))
    }
}
