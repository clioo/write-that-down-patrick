import Foundation
@testable import WriteThatDownKit

// MARK: - Mock microphone signal source

/// Test double for `MicSignalSource`. Captures the orchestrator's handler so a
/// test can drive mic-active/inactive ticks deterministically.
final class MockMicSignalSource: MicSignalSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?
    private(set) var stopped = false

    var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return handler != nil
    }

    func start(onSample: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); handler = onSample; lock.unlock()
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    func emit(_ active: Bool) {
        lock.lock(); let h = handler; lock.unlock()
        h?(active)
    }
}

// MARK: - Mock audio capturer

final class MockAudioCapturer: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AudioBuffer) -> Void)?
    let shouldThrowOnStart: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(shouldThrowOnStart: Bool = false) {
        self.shouldThrowOnStart = shouldThrowOnStart
    }

    var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return handler != nil
    }

    func start(onBuffer: @escaping @Sendable (AudioBuffer) -> Void) async throws {
        if shouldThrowOnStart { throw CaptureError.startFailed("mock capture failure") }
        register(onBuffer)
    }

    func stop() async {
        unregister()
    }

    private func register(_ h: @escaping @Sendable (AudioBuffer) -> Void) {
        lock.lock(); handler = h; startCount += 1; lock.unlock()
    }
    private func unregister() {
        lock.lock(); handler = nil; stopCount += 1; lock.unlock()
    }

    func emit(_ buffer: AudioBuffer) {
        lock.lock(); let h = handler; lock.unlock()
        h?(buffer)
    }
}

// MARK: - Mock transcription engine

/// Scriptable engine: returns the queued segments for each `push`, and a fixed
/// set on `stop`. Can be configured to throw on start or on a given push.
actor MockTranscriptionEngine: TranscriptionEngine {
    nonisolated let id = "mock-engine"

    private var pushResponses: [[Segment]]
    private let stopResponse: [Segment]
    private let throwOnStart: Bool
    private let throwOnPushIndex: Int?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pushCount = 0

    init(
        pushResponses: [[Segment]] = [],
        stopResponse: [Segment] = [],
        throwOnStart: Bool = false,
        throwOnPushIndex: Int? = nil
    ) {
        self.pushResponses = pushResponses
        self.stopResponse = stopResponse
        self.throwOnStart = throwOnStart
        self.throwOnPushIndex = throwOnPushIndex
    }

    func start(_ config: EngineConfig) async throws {
        startCount += 1
        if throwOnStart { throw EngineError.initializationFailed("mock engine start failure") }
    }

    func push(_ buffer: AudioBuffer) async throws -> [Segment] {
        defer { pushCount += 1 }
        if let idx = throwOnPushIndex, idx == pushCount {
            throw EngineError.transcriptionFailed("mock push failure")
        }
        guard !pushResponses.isEmpty else { return [] }
        return pushResponses.removeFirst()
    }

    func stop() async throws -> [Segment] {
        stopCount += 1
        return stopResponse
    }
}

// MARK: - Mock transcript writer

final class MockTranscriptWriter: TranscriptWriting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var beganCount = 0
    private(set) var appended: [Segment] = []
    private(set) var finalizeCount = 0
    private(set) var finalizedDuration: TimeInterval?
    private var url: URL?
    let throwOnBegin: Bool
    let throwOnAppendIndex: Int?

    init(throwOnBegin: Bool = false, throwOnAppendIndex: Int? = nil) {
        self.throwOnBegin = throwOnBegin
        self.throwOnAppendIndex = throwOnAppendIndex
    }

    var currentFileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    @discardableResult
    func begin(session: RecordingSession, title: String, startedAtLocal: Date) throws -> URL {
        if throwOnBegin { throw PersistenceError.folderCreationFailed("mock begin failure") }
        lock.lock(); defer { lock.unlock() }
        beganCount += 1
        let u = URL(fileURLWithPath: "/tmp/mock/\(session.id).md")
        url = u
        return u
    }

    func appendFinal(_ segment: Segment) throws {
        lock.lock()
        let idx = appended.count
        lock.unlock()
        if let throwIdx = throwOnAppendIndex, throwIdx == idx {
            throw PersistenceError.writeFailed("mock append failure")
        }
        lock.lock(); appended.append(segment); lock.unlock()
    }

    @discardableResult
    func finalize(duration: TimeInterval) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        finalizeCount += 1
        finalizedDuration = duration
        return url ?? URL(fileURLWithPath: "/tmp/mock/unknown.md")
    }
}

// MARK: - Mock presenter

@MainActor
final class MockPresenter: Presenting {
    private(set) var statusUpdates: [(SessionStatus, EndReason?)] = []
    private(set) var partials: [Segment] = []
    private(set) var finals: [Segment] = []
    private(set) var errors: [String] = []
    private(set) var captionsShown = false
    private(set) var captionsHidden = false
    private(set) var notifiedStart = 0

    func sessionWillStart(session: RecordingSession) {}
    func showCaptions() { captionsShown = true }
    func hideCaptions() { captionsHidden = true }
    func showPartial(_ segment: Segment) { partials.append(segment) }
    func commitFinal(_ segment: Segment) { finals.append(segment) }
    func updateStatus(_ status: SessionStatus, endReason: EndReason?) { statusUpdates.append((status, endReason)) }
    func notifyCallStarted(session: RecordingSession) { notifiedStart += 1 }
    func presentError(_ message: String) { errors.append(message) }

    var lastStatus: SessionStatus? { statusUpdates.last?.0 }
    func sawStatus(_ status: SessionStatus, reason: EndReason?) -> Bool {
        statusUpdates.contains { $0.0 == status && $0.1 == reason }
    }
}

// MARK: - Mock permissions

final class MockPermissions: PermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PermissionSnapshot

    init(canStart: Bool) {
        self.snapshot = PermissionSnapshot(
            microphone: canStart ? .granted : .denied,
            screenCapture: canStart ? .granted : .denied,
            notifications: .granted,
            speech: .notRequired
        )
    }

    func set(_ snapshot: PermissionSnapshot) {
        lock.lock(); self.snapshot = snapshot; lock.unlock()
    }

    func currentStatus() async -> PermissionSnapshot {
        read()
    }

    func requestAll() async -> PermissionSnapshot {
        read()
    }

    private func read() -> PermissionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}

// MARK: - Test clock

/// Mutable clock so inactivity-timeout tests are deterministic.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { self.date = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock()
    }
}

// MARK: - Async helpers

enum TestSupport {
    /// Polls `condition` until true or the timeout elapses.
    static func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    /// A non-silent buffer (RMS above any reasonable activity threshold).
    static func loudBuffer(sampleRate: Double = 16_000, frames: Int = 1_600) -> AudioBuffer {
        AudioBuffer(samples: [Float](repeating: 0.5, count: frames), sampleRate: sampleRate)
    }

    /// A silent buffer.
    static func silentBuffer(sampleRate: Double = 16_000, frames: Int = 1_600) -> AudioBuffer {
        AudioBuffer(samples: [Float](repeating: 0.0, count: frames), sampleRate: sampleRate)
    }
}
