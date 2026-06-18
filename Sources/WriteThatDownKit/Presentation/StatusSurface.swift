import AppKit
import SwiftUI

/// The menu-bar status surface (§3.1.6): an `NSStatusItem` whose icon reflects
/// session state, with a SwiftUI popover exposing manual control (§16.1).
/// While recording, the item also shows a red "● mm:ss" elapsed indicator so
/// it's unmistakable that capture is live. If an SF Symbol ever fails to
/// resolve, the item falls back to a text title — it can never be blank.
@MainActor
public final class StatusSurface: NSObject {
    private let model: StatusModel
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var recordingTimer: Timer?
    private var recordingSince: Date?

    /// Callbacks wired by the composition root.
    public var onManualStop: (() -> Void)?
    public var onToggleCaptions: (() -> Void)?
    public var onOpenFolder: (() -> Void)?
    public var onSelectEngineOption: ((String) -> Void)?
    public var onQuit: (() -> Void)?

    public init(model: StatusModel) {
        self.model = model
        super.init()
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the user's ⌘-drag position so reordering the icon sticks
        // across relaunches (without this, macOS re-places it each launch).
        item.autosaveName = "WriteThatDownStatusItem"
        item.behavior = []          // never auto-hide / never user-removable
        item.isVisible = true
        if let button = item.button {
            button.image = Self.icon(for: .idle)
            button.image?.isTemplate = true
            if button.image == nil { button.title = "WTD" } // never blank
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        self.statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 390)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(
                model: model,
                onStop: { [weak self] in self?.onManualStop?() },
                onToggleCaptions: { [weak self] in self?.onToggleCaptions?() },
                onOpenFolder: { [weak self] in self?.onOpenFolder?() },
                onSelectEngineOption: { [weak self] id in self?.onSelectEngineOption?(id) },
                onQuit: { [weak self] in self?.onQuit?() }
            )
        )
        self.popover = popover
    }

    public func update(status: SessionStatus, endReason: EndReason?, detail: String, recordingSince: Date? = nil) {
        model.status = status
        model.endReason = endReason
        model.detail = detail

        guard let button = statusItem?.button else { return }
        let image = Self.icon(for: status)
        button.image = image
        // Keep the symbol TEMPLATED in every state (a non-template monochrome
        // symbol draws raw black — invisible on a dark menu bar) and tint via
        // the button instead: red while recording, system tint otherwise.
        button.image?.isTemplate = true
        button.contentTintColor = (status == .recording) ? .systemRed : nil
        if image == nil { button.title = "WTD" }
        button.toolTip = "Write That Down — \(model.headline)"

        if status == .recording {
            self.recordingSince = recordingSince ?? Date()
            startRecordingTicker()
        } else {
            stopRecordingTicker()
            if image != nil { button.attributedTitle = NSAttributedString(string: "") }
        }
    }

    // MARK: Recording elapsed indicator

    private func startRecordingTicker() {
        guard recordingTimer == nil else { return }
        tick() // immediate, don't wait a second
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopRecordingTicker() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingSince = nil
    }

    private func tick() {
        guard let button = statusItem?.button, let since = recordingSince else { return }
        // Clamp: a backward wall-clock step (NTP/manual) must not render "● 0:-5".
        let elapsed = max(0, Int(Date().timeIntervalSince(since)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let text = String(format: " ● %d:%02d", minutes, seconds)
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            ]
        )
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// SF Symbol per state (all available on macOS 12+).
    private static func icon(for status: SessionStatus) -> NSImage? {
        let symbol: String
        switch status {
        case .idle: symbol = "waveform"
        case .detected: symbol = "waveform.and.magnifyingglass" // macOS 12+; badge variant is macOS 14 only
        case .recording: symbol = "waveform.circle.fill"
        case .finalizing: symbol = "square.and.arrow.down"
        case .saved: symbol = "checkmark.circle"
        case .failed: symbol = "exclamationmark.triangle"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "Write That Down status")
    }
}
