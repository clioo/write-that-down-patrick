import SwiftUI
import AppKit

/// Observable model backing the live caption surface.
@MainActor
public final class CaptionModel: ObservableObject {
    @Published public var finals: [Segment] = []
    @Published public var partial: String = ""
    @Published public var statusText: String = "Listening…"
    @Published public var sessionStartedAt: Date?
    // NOTE: follow-mode ("pinned to live edge") is deliberately NOT here. It is
    // per-viewport UI state (@State in CaptionView): the floating panel and the
    // dashboard each have their own scroll position, and a shared flag makes
    // their sentinels fight (scroll yanks, stuck Jump pill).
    /// Whether there is session content worth showing (enables the idle toggle).
    @Published public var hasSessionContent = false
    @Published public var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey) }
    }

    static let fontSizeKey = "captionFontSize"
    static let minFontSize: Double = 10
    static let maxFontSize: Double = 26

    public init() {
        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = stored >= Self.minFontSize && stored <= Self.maxFontSize ? stored : 13
    }

    func appendFinal(_ segment: Segment) {
        finals.append(segment)
        hasSessionContent = true
    }

    func reset() {
        finals.removeAll()
        partial = ""
        hasSessionContent = false
    }

    var fullTranscriptText: String {
        finals.map { "[\($0.formattedOffset)] \($0.text)" }.joined(separator: "\n")
    }

    func adjustFontSize(by delta: Double) {
        fontSize = min(Self.maxFontSize, max(Self.minFontSize, fontSize + delta))
    }
}

// MARK: - PreferenceKey for geometry-based follow detection

/// Reports whether the bottom sentinel's top edge is within the visible
/// viewport. This is the correct mechanism on macOS 13 — `onAppear/onDisappear`
/// in `LazyVStack` tracks render-region materialization, NOT viewport visibility,
/// so it fails to detect scroll-up within the ~1-viewport retention zone.
private struct SentinelVisibleKey: PreferenceKey {
    static let defaultValue = true  // follow by default until geometry settles
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

// MARK: - CaptionView

struct CaptionView: View {
    @ObservedObject var model: CaptionModel
    @State private var justCopied = false
    @State private var copyTask: Task<Void, Never>?
    /// Per-VIEW follow-mode: this scroll view is pinned to the live edge. Each
    /// mounted CaptionView (floating panel, dashboard) tracks its own viewport;
    /// sharing this on the model makes the two sentinels fight.
    @State private var isFollowingLive = true

    static let bottomID = "live-edge"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            transcript
        }
        .padding(12)
        .frame(minWidth: 360, minHeight: 200)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(model.statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let started = model.sessionStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Segment.format(offset: context.date.timeIntervalSince(started)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()

            Button { model.adjustFontSize(by: -1) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .buttonStyle(.borderless)
            .help("Smaller text")
            .disabled(model.fontSize <= CaptionModel.minFontSize)

            Button { model.adjustFontSize(by: 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .buttonStyle(.borderless)
            .help("Larger text")
            .disabled(model.fontSize >= CaptionModel.maxFontSize)

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(model.fullTranscriptText, forType: .string)
                justCopied = true
                // Cancellable timer so rapid copies don't cut the confirmation short.
                copyTask?.cancel()
                copyTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled { justCopied = false }
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy transcript so far")
            .disabled(model.finals.isEmpty)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        // Outer GeometryReader captures the viewport height — needed for
        // geometry-based follow detection below.
        GeometryReader { viewportGeo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.finals) { seg in row(for: seg) }

                        if !model.partial.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text("…")
                                    .font(.system(size: max(9, model.fontSize - 3), design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                Text(model.partial)
                                    .font(.system(size: model.fontSize))
                                    .foregroundStyle(.secondary)
                                    .italic()
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Geometry-based live-edge sentinel. A PreferenceKey
                        // on a background GeometryReader reports whether the
                        // sentinel's top edge is within the visible viewport.
                        // This is reliable even within LazyVStack's ~1-viewport
                        // retain region where onDisappear never fires.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .background(
                                GeometryReader { sentinelGeo in
                                    let minY = sentinelGeo.frame(in: .named("scrollspace")).minY
                                    Color.clear.preference(
                                        key: SentinelVisibleKey.self,
                                        value: minY < viewportGeo.size.height + 8
                                    )
                                }
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Reserve space for the Jump pill so it never covers text.
                    .padding(.bottom, isFollowingLive ? 0 : 38)
                }
                .coordinateSpace(name: "scrollspace")
                .onPreferenceChange(SentinelVisibleKey.self) { visible in
                    isFollowingLive = visible
                }
                // Scroll to live edge when new content arrives OR font changes.
                // Deferred one runloop so layout has settled (avoids LazyVStack
                // short-landing on unmeasured row heights).
                .onChange(of: model.finals.count) { count in
                    // A fresh session (reset() emptied the list) re-engages
                    // follow-mode in every mounted view.
                    if count == 0 {
                        isFollowingLive = true
                        return
                    }
                    if isFollowingLive {
                        DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
                .onChange(of: model.partial) { _ in
                    if isFollowingLive {
                        DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
                .onChange(of: model.fontSize) { _ in
                    if isFollowingLive {
                        DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isFollowingLive {
                        Button {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                            // isFollowingLive flips true via the PreferenceKey
                            // once the scroll settles and the sentinel is in view.
                        } label: {
                            Label("Jump to live", systemImage: "arrow.down.to.line")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Resume auto-scrolling with the conversation")
                    }
                }
            }
        }
    }

    private func row(for seg: Segment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(seg.formattedOffset)
                .font(.system(size: max(9, model.fontSize - 3), design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Text(seg.text)
                .font(.system(size: model.fontSize))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(seg.id)
    }
}
