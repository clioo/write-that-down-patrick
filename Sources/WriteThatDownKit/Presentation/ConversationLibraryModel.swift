import Combine
import Foundation

public struct StoredConversation: Identifiable, Equatable, Sendable {
    public let id: String
    public let fileURL: URL
    public let title: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let segments: [Segment]
    public let savedSummary: String?

    public init(
        fileURL: URL,
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        segments: [Segment],
        savedSummary: String? = nil
    ) {
        self.id = fileURL.standardizedFileURL.path
        self.fileURL = fileURL
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.segments = segments
        self.savedSummary = savedSummary
    }

    public var transcriptText: String {
        segments.map { "[\($0.formattedOffset)] \($0.text)" }.joined(separator: "\n")
    }
}

/// Reads the app's own Markdown transcript format into navigation records.
/// Only `YYYY-MM-DD/*.md` conversation documents with at least one segment are
/// indexed; summary sidecars, provisional recordings, and unrelated Markdown
/// files are deliberately ignored.
public struct ConversationLibraryStore: Sendable {
    public let outputDir: URL

    public init(outputDir: URL) {
        self.outputDir = outputDir.standardizedFileURL
    }

    public func load() -> [StoredConversation] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var conversations: [StoredConversation] = []
        for folder in folders where Self.isDateFolder(folder.lastPathComponent) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fileManager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  )
            else { continue }

            for file in files where Self.isTranscriptFile(file) {
                if let conversation = Self.parse(file), !conversation.segments.isEmpty {
                    conversations.append(conversation)
                }
            }
        }

        return conversations.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.fileURL.lastPathComponent > $1.fileURL.lastPathComponent
        }
    }

    private static func isDateFolder(_ name: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: name) else { return false }
        return formatter.string(from: date) == name
    }

    private static func isTranscriptFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return url.pathExtension.lowercased() == "md"
            && !name.hasSuffix("-summary.md")
            && !name.contains("recording")
    }

    private static func parse(_ url: URL) -> StoredConversation? {
        guard let document = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = document.components(separatedBy: .newlines)
        let title = lines.first(where: { $0.hasPrefix("# ") })
            .map { String($0.dropFirst(2)) }
            ?? url.deletingPathExtension().lastPathComponent
        guard let dateLine = lines.first(where: { $0.hasPrefix("**Date:** ") }),
              let startedAt = parseDate(String(dateLine.dropFirst("**Date:** ".count)))
        else { return nil }

        let durationLine = lines.first(where: { $0.hasPrefix("**Duration:** ") }) ?? ""
        let durationMinutes = firstInteger(in: durationLine) ?? 0
        let transcriptStart = lines.firstIndex(of: "## Transcript").map { $0 + 1 } ?? lines.startIndex
        var segments: [Segment] = []
        for line in lines[transcriptStart...] {
            guard let parsed = parseSegment(line, index: segments.count) else { continue }
            segments.append(parsed)
        }

        let base = url.deletingPathExtension().lastPathComponent
        let summaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-summary.md")
        let savedSummary = loadSummary(at: summaryURL)
        return StoredConversation(
            fileURL: url,
            title: title,
            startedAt: startedAt,
            duration: TimeInterval(durationMinutes * 60),
            segments: segments,
            savedSummary: savedSummary
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)
    }

    private static func firstInteger(in value: String) -> Int? {
        let digits = value.split(whereSeparator: { !$0.isNumber }).first
        return digits.flatMap { Int($0) }
    }

    private static func parseSegment(_ line: String, index: Int) -> Segment? {
        guard line.count >= 11,
              line.first == "[",
              line.dropFirst(9).first == "]"
        else { return nil }
        let timestamp = line.dropFirst().prefix(8).split(separator: ":")
        guard timestamp.count == 3,
              let hours = Double(timestamp[0]),
              let minutes = Double(timestamp[1]),
              let seconds = Double(timestamp[2])
        else { return nil }
        let text = String(line.dropFirst(11)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Segment(
            index: index,
            timestamp: hours * 3_600 + minutes * 60 + seconds,
            text: text,
            isFinal: true
        )
    }

    private static func loadSummary(at url: URL) -> String? {
        guard var summary = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if summary.hasPrefix("# Meeting summary") {
            summary = String(summary.dropFirst("# Meeting summary".count))
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
public final class ConversationLibraryModel: ObservableObject {
    @Published public private(set) var conversations: [StoredConversation] = []
    /// `nil` represents the current/live conversation.
    @Published public private(set) var selectedConversationID: String?

    public let currentWorkspace: ConversationWorkspaceModel
    private let store: ConversationLibraryStore
    private var archivedWorkspaces: [String: ConversationWorkspaceModel] = [:]

    public init(
        outputDir: URL,
        currentWorkspace: ConversationWorkspaceModel,
        selectMostRecent: Bool = true
    ) {
        self.store = ConversationLibraryStore(outputDir: outputDir)
        self.currentWorkspace = currentWorkspace
        refresh()
        if selectMostRecent {
            selectedConversationID = conversations.first?.id
        }
    }

    public var selectedConversation: StoredConversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    public var selectedWorkspace: ConversationWorkspaceModel {
        guard let selectedConversationID else { return currentWorkspace }
        return archivedWorkspaces[selectedConversationID] ?? currentWorkspace
    }

    public var selectedTranscriptText: String {
        selectedConversation?.transcriptText ?? ""
    }

    public var allWorkspaces: [ConversationWorkspaceModel] {
        [currentWorkspace] + Array(archivedWorkspaces.values)
    }

    public func selectConversation(id: String?) {
        guard let id else {
            selectedConversationID = nil
            return
        }
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedConversationID = id
    }

    public func refresh() {
        conversations = store.load()
        let validIDs = Set(conversations.map(\.id))
        archivedWorkspaces = archivedWorkspaces.filter { validIDs.contains($0.key) }
        for conversation in conversations where archivedWorkspaces[conversation.id] == nil {
            let workspace = ConversationWorkspaceModel()
            workspace.loadArchivedConversation(
                startedAt: conversation.startedAt,
                duration: conversation.duration,
                summary: conversation.savedSummary
            )
            archivedWorkspaces[conversation.id] = workspace
        }
        if let selectedConversationID, !validIDs.contains(selectedConversationID) {
            self.selectedConversationID = conversations.first?.id
        }
    }

    public func updatePersistedSummary(_ summary: String, transcriptPath: String) {
        refresh()
        let id = URL(fileURLWithPath: transcriptPath).standardizedFileURL.path
        archivedWorkspaces[id]?.completeSummary(summary)
    }

    func installPreviewConversations(_ previewConversations: [StoredConversation]) {
        conversations = previewConversations.sorted { $0.startedAt > $1.startedAt }
        archivedWorkspaces.removeAll()
        for conversation in conversations {
            let workspace = ConversationWorkspaceModel()
            workspace.loadArchivedConversation(
                startedAt: conversation.startedAt,
                duration: conversation.duration,
                summary: conversation.savedSummary
            )
            archivedWorkspaces[conversation.id] = workspace
        }
        selectedConversationID = nil
    }
}
