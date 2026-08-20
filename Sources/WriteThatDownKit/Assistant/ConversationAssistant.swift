import Foundation

/// A model exposed by the OpenCode Go subscription. The provider is purposely
/// not configurable: meeting chat must never silently fall back to Codex or a
/// different API account.
public struct OpenCodeGoModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ConversationAssistantTurn: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public protocol ConversationAssistant: Sendable {
    /// Models are sourced from Pi's OpenCode Go catalog. Implementations may
    /// return a bundled fallback list when the local catalog cannot be queried.
    func availableModels(apiKey: String) async throws -> [OpenCodeGoModelOption]

    func answer(
        transcript: String,
        conversation: [ConversationAssistantTurn],
        question: String,
        modelID: String,
        apiKey: String
    ) async throws -> String

    func summarize(
        transcript: String,
        modelID: String,
        apiKey: String
    ) async throws -> String
}

public enum ConversationAssistantError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case piNotInstalled
    case invalidModel(String)
    case launchFailed(String)
    case requestFailed(String)
    case timedOut
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenCode Go API key to use meeting chat."
        case .piNotInstalled:
            return "Pi was not found. Install @earendil-works/pi-coding-agent or set WTD_PI_PATH."
        case let .invalidModel(model):
            return "\(model) is not a valid OpenCode Go model."
        case let .launchFailed(message):
            return "Pi could not start: \(message)"
        case let .requestFailed(message):
            return "OpenCode Go request failed: \(message)"
        case .timedOut:
            return "OpenCode Go took too long to respond."
        case .invalidResponse:
            return "Pi returned an unreadable response."
        }
    }
}
