import AppKit
import SwiftUI

/// The menu-bar status surface (§3.1.6): an `NSStatusItem` whose icon reflects
/// session state, with a SwiftUI popover exposing manual stop control (§16.1).
@MainActor
public final class StatusSurface: NSObject {
    private let model: StatusModel
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    /// Callbacks wired by the composition root.
    public var onManualStop: (() -> Void)?
    public var onOpenFolder: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(model: StatusModel) {
        self.model = model
        super.init()
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.icon(for: .idle)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        self.statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 220)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(
                model: model,
                onStop: { [weak self] in self?.onManualStop?() },
                onOpenFolder: { [weak self] in self?.onOpenFolder?() },
                onQuit: { [weak self] in self?.onQuit?() }
            )
        )
        self.popover = popover
    }

    public func update(status: SessionStatus, endReason: EndReason?, detail: String) {
        model.status = status
        model.endReason = endReason
        model.detail = detail
        statusItem?.button?.image = Self.icon(for: status)
        statusItem?.button?.image?.isTemplate = (status != .recording)
        statusItem?.button?.toolTip = "Write That Down — \(model.headline)"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// SF Symbol per state. Recording uses a filled, tinted dot.
    private static func icon(for status: SessionStatus) -> NSImage? {
        let symbol: String
        switch status {
        case .idle: symbol = "waveform"
        case .detected: symbol = "waveform.badge.magnifyingglass"
        case .recording: symbol = "waveform.circle.fill"
        case .finalizing: symbol = "square.and.arrow.down"
        case .saved: symbol = "checkmark.circle"
        case .failed: symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Write That Down status")
        return image
    }
}
