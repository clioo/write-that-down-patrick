import XCTest
@testable import WriteThatDownKit

final class SessionOrchestratorTests: XCTestCase {

    // MARK: - Assembly

    private func config(
        inactivityMs: Int = 900_000,
        pollMs: Int = 50,
        graceMs: Int = 1_000_000
    ) -> AppConfiguration {
        AppConfiguration(
            outputDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            language: "en",
            engine: .default,
            inactivityTimeoutMs: inactivityMs,
            pollIntervalMs: pollMs,
            micInactivityGraceMs: graceMs
        )
    }

    /// Builds, starts, and waits until the orchestrator is observing.
    private func startOrchestrator(
        config: AppConfiguration,
        detector: MockMicSignalSource,
        capturer: MockAudioCapturer,
        engine: MockTranscriptionEngine,
        writer: MockTranscriptWriter,
        presenter: MockPresenter,
        permissions: MockPermissions,
        clock: TestClock
    ) async -> (SessionOrchestrator, Task<Void, Never>) {
        let orchestrator = SessionOrchestrator(
            config: config,
            detector: detector,
            makeCapturer: { capturer },
            makeEngine: { engine },
            makeWriter: { writer },
            presenter: presenter,
            permissions: permissions,
            now: { clock.now() }
        )
        let task = Task { await orchestrator.start() }
        _ = await TestSupport.waitUntil { detector.isStarted }
        return (orchestrator, task)
    }

    private func makePresenter() async -> MockPresenter {
        await MainActor.run { MockPresenter() }
    }

    // MARK: - §15.1 Detection and state

