import Foundation

/// Errors raised while validating configuration before any operation starts (§11).
public enum ConfigurationError: Error, Equatable, LocalizedError {
    case emptyOutputDirectory
    case emptyLanguage
    case nonPositive(field: String, value: Int)
    case outOfRange(field: String, value: Double)

    public var errorDescription: String? {
        switch self {
        case .emptyOutputDirectory:
            return "Configuration error: output directory must not be empty."
        case .emptyLanguage:
            return "Configuration error: language must not be empty (use \"auto\" for automatic detection)."
        case let .nonPositive(field, value):
            return "Configuration error: \(field) must be a positive integer (got \(value))."
        case let .outOfRange(field, value):
            return "Configuration error: \(field) is out of range (got \(value))."
        }
    }
}
