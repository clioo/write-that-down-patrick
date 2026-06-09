import SwiftUI

/// Observable model backing the live caption surface. Updated only by the
/// `PresentationCoordinator` (which is driven only by the orchestrator).
@MainActor
public final class CaptionModel: ObservableObject {
    /// Recent committed (final) segments — capped to keep the HUD light.
    @Published public var finals: [Segment] = []
    /// The current partial hypothesis (captions only, never persisted, §8.3).
    @Published public var partial: String = ""
    @Published public var statusText: String = "Listening…"

    private let maxFinals = 60

    public init() {}

    func appendFinal(_ segment: Segment) {
        finals.append(segment)
        if finals.count > maxFinals { finals.removeFirst(finals.count - maxFinals) }
    }

    func reset() {
        finals.removeAll()
        partial = ""
    }
}

/// SwiftUI content for the floating caption HUD (Appendix A — driven solely from
/// the orchestrator's segment stream).
struct CaptionView: View {
    @ObservedObject var model: CaptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(model.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.finals) { seg in
                            HStack(alignment: .top, spacing: 6) {
                                Text(seg.formattedOffset)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(seg.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            .id(seg.id)
                        }
                        if !model.partial.isEmpty {
                            Text(model.partial)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .italic()
                                .id("partial")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.finals.count) { _ in
                    if let last = model.finals.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: model.partial) { _ in
                    withAnimation { proxy.scrollTo("partial", anchor: .bottom) }
                }
            }
        }
        .padding(12)
        .frame(width: 420, height: 220, alignment: .topLeading)
    }
}