    func testIdleToRecordingOnMicActive() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        let recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording, "Idle → Recording on mic active (§15.1)")

        let startCount = await engine.startCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(capturer.startCount, 1)
        XCTAssertEqual(writer.beganCount, 1)
        let shown = await presenter.captionsShown
        XCTAssertTrue(shown, "captions show on start (§15.5)")
        let notified = await presenter.notifiedStart
        XCTAssertEqual(notified, 1, "notification on detect+start (§15.5)")
        let sawRecording = await presenter.sawStatus(.recording, reason: nil)
        XCTAssertTrue(sawRecording)

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testSecondSessionNotStartedWhileRecording() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        // Subsequent active ticks must not begin a second session (§6.3, §15.1).
        detector.emit(true)
        detector.emit(true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let startCount = await engine.startCount
        XCTAssertEqual(startCount, 1, "at most one active session (§6.3)")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testManualStopEndsWithManual() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let final = Segment(index: 0, timestamp: 1, text: "hello", isFinal: true)
        let engine = MockTranscriptionEngine(pushResponses: [[final]])
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        orchestrator.requestManualStop()
        let idle = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .idle }
        XCTAssertTrue(idle)
        XCTAssertEqual(writer.finalizeCount, 1, "document finalized on manual stop")
        let sawManual = await presenter.sawStatus(.saved, reason: .manual)
        XCTAssertTrue(sawManual, "manual stop ends with end_reason = manual (§15.1)")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testInactivityTimeoutEndsWithInactivity() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // 1 s audio-inactivity timeout; mic-off grace huge so only the audio path fires.
        let (orchestrator, task) = await startOrchestrator(
            config: config(inactivityMs: 1_000, pollMs: 50, graceMs: 10_000_000),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        // No loud audio arrives; advance the clock past the timeout, then tick.
        clock.advance(by: 2.0)
        detector.emit(true) // a poll tick (mic still "in use")

        let idle = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .idle }
        XCTAssertTrue(idle)
        let sawInactivity = await presenter.sawStatus(.saved, reason: .inactivity)
        XCTAssertTrue(sawInactivity, "sustained audio inactivity ends with end_reason = inactivity (§7.3, §15.1)")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testSustainedMicOffEndsWithSystemStop() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // grace = 150 ms, poll = 50 ms → 3 inactive ticks ends the session.
        let (orchestrator, task) = await startOrchestrator(
            config: config(inactivityMs: 10_000_000, pollMs: 50, graceMs: 150),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        detector.emit(false)
        detector.emit(false)
        detector.emit(false)

        let idle = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .idle }
        XCTAssertTrue(idle)
        let sawStop = await presenter.sawStatus(.saved, reason: .systemStop)
        XCTAssertTrue(sawStop, "sustained mic-off ends with end_reason = system_stop (§5.3)")

        orchestrator.requestShutdown(); _ = await task.value
    }

    // MARK: - §15.3 Transcription engine

    func testPartialsNotWrittenFinalsWritten() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let partial = Segment(index: -1, timestamp: 0, text: "partial", isFinal: false)
        let final = Segment(index: 0, timestamp: 1, text: "final text", isFinal: true)
        let engine = MockTranscriptionEngine(pushResponses: [[partial], [final]])
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        capturer.emit(TestSupport.loudBuffer()) // → partial
        capturer.emit(TestSupport.loudBuffer()) // → final

        let wrote = await TestSupport.waitUntil { writer.appended.count == 1 }
        XCTAssertTrue(wrote)
        XCTAssertEqual(writer.appended.first?.text, "final text", "only finals written (§8.3, §15.3)")
        XCTAssertEqual(writer.appended.first?.index, 0, "orchestrator assigns monotonic index")
        let partials = await presenter.partials
        XCTAssertTrue(partials.contains { $0.text == "partial" }, "partials shown in captions (§8.3)")

        orchestrator.requestShutdown(); _ = await task.value
    }

    // MARK: - §15.6 Failures

    func testPermissionDeniedBlocksStart() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: false)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        let errored = await TestSupport.waitUntil { await !presenter.errors.isEmpty }
        XCTAssertTrue(errored, "denied permission informs the user (§15.6)")
        let status = await orchestrator.snapshot().sessionStatus
        XCTAssertEqual(status, .idle, "no session starts (§10.2)")
        let startCount = await engine.startCount
        XCTAssertEqual(startCount, 0)

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testCaptureFailureTransitionsToFailedThenIdle() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer(shouldThrowOnStart: true)
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        let sawFailed = await TestSupport.waitUntil { await presenter.sawStatus(.failed, reason: .error) }
        XCTAssertTrue(sawFailed, "capture failure → Failed (§15.6)")
        let idle = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .idle }
        XCTAssertTrue(idle, "returns to Idle and keeps observing (§10.2)")
        let stopCount = await engine.stopCount
        XCTAssertEqual(stopCount, 1, "engine torn down on capture failure")
        XCTAssertEqual(writer.beganCount, 0, "writer not opened on capture failure")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testEngineFailureDuringRecordingPreservesFinals() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let final1 = Segment(index: 0, timestamp: 1, text: "kept", isFinal: true)
        // First push yields a final; second push throws (engine failure mid-call).
        let engine = MockTranscriptionEngine(pushResponses: [[final1]], throwOnPushIndex: 1)
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        capturer.emit(TestSupport.loudBuffer()) // push 0 → final kept
        _ = await TestSupport.waitUntil { writer.appended.count == 1 }
        capturer.emit(TestSupport.loudBuffer()) // push 1 → throws → finalize preserving finals

        let idle = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .idle }
        XCTAssertTrue(idle)
        XCTAssertTrue(writer.appended.contains { $0.text == "kept" }, "captured finals preserved (§10.2)")
        XCTAssertEqual(writer.finalizeCount, 1, "session finalized after engine failure")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testPersistenceFailureDoesNotLoseSilently() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let final = Segment(index: 0, timestamp: 1, text: "boom", isFinal: true)
        let engine = MockTranscriptionEngine(pushResponses: [[final]])
        let writer = MockTranscriptWriter(throwOnAppendIndex: 0) // first append fails
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(), detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        capturer.emit(TestSupport.loudBuffer()) // push → final → append throws

        let errored = await TestSupport.waitUntil { await !presenter.errors.isEmpty }
        XCTAssertTrue(errored, "persistence failure surfaced visibly, not silently (§10.2, §15.6)")
        XCTAssertEqual(writer.finalizeCount, 1, "attempt to preserve content on persistence failure")

        orchestrator.requestShutdown(); _ = await task.value
    }
}
