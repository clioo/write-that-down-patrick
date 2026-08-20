import Combine
import Foundation

/// The durable presentation state for one conversation. It deliberately lives
/// outside `StatusModel`: the recorder returns from `.saved` to `.idle`
/// immediately, while the user still needs to read the chat and summary.
@MainActor
public final class ConversationWorkspaceModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case live
        case finalizing
        case finished
        case failed
    }

    public enum Tab: String, CaseIterable, Equatable, Sendable {
        case chat
        case summary
    }

    public enum SummaryState: Equatable, Sendable {
        case locked
        case generating
        case ready(String)
        case empty
        case failed(String)
    }

    public struct AssistantModel: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String

        public init(id: String, title: String, detail: String = "OpenCode Go") {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    public struct Message: Identifiable, Equatable, Sendable {
        public enum Role: Equatable, Sendable {
            case user
            case assistant
        }

        public let id: UUID
        public let role: Role
        public var content: String
        public var isStreaming: Bool
        public var errorMessage: String?

        public init(
            id: UUID = UUID(),
            role: Role,
            content: String,
            isStreaming: Bool = false,
            errorMessage: String? = nil
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.isStreaming = isStreaming
            self.errorMessage = errorMessage
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public var selectedTab: Tab = .chat
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var summary: SummaryState = .locked
    @Published public private(set) var sessionStartedAt: Date?
    @Published public private(set) var sessionEndedAt: Date?
    @Published public private(set) var sessionError: String?

    /// Only configuration status is observable. The API key itself is never
    /// stored in this model (nor exposed through a published property).
    @Published public var isConfigured = false
    @Published public var configurationError: String?
    @Published public var assistantModels: [AssistantModel] = []
    @Published public var selectedAssistantModelID = ""
    @Published public private(set) var isAnswering = false

    public init() {}

    public var selectedAssistantModel: AssistantModel? {
        assistantModels.first { $0.id == selectedAssistantModelID }
    }

    public var conversationTurns: [ConversationAssistantTurn] {
        messages.compactMap { message in
            guard !message.content.isEmpty else { return nil }
            return ConversationAssistantTurn(
                id: message.id,
                role: message.role == .user ? .user : .assistant,
                text: message.content
            )
        }
    }

    public var duration: TimeInterval? {
        guard let start = sessionStartedAt else { return nil }
        return max(0, (sessionEndedAt ?? Date()).timeIntervalSince(start))
    }

    /// Maps the recorder's short-lived state machine into presentation state.
    /// `.idle` intentionally does not erase a finished/failed conversation.
    public func updateSessionStatus(
        _ status: SessionStatus,
        startedAt: Date? = nil,
        error: String? = nil
    ) {
        switch status {
        case .idle:
            switch phase {
            case .starting, .live, .finalizing:
                finishConversation()
            case .finished, .failed:
                break
            case .idle:
                phase = .idle
            }

        case .detected:
            beginConversation(startedAt: startedAt ?? Date())

        case .recording:
            let wasAlreadyLive = phase == .live
            if phase == .idle || phase == .finished || phase == .failed {
                beginConversation(startedAt: startedAt ?? Date())
            } else if !wasAlreadyLive, let startedAt {
                // Re-baseline when capture is actually ready so model-loading
                // time is not counted in the meeting clock or segment times.
                sessionStartedAt = startedAt
            } else if sessionStartedAt == nil {
                sessionStartedAt = startedAt ?? Date()
            }
            phase = .live

        case .finalizing:
            phase = .finalizing

        case .saved:
            finishConversation()

        case .failed:
            phase = .failed
            sessionEndedAt = Date()
            sessionError = error
            isAnswering = false
            finishStreamingMessages()
        }
    }

    public func beginConversation(startedAt: Date = Date()) {
        phase = .starting
        selectedTab = .chat
        messages.removeAll()
        summary = .locked
        sessionStartedAt = startedAt
        sessionEndedAt = nil
        sessionError = nil
        isAnswering = false
    }

    public func finishConversation(endedAt: Date = Date()) {
        guard phase != .idle || sessionStartedAt != nil else { return }
        phase = .finished
        sessionEndedAt = endedAt
        isAnswering = false
        finishStreamingMessages()
        selectedTab = .summary
        if case .locked = summary, isConfigured {
            summary = .generating
        }
    }

    /// Initializes a workspace for a transcript loaded from disk. Chat remains
    /// in memory for the current app launch, while any persisted summary is
    /// restored from its sidecar file.
    public func loadArchivedConversation(
        startedAt: Date,
        duration: TimeInterval,
        summary savedSummary: String?
    ) {
        phase = .finished
        selectedTab = .chat
        messages.removeAll()
        if let savedSummary, !savedSummary.isEmpty {
            summary = .ready(savedSummary)
        } else {
            summary = .locked
        }
        sessionStartedAt = startedAt
        sessionEndedAt = startedAt.addingTimeInterval(max(0, duration))
        sessionError = nil
        isAnswering = false
    }

    public func setAssistantModels(_ models: [AssistantModel], selectedID: String?) {
        assistantModels = models
        if let selectedID, models.contains(where: { $0.id == selectedID }) {
            selectedAssistantModelID = selectedID
        } else if !models.contains(where: { $0.id == selectedAssistantModelID }) {
            selectedAssistantModelID = models.first?.id ?? ""
        }
    }

    public func setAssistantModels(_ models: [OpenCodeGoModelOption], selectedID: String?) {
        setAssistantModels(
            models.map { AssistantModel(id: $0.id, title: $0.title) },
            selectedID: selectedID
        )
    }

    @discardableResult
    public func appendUserMessage(_ content: String) -> UUID {
        let message = Message(role: .user, content: content)
        messages.append(message)
        return message.id
    }

    @discardableResult
    public func beginAssistantResponse() -> UUID {
        finishStreamingMessages()
        let message = Message(role: .assistant, content: "", isStreaming: true)
        messages.append(message)
        isAnswering = true
        return message.id
    }

    public func appendAssistantDelta(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.role == .assistant }) else { return }
        messages[index].content += delta
        messages[index].isStreaming = true
        messages[index].errorMessage = nil
        isAnswering = true
    }

    public func finishAssistantResponse(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].isStreaming = false
        isAnswering = messages.contains { $0.isStreaming }
    }

    public func failAssistantResponse(_ message: String, responseID: UUID? = nil) {
        if let responseID,
           let index = messages.firstIndex(where: { $0.id == responseID }) {
            messages[index].isStreaming = false
            messages[index].errorMessage = message
        } else {
            messages.append(Message(role: .assistant, content: "", errorMessage: message))
        }
        isAnswering = false
    }

    public func beginSummary() {
        summary = .generating
        selectedTab = .summary
    }

    public func completeSummary(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = trimmed.isEmpty ? .empty : .ready(trimmed)
        selectedTab = .summary
    }

    public func failSummary(_ message: String) {
        summary = .failed(message)
        selectedTab = .summary
    }

    private func finishStreamingMessages() {
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
        isAnswering = false
    }
}
