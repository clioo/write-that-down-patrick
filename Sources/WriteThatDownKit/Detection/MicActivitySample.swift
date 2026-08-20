import Foundation

/// How much attribution the operating system supplied for a microphone sample.
public enum MicActivityAttribution: Sendable, Equatable {
    /// macOS supplied one or more process records for the active microphone.
    case attributed
    /// Only the device-level "some process is using the microphone" bit is known.
    case unattributed
    /// Compatibility input used by deterministic tests and legacy signal sources.
    /// It intentionally keeps the former Bool semantics: active means auto-start.
    case legacyAutomatic
}

/// One process observed using microphone input.
public struct MicActivitySource: Sendable, Hashable {
    public let pid: Int32
    /// Bundle identifier reported by CoreAudio. Chromium commonly reports a
    /// helper bundle here rather than the browser's top-level bundle.
    public let bundleID: String?
    /// Best-effort top-level application bundle identifier.
    public let applicationBundleID: String?
    public let displayName: String?
    /// Title of the application's frontmost on-screen window, when available.
    /// This is intentionally transient and must never be persisted or logged.
    public let windowTitle: String?

    public init(
        pid: Int32,
        bundleID: String? = nil,
        applicationBundleID: String? = nil,
        displayName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.applicationBundleID = applicationBundleID
        self.displayName = displayName
        self.windowTitle = windowTitle
    }

    /// Identifier used for policy matching. Prefer the normalized top-level app.
    public var effectiveBundleID: String? {
        applicationBundleID ?? bundleID
    }
}

/// Rich replacement for the former microphone-active Bool signal.
public struct MicActivitySample: Sendable, Equatable {
    public let isActive: Bool
    public let attribution: MicActivityAttribution
    /// Non-excluded sources that may produce a recording candidate.
    public let sources: [MicActivitySource]
    /// Sources suppressed by the existing configured exclusion list.
    public let ignoredSources: [MicActivitySource]

    public init(
        isActive: Bool,
        attribution: MicActivityAttribution,
        sources: [MicActivitySource] = [],
        ignoredSources: [MicActivitySource] = []
    ) {
        self.isActive = isActive
        self.attribution = attribution
        self.sources = sources
        self.ignoredSources = ignoredSources
    }

    public static let inactive = MicActivitySample(
        isActive: false,
        attribution: .attributed
    )

    public static func unattributed(active: Bool) -> MicActivitySample {
        MicActivitySample(isActive: active, attribution: .unattributed)
    }

    /// Preserves the old Bool detector semantics for mocks and legacy adapters.
    public static func legacy(active: Bool) -> MicActivitySample {
        MicActivitySample(isActive: active, attribution: .legacyAutomatic)
    }
}

public enum DetectedCallKind: String, Sendable, Equatable {
    case zoom
    case teams
    case googleMeet
    case whatsApp
    case browser
    case other
    case unknown
    case legacy
}

/// Stable, privacy-safe description of a sustained microphone episode.
public struct DetectedCallContext: Sendable, Equatable, Hashable {
    public let fingerprint: String
    public let kind: DetectedCallKind
    public let sourceName: String
    public let sourceBundleIDs: [String]

    public init(
        fingerprint: String,
        kind: DetectedCallKind,
        sourceName: String,
        sourceBundleIDs: [String]
    ) {
        self.fingerprint = fingerprint
        self.kind = kind
        self.sourceName = sourceName
        self.sourceBundleIDs = sourceBundleIDs
    }
}

/// Result of the pure source-classification policy.
public enum CallStartDecision: Sendable, Equatable {
    case inactive
    case automatic(DetectedCallContext)
    case requiresConfirmation(DetectedCallContext)
}

/// User-facing request emitted only after an ambiguous source survives the
/// existing start-confirm window. The ID protects against stale responses.
public struct RecordingPrompt: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let context: DetectedCallContext

    public init(id: UUID = UUID(), context: DetectedCallContext) {
        self.id = id
        self.context = context
    }
}

/// Pure, deterministic policy for deciding whether sustained microphone use may
/// auto-start a recording. Exclusions have already been applied by CallDetector.
public struct CallStartPolicy: Sendable {
    public init() {}

