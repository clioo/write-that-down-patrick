import Foundation

public struct PiAssistantModelOption: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public typealias OpenCodeGoModelOption = PiAssistantModelOption

public struct PiProviderAuthMethod: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case apiKey = "api_key"
        case oauth
    }

    public let kind: Kind
    public let name: String
    public let loginLabel: String?
    public let isSubscription: Bool
    public let isInteractive: Bool

    public var id: String { kind.rawValue }

    public init(
        kind: Kind,
        name: String,
        loginLabel: String? = nil,
        isSubscription: Bool = false,
        isInteractive: Bool = true
    ) {
        self.kind = kind
        self.name = name
        self.loginLabel = loginLabel
        self.isSubscription = isSubscription
        self.isInteractive = isInteractive
    }
}

public struct PiProviderOption: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let authMethods: [PiProviderAuthMethod]
    public let models: [PiAssistantModelOption]
    public let isConfigured: Bool
    public let configuredAuthType: PiProviderAuthMethod.Kind?

    public init(
        id: String,
        name: String,
        authMethods: [PiProviderAuthMethod],
        models: [PiAssistantModelOption],
        isConfigured: Bool,
        configuredAuthType: PiProviderAuthMethod.Kind? = nil
    ) {
        self.id = id
        self.name = name
        self.authMethods = authMethods
        self.models = models
        self.isConfigured = isConfigured
        self.configuredAuthType = configuredAuthType
    }
}

public struct PiAuthPrompt: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case text
        case secret
        case select
        case manualCode = "manual_code"
    }

    public struct Option: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let detail: String?
    }

    public let id: String
    public let kind: Kind
    public let message: String
    public let placeholder: String?
    public let options: [Option]
}

public enum PiAuthEvent: Equatable, Sendable {
    case info(message: String, links: [PiAuthLink])
    case authURL(URL, instructions: String?)
    case deviceCode(code: String, verificationURL: URL, expiresInSeconds: Int?)
    case progress(String)
}

public struct PiAuthLink: Equatable, Sendable {
    public let label: String?
    public let url: URL
}

public struct PiProviderAuthInteraction: Sendable {
    public let prompt: @Sendable (PiAuthPrompt) async throws -> String
    public let notify: @Sendable (PiAuthEvent) async -> Void

    public init(
        prompt: @escaping @Sendable (PiAuthPrompt) async throws -> String,
        notify: @escaping @Sendable (PiAuthEvent) async -> Void
    ) {
        self.prompt = prompt
        self.notify = notify
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
    func providerCatalog() async throws -> [PiProviderOption]
    func connect(
        providerID: String,
        authType: PiProviderAuthMethod.Kind,
        interaction: PiProviderAuthInteraction
    ) async throws
    func disconnect(providerID: String) async throws

    func answer(
        transcript: String,
        conversation: [ConversationAssistantTurn],
        question: String,
        providerID: String,
        modelID: String
    ) async throws -> String

    func summarize(
        transcript: String,
        providerID: String,
        modelID: String
    ) async throws -> String
}

public enum ConversationAssistantError: LocalizedError, Equatable, Sendable {
    case missingCredential(String)
    case piNotInstalled
    case invalidProvider(String)
    case invalidModel(String)
    case launchFailed(String)
    case requestFailed(String)
    case timedOut
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .missingCredential(provider):
            return "Connect \(provider) to use meeting chat."
        case .piNotInstalled:
            return "Pi was not found. Install @earendil-works/pi-coding-agent or set WTD_PI_PATH."
        case let .invalidProvider(provider):
            return "\(provider) is not a provider exposed by this Pi installation."
        case let .invalidModel(model):
            return "\(model) is not a valid model."
        case let .launchFailed(message):
            return "Pi could not start: \(message)"
        case let .requestFailed(message):
            return "AI request failed: \(message)"
        case .timedOut:
            return "The AI provider took too long to respond."
        case .invalidResponse:
            return "Pi returned an unreadable response."
        case .cancelled:
            return "Sign-in was cancelled."
        }
    }
}
