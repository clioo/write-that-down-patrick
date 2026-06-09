import AppKit
import SwiftUI

/// The live caption surface (§3.1.5): an always-on-top, non-activating HUD panel
/// (`NSPanel` with `.nonactivatingPanel` + `.hudWindow`) that shows partial and
/// final segments during a call.
@MainActor
public final class CaptionSurface {
    private let model: CaptionModel
    private var panel: NSPanel?

    public init(model: CaptionModel) {
        self.model = model
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.nonactivatingPanel, .titled, .closable, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Captions"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: CaptionView(model: model))

        // Bottom-center of the main screen.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - 210
            let y = visible.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        self.panel = panel
    }

    public func show() {
        makePanelIfNeeded()
        model.statusText = "Recording…"
        panel?.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    public func showPartial(_ text: String) {
        model.partial = text
    }

    public func commitFinal(_ segment: Segment) {
        model.appendFinal(segment)
        model.partial = ""
    }

    public func reset() {
        model.reset()
    }
}