    public func decision(for sample: MicActivitySample) -> CallStartDecision {
        guard sample.isActive else { return .inactive }

        if sample.attribution == .legacyAutomatic {
            return .automatic(context(
                kind: .legacy,
                sourceName: "Call",
                sources: sample.sources,
                fallbackID: "legacy"
            ))
        }

        // macOS 13 cannot attribute microphone use. Treat it as ambiguous rather
        // than silently reverting to auto-record-everything behavior.
        guard !sample.sources.isEmpty else {
            return .requiresConfirmation(context(
                kind: .unknown,
                sourceName: "Unknown application",
                sources: [],
                fallbackID: "unattributed"
            ))
        }

        if let zoom = sample.sources.first(where: { Self.isZoom($0) }) {
            return .automatic(context(kind: .zoom, sourceName: "Zoom", sources: sample.sources, preferred: zoom))
        }
        if let teams = sample.sources.first(where: { Self.isTeams($0) }) {
            return .automatic(context(kind: .teams, sourceName: "Microsoft Teams", sources: sample.sources, preferred: teams))
        }
        if let meet = sample.sources.first(where: {
            Self.isBrowser($0) && Self.titleIndicatesGoogleMeet($0.windowTitle)
        }) {
            return .automatic(context(kind: .googleMeet, sourceName: "Google Meet", sources: sample.sources, preferred: meet))
        }

        if let whatsApp = sample.sources.first(where: { Self.isWhatsApp($0) }) {
            return .requiresConfirmation(context(kind: .whatsApp, sourceName: "WhatsApp", sources: sample.sources, preferred: whatsApp))
        }
        if let browser = sample.sources.first(where: { Self.isBrowser($0) }) {
            let name = browser.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .requiresConfirmation(context(
                kind: .browser,
                sourceName: name?.isEmpty == false ? name! : "Browser",
                sources: sample.sources,
                preferred: browser
            ))
        }

        let preferred = sample.sources.sorted(by: Self.sourceOrder).first
        let name = preferred?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .requiresConfirmation(context(
            kind: preferred?.effectiveBundleID == nil ? .unknown : .other,
            sourceName: name?.isEmpty == false ? name! : "Unknown application",
            sources: sample.sources,
            preferred: preferred
        ))
    }

    private func context(
        kind: DetectedCallKind,
        sourceName: String,
        sources: [MicActivitySource],
        preferred: MicActivitySource? = nil,
        fallbackID: String? = nil
    ) -> DetectedCallContext {
        let ids = Array(Set(sources.compactMap { source in
            source.effectiveBundleID?.lowercased()
        })).sorted()
        let identity = ids.isEmpty ? (fallbackID ?? "unknown") : ids.joined(separator: ",")
        // Include the classification in the key so a browser changing from an
        // ambiguous page to a verified Meet page begins a fresh confirm window.
        let fingerprint = "\(kind.rawValue)|\(identity)"
        let preferredID = preferred?.effectiveBundleID?.lowercased()
        let orderedIDs: [String]
        if let preferredID {
            orderedIDs = [preferredID] + ids.filter { $0 != preferredID }
        } else {
            orderedIDs = ids
        }
        return DetectedCallContext(
            fingerprint: fingerprint,
            kind: kind,
            sourceName: sourceName,
            sourceBundleIDs: orderedIDs
        )
    }

    private static func sourceOrder(_ lhs: MicActivitySource, _ rhs: MicActivitySource) -> Bool {
        let left = lhs.effectiveBundleID ?? lhs.bundleID ?? "pid:\(lhs.pid)"
        let right = rhs.effectiveBundleID ?? rhs.bundleID ?? "pid:\(rhs.pid)"
        return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }

    private static func bundleIDs(_ source: MicActivitySource) -> [String] {
        [source.applicationBundleID, source.bundleID]
            .compactMap { $0?.lowercased() }
    }

    private static func isZoom(_ source: MicActivitySource) -> Bool {
        bundleIDs(source).contains { $0 == "us.zoom.xos" || $0.hasPrefix("us.zoom.xos.") }
    }

    private static func isTeams(_ source: MicActivitySource) -> Bool {
        bundleIDs(source).contains {
            $0 == "com.microsoft.teams" || $0.hasPrefix("com.microsoft.teams.") ||
            $0 == "com.microsoft.teams2" || $0.hasPrefix("com.microsoft.teams2.")
        }
    }

    private static func isWhatsApp(_ source: MicActivitySource) -> Bool {
        bundleIDs(source).contains { $0.contains("whatsapp") }
    }

    private static func isBrowser(_ source: MicActivitySource) -> Bool {
        bundleIDs(source).contains { id in
            id == "com.apple.safari" || id.hasPrefix("com.apple.safari.") ||
            id == "com.google.chrome" || id.hasPrefix("com.google.chrome.") ||
            id == "com.brave.browser" || id.hasPrefix("com.brave.browser.") ||
            id == "com.microsoft.edgemac" || id.hasPrefix("com.microsoft.edgemac.") ||
            id == "org.mozilla.firefox" || id.hasPrefix("org.mozilla.firefox.") ||
            id == "company.thebrowser.browser" || id.hasPrefix("company.thebrowser.browser.")
        }
    }

    private static func titleIndicatesGoogleMeet(_ title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return title.contains("meet.google.com") || title.contains("google meet")
    }
}
