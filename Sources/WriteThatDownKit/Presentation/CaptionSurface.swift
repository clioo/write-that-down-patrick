@preconcurrency import AppKit
import SwiftUI

/// The live caption surface (§3.1.5): an always-on-top, non-activating HUD panel
/// showing partial and final segments during a call. Resizable; size + position
/// remembered across launches.
@MainActor
public final class CaptionSurface {
    private static let frameAutosaveName = "WTDCaptionsPanel"

    private let model: CaptionModel
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?

    /// Called when the user dismisses the panel via its close button, so the
    /// menu-bar mirror (`captionsVisible`) can be kept in sync.
    public var onUserClosed: (() -> Void)?

    public init(model: CaptionModel) {
        self.model = model
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.nonactivatingPanel, .titled, .closable, .miniaturizable, .resizable, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Captions"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // The title bar is the drag handle — set in content coordinates so it
        // matches the SwiftUI .frame(minWidth:minHeight:) declaration.
        panel.contentMinSize = NSSize(width: 360, height: 200)
        // Background-drag conflicts with text selection in the transcript.
        // The .titled title bar is a dedicated, unambiguous drag handle.
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(rootView: CaptionView(model: model))

        if !panel.setFrameUsingName(Self.frameAutosaveName), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - panel.frame.width / 2
            let y = visible.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        self.panel = panel

        // Sync the menu-bar mirror when the user closes via the window's X
        // button — that path doesn't go through hide(), so we observe it here.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // Jump to main actor — the notification fires on .main queue already
            // but the closure is Sendable so we re-enter explicitly.
            DispatchQueue.main.async { self?.onUserClosed?() }
        }
    }

    public func show() {
        makePanelIfNeeded()
        // Do NOT hardcode statusText here — `updateStatus` is the single writer.
        panel?.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    public func showPartial(_ text: String) { model.partial = text }

    public func commitFinal(_ segment: Segment) {
        model.appendFinal(segment)
        model.partial = ""
    }

    public func reset() { model.reset() }

    // closeObserver is removed automatically when the object token deinits.
    // Explicit removal isn't needed for block-based observers, but kept for clarity.

}
