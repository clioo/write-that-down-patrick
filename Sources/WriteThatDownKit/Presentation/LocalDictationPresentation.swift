import AppKit
import SwiftUI

public enum LocalDictationPhase: String, Equatable, Sendable {
    case idle
    case loading
    case listening
    case transcribing
    case inserted
    case failed

    public var isBusy: Bool {
        self == .loading || self == .listening || self == .transcribing
    }
}

@MainActor
public final class DictationSettingsModel: ObservableObject {
    @Published public var isEnabled = false
    @Published public var accessibilityGranted = false
    @Published public var phase: LocalDictationPhase = .idle
    @Published public var targetApplicationName: String?
    @Published public var errorMessage: String?

    public init() {}
}

/// Compact, non-activating feedback shown above the Dock while dictation is
/// loading, listening, or inserting. It never steals focus from the destination
/// text field.
@MainActor
public final class DictationOverlaySurface {
    private let model = OverlayModel()
    private var panel: NSPanel?

    public init() {}

    public func show(
        phase: LocalDictationPhase,
        engineName: String,
        targetApplicationName: String?,
        message: String? = nil
    ) {
        model.phase = phase
        model.engineName = engineName
        model.targetApplicationName = targetApplicationName
        model.message = message
        let panel = makePanelIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationOverlayView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 42
        )
        panel.setFrameOrigin(origin)
    }
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var phase: LocalDictationPhase = .idle
    @Published var engineName = ""
    @Published var targetApplicationName: String?
    @Published var message: String?
}

private struct DictationOverlayView: View {
    @ObservedObject var model: OverlayModel
    private let language = AppLanguage.current

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(indicatorColor.opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: indicatorSymbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(indicatorColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if model.phase == .listening {
                Text("⌘E")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            } else if model.phase == .loading || model.phase == .transcribing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(width: 390, height: 96)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
    }

    private var title: String {
        switch model.phase {
        case .idle: return language.text("Local dictation", spanish: "Dictado local")
        case .loading: return language.text("Loading \(model.engineName)…", spanish: "Cargando \(model.engineName)…")
        case .listening: return language.text("Listening…", spanish: "Escuchando…")
        case .transcribing: return language.text("Writing that down…", spanish: "Escribiendo eso…")
        case .inserted: return language.text("Text inserted", spanish: "Texto insertado")
        case .failed: return language.text("Dictation stopped", spanish: "Dictado detenido")
        }
    }

    private var detail: String {
        if let message = model.message, !message.isEmpty { return message }
        switch model.phase {
        case .loading:
            return language.text("The selected local model is getting ready.", spanish: "El modelo local seleccionado se está preparando.")
        case .listening:
            let destination = model.targetApplicationName ?? language.text("the selected field", spanish: "el campo seleccionado")
            return language.text("Press ⌘E again to insert into \(destination).", spanish: "Presiona ⌘E otra vez para insertar en \(destination).")
        case .transcribing:
            return language.text("Audio stays on this Mac.", spanish: "El audio permanece en esta Mac.")
        case .inserted:
            return language.text("Done.", spanish: "Listo.")
        case .failed:
            return language.text("Try again from a text field.", spanish: "Inténtalo de nuevo desde un campo de texto.")
        case .idle:
            return ""
        }
    }

    private var indicatorSymbol: String {
        switch model.phase {
        case .listening: return "waveform"
        case .inserted: return "checkmark"
        case .failed: return "exclamationmark"
        default: return "mic.fill"
        }
    }

    private var indicatorColor: Color {
        switch model.phase {
        case .listening: return .red
        case .inserted: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }
}
