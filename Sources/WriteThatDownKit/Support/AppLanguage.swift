import Foundation

/// The two interface languages currently shipped by Write That Down.
///
/// macOS places the user's primary app/system language first in
/// `Locale.preferredLanguages`. We intentionally inspect only that first
/// language: Spanish gets Spanish, English gets English, and every unsupported
/// language falls back to English.
public enum AppLanguage: String, Equatable, Sendable {
    case english = "en"
    case spanish = "es"

    public static var current: AppLanguage {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        let hasOverride = arguments.contains { $0.hasPrefix("--ui-language=") }
            || environment["WTD_UI_LANGUAGE"] != nil
        let bundleName = Bundle.main.bundleURL
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        let isPreview = arguments.contains("--preview-ui")
            || arguments.contains("--preview-summary")
            || arguments.contains("--preview-recording-prompt")
            || bundleName.contains("preview")
        if isPreview && !hasOverride {
            return .english
        }
        return resolve(
            arguments: arguments,
            environment: environment,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    static func resolve(
        arguments: [String],
        environment: [String: String],
        preferredLanguages: [String]
    ) -> AppLanguage {
        // This override keeps screenshot fixtures and automated tests stable.
        // Normal launches do not set it and always follow macOS.
        let argumentOverride = arguments
            .first { $0.hasPrefix("--ui-language=") }
            .map { String($0.dropFirst("--ui-language=".count)) }
        let override = argumentOverride ?? environment["WTD_UI_LANGUAGE"]
        if let override, let language = from(identifier: override) {
            return language
        }

        guard let primary = preferredLanguages.first else { return .english }
        return from(identifier: primary) ?? .english
    }

    private static func from(identifier: String) -> AppLanguage? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let code = normalized.split(separator: "-").first.map(String.init) ?? normalized
        switch code {
        case "es": return .spanish
        case "en": return .english
        default: return nil
        }
    }

    public func text(_ english: String, spanish: String) -> String {
        switch self {
        case .english: return english
        case .spanish: return spanish
        }
    }
}
