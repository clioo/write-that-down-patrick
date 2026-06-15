import XCTest
@testable import WriteThatDownKit

final class SessionOrchestratorTests: XCTestCase {

    // MARK: - Assembly

    private func config(
        inactivityMs: Int = 900_000,
        pollMs: Int = 50,
        graceMs: Int = 1_000_000,
        startConfirmMs: Int = 0, // 0 → start on first mic-active tick
        retryCooldownMs: Int = 0 // 0 → retry on every confirm window
    ) -> AppConfiguration {
        AppConfiguration(
            outputDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            language: "en",
            engine: .default,
            inactivityTimeoutMs: inactivityMs,
            pollIntervalMs: pollMs,
            micInactivityGraceMs: graceMs,
            startConfirmMs: startConfirmMs,
            startRetryCooldownMs: retryCooldownMs
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

    func testStartConfirmWindowIgnoresBriefMicBlip() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // startConfirmMs=150, pollMs=50 → 1 + ceil(150/50) = 4 consecutive
        // active ticks required (first tick is the 0 ms baseline).
        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 150),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        // Three active ticks (= 100 ms confirmed) then released — a blip,
        // below the 150 ms window.
        detector.emit(true)
        detector.emit(true)
        detector.emit(true)
        detector.emit(false)

        // Prove the blip started nothing by driving a FULL confirm window next
        // and asserting exactly ONE session results — stronger than a wall-clock
        // sleep, which could pass vacuously before events were processed.
        detector.emit(true)
        detector.emit(true)
        detector.emit(true)
        detector.emit(true)
        let recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording)
        let startCount = await engine.startCount
        XCTAssertEqual(startCount, 1, "the blip must not have started a session of its own (§5.2)")
        let notified = await presenter.notifiedStart
        XCTAssertEqual(notified, 1, "no notification for the blip — only for the confirmed session")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testConfirmWindowRoundsUpNonMultipleDurations() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // 120 ms confirm / 50 ms poll → 1 + ceil(2.4) = 4 ticks required.
        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 120),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        detector.emit(true)
        detector.emit(true) // 3 ticks = 100 ms proven < 120 ms → must NOT start
        try? await Task.sleep(nanoseconds: 100_000_000)
        var startCount = await engine.startCount
        XCTAssertEqual(startCount, 0, "ceil rounding: 3 ticks prove only 100 ms < 120 ms")

        detector.emit(true) // 4th tick = 150 ms proven ≥ 120 ms → start
        let recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording)
        startCount = await engine.startCount
        XCTAssertEqual(startCount, 1)

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testConfirmWindowShorterThanPollNeedsTwoTicks() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // 30 ms confirm / 50 ms poll → 1 + ceil(0.6) = 2 ticks: one active poll
        // proves 0 ms and must not start; the second proves 50 ms ≥ 30 ms.
        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 30),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        var startCount = await engine.startCount
        XCTAssertEqual(startCount, 0, "a single active poll proves 0 ms of sustained activity")

        detector.emit(true)
        let recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording)
        startCount = await engine.startCount
        XCTAssertEqual(startCount, 1)

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testStartConfirmWindowStartsAfterSustainedActivity() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // 4 consecutive active ticks required (1 baseline + 150/50 = 3 proving
        // ticks); a blip first must not consume them.
        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 150),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        detector.emit(false) // resets the confirm counter
        detector.emit(true)
        detector.emit(true)
        detector.emit(true)
        detector.emit(true) // 4th consecutive (150 ms confirmed) → start

        let recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording, "sustained mic activity past the confirm window starts a session")
        let startCount = await engine.startCount
        XCTAssertEqual(startCount, 1)

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testPermissionGrantMidEpisodeStartsOnNextPollWithoutNewWindow() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: false) // denied at launch
        let clock = TestClock()

        // 1 + ceil(100/50) = 3 ticks to confirm.
        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 100),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        // Confirm window completes while denied → warned, no session, counter held.
        detector.emit(true)
        detector.emit(true)
        detector.emit(true)
        let warned = await TestSupport.waitUntil { await !presenter.errors.isEmpty }
        XCTAssertTrue(warned)
        var startCount = await engine.startCount
        XCTAssertEqual(startCount, 0)

        // User grants permission mid-meeting (mic continuously active).
        permissions.set(PermissionSnapshot(
            microphone: .granted, screenCapture: .granted,
            notifications: .granted, speech: .notRequired))

        // ONE more poll must start the session — no re-accumulated window.
        detector.emit(true)
        let recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording, "mid-episode grant starts on the next poll, not after another confirm window")
        startCount = await engine.startCount
        XCTAssertEqual(startCount, 1)

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testDeniedWarningReArmsAfterMicRelease() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: false)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 0), // 1 tick confirms
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        // First blocked episode → exactly one warning (no per-poll spam).
        detector.emit(true)
        detector.emit(true)
        _ = await TestSupport.waitUntil { await presenter.errors.count == 1 }
        var errorCount = await presenter.errors.count
        XCTAssertEqual(errorCount, 1, "one warning per blocked episode, not per poll")

        // Mic released → episode over. A later distinct attempt re-warns.
        detector.emit(false)
        detector.emit(true)
        let rewarned = await TestSupport.waitUntil { await presenter.errors.count == 2 }
        XCTAssertTrue(rewarned, "a distinct later blocked attempt must warn again (§10.2)")
        errorCount = await presenter.errors.count
        XCTAssertEqual(errorCount, 2)

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testSilenceEndsSessionViaAudioPathWithoutMicPoll() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // Small audio-inactivity timeout; mic-off grace huge.
        let (orchestrator, task) = await startOrchestrator(
            config: config(inactivityMs: 1_000, pollMs: 50, graceMs: 10_000_000),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        // Loud audio stamps activity; then the clock jumps past the timeout and
        // a SILENT buffer arrives — with NO further mic poll, the audio path
        // itself must end the session.
        capturer.emit(TestSupport.loudBuffer())
        _ = await TestSupport.waitUntil { await engine.pushCount == 1 } // loud buffer fully handled
        clock.advance(by: 2.0)
        capturer.emit(TestSupport.silentBuffer())

        let idle = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .idle }
        XCTAssertTrue(idle)
        let sawInactivity = await presenter.sawStatus(.saved, reason: .inactivity)
        XCTAssertTrue(sawInactivity, "silence timeout fires from the audio stream, not only on mic polls (§7.3)")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testStartupFailureWarnsOnceAndBacksOff() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine(throwOnStart: true) // persistent failure
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 0, retryCooldownMs: 60_000),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        // First confirm → attempt fails → exactly one visible error.
        detector.emit(true)
        let warned = await TestSupport.waitUntil { await presenter.errors.count == 1 }
        XCTAssertTrue(warned)
        var startCount = await engine.startCount
        XCTAssertEqual(startCount, 1)

        // Mic stays active: further polls must NOT retry within the cooldown
        // and must NOT pop more errors (the spam the cooldown exists to stop).
        detector.emit(true)
        detector.emit(true)
        detector.emit(true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        startCount = await engine.startCount
        XCTAssertEqual(startCount, 1, "no retry within startRetryCooldownMs")
        var errorCount = await presenter.errors.count
        XCTAssertEqual(errorCount, 1, "ONE visible error per mic episode, never per poll")

        // Past the cooldown a retry is allowed — but the episode already
        // warned, so still no second error.
        clock.advance(by: 61)
        detector.emit(true)
        let retried = await TestSupport.waitUntil { await engine.startCount == 2 }
        XCTAssertTrue(retried, "retry resumes after the cooldown elapses")
        errorCount = await presenter.errors.count
        XCTAssertEqual(errorCount, 1, "retry after cooldown stays silent within the same episode")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testStartupFailureRetriesImmediatelyOnNewEpisode() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine(throwOnStart: true)
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, startConfirmMs: 0, retryCooldownMs: 60_000),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await presenter.errors.count == 1 }

        // Mic released → episode over → cooldown cleared, warning re-armed.
        detector.emit(false)
        // A new call retries immediately (no waiting out the old cooldown) and
        // may warn once again.
        detector.emit(true)
        let retried = await TestSupport.waitUntil { await engine.startCount == 2 }
        XCTAssertTrue(retried, "a new mic episode retries immediately")
        let rewarned = await TestSupport.waitUntil { await presenter.errors.count == 2 }
        XCTAssertTrue(rewarned, "a new episode gets its own single error")

        orchestrator.requestShutdown(); _ = await task.value
    }

    func testSecondMeetingIsDetectedAfterFirstSessionSaves() async {
        let detector = MockMicSignalSource()
        let capturer = MockAudioCapturer()
        let engine = MockTranscriptionEngine()
        let writer = MockTranscriptWriter()
        let presenter = await makePresenter()
        let permissions = MockPermissions(canStart: true)
        let clock = TestClock()

        // Realistic shape: 3-tick confirm window, small mic-off grace.
        let (orchestrator, task) = await startOrchestrator(
            config: config(pollMs: 50, graceMs: 100, startConfirmMs: 100),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        // ── Meeting 1: confirm window → recording.
        detector.emit(true); detector.emit(true); detector.emit(true)
        var recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording, "meeting 1 starts")

        // Mic released, sustained → system_stop → Saved → Idle.
        detector.emit(false); detector.emit(false); detector.emit(false); detector.emit(false)
        let idle = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .idle }
        XCTAssertTrue(idle, "meeting 1 saved and back to observing")
        var startCount = await engine.startCount
        XCTAssertEqual(startCount, 1)

        // A quiet gap between meetings (mic stays off).
        detector.emit(false); detector.emit(false)

        // ── Meeting 2: mic active again → MUST start a new session.
        detector.emit(true); detector.emit(true); detector.emit(true)
        recording = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }
        XCTAssertTrue(recording, "meeting 2 must be detected after meeting 1 saved")
        startCount = await engine.startCount
        XCTAssertEqual(startCount, 2, "a second engine session must start")

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
        // The presenter is told where the transcript lives: once at begin
        // (provisional) and once at finalize (final path).
        let paths = await presenter.transcriptPaths
        XCTAssertEqual(paths.count, 2, "transcript path reported at begin and at finalize")
        XCTAssertTrue(paths.allSatisfy { $0?.isEmpty == false })

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

        // grace = 150 ms, poll = 50 ms → first inactive tick is the baseline,
        // so 4 inactive ticks prove (4-1)·50 = 150 ms ≥ grace and end the session.
        let (orchestrator, task) = await startOrchestrator(
            config: config(inactivityMs: 10_000_000, pollMs: 50, graceMs: 150),
            detector: detector, capturer: capturer, engine: engine,
            writer: writer, presenter: presenter, permissions: permissions, clock: clock)

        detector.emit(true)
        _ = await TestSupport.waitUntil { await orchestrator.snapshot().sessionStatus == .recording }

        detector.emit(false)
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
