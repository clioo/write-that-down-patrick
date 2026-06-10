import AppKit
import SwiftUI

/// The desktop dashboard window: shown on app launch and whenever the user
/// re-opens the app (Spotlight/Finder) while it's already running, so the app
/// is not menu-bar-only. Combines the status/actions column with the live
/// transcript view. Closing it leaves the app running in the menu bar.
@MainActor
public final class MainWindowController {
    private static let frameAutosaveName = "WTDMainWindow"

    private let statusModel: StatusModel
    private let captionModel: CaptionModel
    private var window: NSWindow?

    // Action closures, supplied by the coordinator (same ones the popover uses).
    var onStop: () -> Void = {}
    var onToggleCaptions: () -> Void = {}
    var onOpenFolder: () -> Void = {}
    var onQuit: () -> Void = {}

    public init(statusModel: StatusModel, captionModel: CaptionModel) {
        self.statusModel = statusModel
        self.captionModel = captionModel
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Write That Down"
        window.isReleasedWhenClosed = false // we keep a strong reference and reuse it
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.contentView = NSHostingView(
            rootView: MainWindowView(
                statusModel: statusModel,
                captionModel: captionModel,
                onStop: { [weak self] in self?.onStop() },
                onToggleCaptions: { [weak self] in self?.onToggleCaptions() },
                onOpenFolder: { [weak self] in self?.onOpenFolder() },
                onQuit: { [weak self] in self?.onQuit() }
            )
        )
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window
    }

    /// Shows (or brings forward) the dashboard and gives it focus — works even
    /// though the app is an accessory (no Dock icon).
    public func show() {
        makeWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Dashboard layout: status & actions on the left, live transcript on the right.
private struct MainWindowView: View {
    @ObservedObject var statusModel: StatusModel
    @ObservedObject var captionModel: CaptionModel
    var onStop: () -> Void
    var onToggleCaptions: () -> Void
    var onOpenFolder: () -> Void
    var onQuit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Reuse the popover content as the actions column — identical
            // behavior in both surfaces, one source of truth.
            StatusPopoverView(
                model: statusModel,
                onStop: onStop,
                onToggleCaptions: onToggleCaptions,
                onOpenFolder: onOpenFolder,
                onQuit: onQuit
            )
            .frame(width: 300, alignment: .top)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Live transcript")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if captionModel.finals.isEmpty && captionModel.partial.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "waveform")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No conversation yet")
                            .foregroundStyle(.secondary)
                        Text("Transcription starts automatically when a call begins.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // The same live reading view the floating panel uses.
                    CaptionView(model: captionModel)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
