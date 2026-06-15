import Foundation

/// The single authority over session state (§3.1.4, §6). Implements the state
/// machine of §6 exactly and is the ONLY component that mutates `RuntimeState`.
///
/// ## Concurrency design
/// Every input — microphone-poll samples, mixed audio buffers, manual-stop — is
/// funneled into one `AsyncStream<Event>` consumed by a single serial loop
/// (`run`). Because the loop fully handles one event (including its `await`s)
/// before pulling the next, there is no actor reentrancy and segment ordering is
/// deterministic. External callers feed the loop through `nonisolated` yielders;
/// the actor's only async entry point is `run()`.
public actor SessionOrchestrator {

    public enum Event: Sendable {
        case micSample(Bool)
        case audio(AudioBuffer)
        case manualStop
        case shutdown
    }

    // MARK: Injected collaborators

    private let config: AppConfiguration
    private let detector: MicSignalSource
    private let makeCapturer: @Sendable () -> AudioCapturing
    private let makeEngine: @Sendable () -> TranscriptionEngine
    private let makeWriter: @Sendable () -> TranscriptWriting
    private let presenter: any Presenting
    private let permissions: PermissionChecking
    private let now: @Sendable () -> Date

    // MARK: State (single authoritative copy, §4.1.5)

    private var state: RuntimeState
    private var engine: TranscriptionEngine?
    private var capturer: AudioCapturing?
    private var writer: TranscriptWriting?

    private var finalSegmentCount = 0
    private var inactiveMicTicks = 0
    /// Consecutive mic-active polls observed while Idle — the "confirm window"
    /// counter (§5.2). A session starts only once this reaches `requiredStartTicks`.
    private var pendingStartTicks = 0
    private var permissionsOK = false
    private var didWarnPermission = false
    /// When the last session-startup failure occurred. While set and within
    /// `startRetryCooldownMs`, confirmed windows do NOT retry — a persistent
    /// failure (bad model, capture error) must not churn on every poll.
    private var lastStartFailureAt: Date?
    /// Whether the user has already seen a startup-failure error during the
    /// current continuous mic-active episode. ONE visible error per episode;
    /// re-armed when the mic is released (a new call may warn once again).
    private var didWarnStartFailure = false

    /// Number of consecutive mic-active polls required before starting a session.
    /// The first active poll is only the baseline observation (0 ms of confirmed
    /// sustained activity); each subsequent consecutive active poll proves one
    /// more `pollIntervalMs` of it. N ticks therefore prove (N-1)·poll ms, so we
    /// require `1 + ceil(startConfirmMs / poll)` ticks — guaranteeing at least
    /// `startConfirmMs` of observed sustained activity. The mic-off grace in the
    /// `.recording` branch uses the same baseline convention.
    /// `startConfirmMs == 0` → 1 tick: start on the first mic-on poll.
    private var requiredStartTicks: Int {
        let poll = max(1, config.pollIntervalMs)
        // Overflow-safe integer ceiling division (a Double→Int round-trip traps
        // for absurd-but-validated values like startConfirmMs = Int.max).
        let ticks = config.startConfirmMs / poll + (config.startConfirmMs % poll == 0 ? 0 : 1)
        return 1 + min(ticks, Int.max - 1)
    }

    private let eventContinuation: AsyncStream<Event>.Continuation
    private var eventStream: AsyncStream<Event>?

    // MARK: Init

    public init(
        config: AppConfiguration,
        detector: MicSignalSource,
        makeCapturer: @escaping @Sendable () -> AudioCapturing,
        makeEngine: @escaping @Sendable () -> TranscriptionEngine,
        makeWriter: @escaping @Sendable () -> TranscriptWriting,
        presenter: any Presenting,
        permissions: PermissionChecking,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.detector = detector
        self.makeCapturer = makeCapturer
        self.makeEngine = makeEngine
        self.makeWriter = makeWriter
        self.presenter = presenter
        self.permissions = permissions
        self.now = now
        self.state = RuntimeState(
            engineID: config.engine.rawValue,
            inactivityTimeoutMs: config.inactivityTimeoutMs,
            pollIntervalMs: config.pollIntervalMs
        )
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    // MARK: Public entry points

    /// Begins observing the detection signal and runs the event loop. Call from
    /// a long-lived `Task`; this does not return until `shutdown()` is invoked.
    public func start() async {
        let snapshot = await permissions.currentStatus()
        permissionsOK = snapshot.canStartSession
        await presenter.updateStatus(.idle, endReason: nil)

        detector.start { [weak self] active in
            self?.eventContinuation.yield(.micSample(active))
        }
        Log.orchestrator.notice("Orchestrator observing (permissionsOK=\(self.permissionsOK, privacy: .public)).")
        await run()
    }

    /// Requests a manual stop of the current session (§5.3). Safe to call from
    /// any thread/context.
    public nonisolated func requestManualStop() {
        eventContinuation.yield(.manualStop)
    }

    /// Requests a clean shutdown: stops the detector, finalizes any in-progress
    /// session, and ends the event loop. Routed through the serial event loop (not
    /// run as a separate actor task) so it cannot interleave with an in-flight
    /// handler — preserving the no-reentrancy invariant. `start()` returns once
    /// the loop has finished. Safe to call from any context.
    public nonisolated func requestShutdown() {
        eventContinuation.yield(.shutdown)
    }

    /// Snapshot of the authoritative runtime state (read-only).
    public func snapshot() -> RuntimeState { state }

    // MARK: Event loop

    private func run() async {
        guard let stream = eventStream else { return }
        eventStream = nil
        for await event in stream {
            await handle(event)
        }
        Log.orchestrator.notice("Orchestrator event loop ended.")
    }

    private func handle(_ event: Event) async {
        switch event {
        case let .micSample(active): await handleMicSample(active)
        case let .audio(buffer): await handleAudio(buffer)
        case .manualStop:
            if state.sessionStatus == .recording {
                await finalizeSession(reason: .manual)
            }
        case .shutdown:
            detector.stop()
            if state.sessionStatus == .recording {
                await finalizeSession(reason: .manual)
            }
            eventContinuation.finish() // ends `run()`, which returns from `start()`
        }
    }

    // MARK: Detection (§5, §14.1)

    private func handleMicSample(_ active: Bool) async {
        switch state.sessionStatus {
        case .idle:
            guard active else {
                // Mic released before the confirm window elapsed → it was a brief,
                // non-meeting blip. Discard it; no session/notification/transcript.
                // .info (not .debug): this is the only silent no-session path,
                // and exactly the line needed to field-debug "my call never
                // started". At most one line per mic release — no spam risk.
                if pendingStartTicks > 0 {
                    Log.orchestrator.notice("Mic blip ignored (\(self.pendingStartTicks, privacy: .public)/\(self.requiredStartTicks, privacy: .public) confirm ticks).")
                }
                pendingStartTicks = 0
                // Re-arm the warnings and clear the failure cooldown: the next
                // sustained-activity episode is a distinct call — it retries
                // immediately and deserves its own (single) visible error if
                // still failing (§10.2).
                didWarnPermission = false
                didWarnStartFailure = false
                lastStartFailureAt = nil
                return
            }
            // Mic in use. Require it to stay active for the confirm window before
            // starting a session, so brief mic use never triggers one (§5.2).
            // Clamped: while blocked on permissions the counter holds at the
            // threshold rather than growing unboundedly.
            pendingStartTicks = min(pendingStartTicks + 1, requiredStartTicks)
            guard pendingStartTicks >= requiredStartTicks else { return }

            // Confirmed. Refresh permission state — the user may have granted
            // access since launch. Block session starts until granted (§10.2).
            // The counter is NOT reset while blocked: the mic is still
            // continuously active, so a mid-meeting grant starts the session on
            // the very next poll instead of re-accumulating the confirm window.
            let snapshot = await permissions.currentStatus()
            permissionsOK = snapshot.canStartSession
            if permissionsOK {
                // Back off after a startup failure: while the mic stays active,
                // retry at most once per cooldown so a persistently failing
                // start doesn't churn (and notify) on every confirm window.
                if let failedAt = lastStartFailureAt {
                    let sinceMs = now().timeIntervalSince(failedAt) * 1000
                    if sinceMs < Double(config.startRetryCooldownMs) {
                        return // counter stays clamped; next poll re-checks
                    }
                }
                pendingStartTicks = 0
                didWarnPermission = false
                await beginSession()
            } else if !didWarnPermission {
                didWarnPermission = true
                await presenter.presentError(snapshot.blockingReason ?? "Required permissions are not granted.")
            }

        case .recording:
            if active {
                inactiveMicTicks = 0
            } else {
                inactiveMicTicks += 1
                // Baseline convention, same as the confirm window: the first
                // inactive poll proves 0 ms of mic-off; N ticks prove (N-1)·poll,
                // so `system_stop` fires only after ≥ micInactivityGraceMs of
                // observed sustained mic release (§5.3).
                let inactiveMs = (inactiveMicTicks - 1) * config.pollIntervalMs
                if inactiveMs >= config.micInactivityGraceMs {
                    Log.orchestrator.notice("Mic inactive \(inactiveMs, privacy: .public) ms → finalize (system_stop).")
                    await finalizeSession(reason: .systemStop)
                    return
                }
            }
            // Audio-level inactivity timeout (§7.3) — poll-side fallback; the
            // primary evaluation rides the audio stream in `handleAudio`.
            _ = await finalizeIfAudioInactive(via: "mic poll")

        default:
            // detected / finalizing / saved / failed are transient within the
            // serial loop; ignore detection ticks (§6.3 idempotency).
            break
        }
    }

    // MARK: Session start (§5.2, §14.2)

    private func beginSession() async {
        let startedAt = now()
        let id = RecordingSession.makeID(from: startedAt)
        var session = RecordingSession(
            id: id,
            startedAt: startedAt,
            status: .detected,
            audioSources: [
                AudioSource(kind: .system, active: false),
                AudioSource(kind: .microphone, active: false),
            ]
        )
        state.sessionStatus = .detected
        state.currentSession = session
        await presenter.updateStatus(.detected, endReason: nil)
        await presenter.sessionWillStart(session: session)
        Log.orchestrator.notice("Session \(id, privacy: .public) detected; starting capture/engine.")

        // 1. Engine (may incur model-load cost, §8.1).
        let engine = makeEngine()
        let engineConfig = EngineConfig(
            language: config.language,
            sampleRate: config.sampleRate,
            windowSeconds: config.transcriptionWindowSeconds,
            model: config.whisperModel,
            modelFolder: config.whisperModelFolder
        )
        do {
            try await engine.start(engineConfig)
        } catch {
            await failStartup(message: "Transcription engine failed to start: \(error.localizedDescription)",
                              engine: nil, capturer: nil, writer: nil)
            return
        }
        self.engine = engine
        state.engineID = engine.id

        // 2. Audio capture (system + microphone, §7.1).
        let capturer = makeCapturer()
        do {
            try await capturer.start { [weak self] buffer in
                self?.eventContinuation.yield(.audio(buffer))
            }
        } catch {
            await failStartup(message: "Audio capture failed: \(error.localizedDescription)",
                              engine: engine, capturer: nil, writer: nil)
            return
        }
        self.capturer = capturer
        session.audioSources = [
            AudioSource(kind: .system, active: true),
            AudioSource(kind: .microphone, active: true),
        ]

        // 3. Open the transcript document.
        let writer = makeWriter()
        do {
            let url = try writer.begin(session: session, title: Self.defaultTitle(startedAt), startedAtLocal: startedAt)
            session.transcriptRef = url.path
            await presenter.updateTranscriptPath(url.path)
        } catch {
            await failStartup(message: "Could not create transcript file: \(error.localizedDescription)",
                              engine: engine, capturer: capturer, writer: nil)
            return
        }
        self.writer = writer

        // Success → Recording (§6.2 Detected -> Recording).
        finalSegmentCount = 0
        inactiveMicTicks = 0
        // Startup recovered — clear the failure cooldown and re-arm the warning.
        lastStartFailureAt = nil
        didWarnStartFailure = false
        state.currentSession = session
        // Seed at recording-ready (NOT `startedAt`): engine/model startup above
        // can take many seconds and must not eat into the inactivity budget.
        state.lastAudioActivityAt = now()
        state.sessionStatus = .recording
        await presenter.showCaptions()
        await presenter.updateStatus(.recording, endReason: nil)
        await presenter.notifyCallStarted(session: session)
        Log.orchestrator.notice("Session \(id, privacy: .public) recording.")
    }

    /// Detected -> Failed (§6.2). Tears down whatever started, returns to Idle,
    /// and surfaces a visible error (§10.2). No transcript content exists yet on
    /// engine/capture failure; on writer failure the provisional file is kept.
    private func failStartup(
        message: String,
        engine: TranscriptionEngine?,
        capturer: AudioCapturing?,
        writer: TranscriptWriting?
    ) async {
        Log.orchestrator.error("Session startup failed: \(message, privacy: .public)")
        if let capturer { await capturer.stop() }
        if let engine { _ = try? await engine.stop() }
        if let writer, let preserved = try? writer.finalize(duration: 0) {
            await presenter.updateTranscriptPath(preserved.path)
        }

        self.engine = nil
        self.capturer = nil
        self.writer = nil

        // Start the retry cooldown and surface the error AT MOST ONCE per
        // continuous mic-active episode — a persistent failure must not pop an
        // alert/notification on every confirm window (the failure is always
        // logged above and reflected in the menu-bar status regardless).
        lastStartFailureAt = now()
        let surface = !didWarnStartFailure
        didWarnStartFailure = true

        await presenter.hideCaptions()
        await failToIdle(message: message, surfaceError: surface)
    }

    // MARK: Transcription loop (§14.3)

    private func handleAudio(_ buffer: AudioBuffer) async {
        guard state.sessionStatus == .recording, let engine = self.engine else { return }

        if buffer.rms >= config.activityThresholdRMS {
            state.lastAudioActivityAt = now()
        } else if await finalizeIfAudioInactive(via: "audio stream") {
            // Primary silence-timeout evaluation rides the audio stream — the
            // signal actually being measured (§7.3) — so it fires within one
            // buffer interval of the deadline instead of waiting for a mic poll.
            return
        }

        let segments: [Segment]
        do {
            segments = try await engine.push(buffer)
        } catch {
            // Engine failure during recording: finalize, preserving captured
            // final segments (§10.2).
            Log.engine.error("engine.push failed: \(error.localizedDescription)")
            await finalizeSession(reason: .error)
            return
        }

        for seg in segments {
            if seg.isFinal {
                let indexed = seg.reindexed(finalSegmentCount)
                do {
                    try writer?.appendFinal(indexed)
                    finalSegmentCount += 1
                    await presenter.commitFinal(indexed)
                } catch {
                    await handlePersistenceFailure(error)
                    return
                }
            } else {
                await presenter.showPartial(seg)
            }
        }
    }

    /// Persistence failure mid-recording: preserve already-written content, emit
    /// a visible error, do not silently lose the session (§10.2, §10.3).
    private func handlePersistenceFailure(_ error: Error) async {
        Log.persistence.error("Persistence failure during recording: \(error.localizedDescription)")
        await capturer?.stop(); capturer = nil
        _ = try? await engine?.stop(); engine = nil
        // finalize() may rename the file; publish the preserved location so the
        // popover's reveal/copy actions don't point at the old provisional path.
        if let preserved = try? writer?.finalize(duration: currentElapsed()) {
            await presenter.updateTranscriptPath(preserved.path)
        }
        writer = nil

        await presenter.hideCaptions()
        await failToIdle(message: "Could not write transcript: \(error.localizedDescription). Partial transcript preserved.")
    }

    // MARK: Session finalization (§5.3, §14.4)

    private func finalizeSession(reason: EndReason) async {
        guard state.sessionStatus == .recording else { return }
        state.sessionStatus = .finalizing
        await presenter.updateStatus(.finalizing, endReason: reason)
        Log.orchestrator.notice("Finalizing session (reason=\(reason.rawValue, privacy: .public)).")

        // Stop capture first so no further buffers arrive.
        await capturer?.stop(); capturer = nil

        // Flush the engine and write its pending final segments.
        var pending: [Segment] = []
        if let engine = self.engine {
            do { pending = try await engine.stop() }
            catch { Log.engine.error("engine.stop failed: \(error.localizedDescription)") }
        }
        self.engine = nil
        for seg in pending where seg.isFinal {
            let indexed = seg.reindexed(finalSegmentCount)
            do {
                try writer?.appendFinal(indexed)
                finalSegmentCount += 1
                await presenter.commitFinal(indexed)
            } catch {
                Log.persistence.error("append during finalize failed: \(error.localizedDescription)")
            }
        }

        // Close the document and update duration (§9.4).
        let duration = currentElapsed()
        var finalURL: URL?
        var finalizeOK = true
        do {
            finalURL = try writer?.finalize(duration: duration)
        } catch {
            finalizeOK = false
            Log.persistence.error("finalize failed: \(error.localizedDescription)")
        }
        self.writer = nil
        await presenter.hideCaptions()

        if !finalizeOK {
            // Finalizing -> Failed (§6.2 / §10.2). Partial content is preserved.
            await failToIdle(message: "Could not finalize the transcript. Partial content preserved.")
            return
        }

        // Finalizing -> Saved (§6.2).
        if var session = state.currentSession {
            session.endedAt = now()
            session.endReason = reason
            session.status = .saved
            if let finalURL { session.transcriptRef = finalURL.path }
            if let finalURL { await presenter.updateTranscriptPath(finalURL.path) }
            state.currentSession = session
        }
        state.sessionStatus = .saved
        await presenter.updateStatus(.saved, endReason: reason)

        // Saved -> Idle (§6.2): return to observing — and SHOW it. Without the
        // .idle update the UI stays frozen on "Saved" and the user can't tell
        // the app is still watching for the next call.
        resetToIdle()
        await presenter.updateStatus(.idle, endReason: reason)
        Log.orchestrator.notice("Session saved → idle.")
    }

    // MARK: Helpers

    /// Evaluates the audio-silence timeout (§7.3) against `lastAudioActivityAt`,
    /// finalizing with `end_reason = inactivity` when exceeded. Returns true if
    /// the session was finalized. Called from both the audio stream (primary)
    /// and the mic poll (fallback) so the timeout policy lives in one place.
    private func finalizeIfAudioInactive(via source: String) async -> Bool {
        guard state.sessionStatus == .recording, let last = state.lastAudioActivityAt else { return false }
        let elapsedMs = now().timeIntervalSince(last) * 1000
        guard elapsedMs >= Double(config.inactivityTimeoutMs) else { return false }
        Log.orchestrator.notice("Audio inactive \(Int(elapsedMs), privacy: .public) ms (\(source, privacy: .public)) → finalize (inactivity).")
        await finalizeSession(reason: .inactivity)
        return true
    }

    /// Returns the orchestrator to observing (… -> Idle, §6.2).
    private func resetToIdle() {
        state.sessionStatus = .idle
        state.currentSession = nil
        inactiveMicTicks = 0
    }

    /// Common Failed -> Idle tail (§6.2, §10.2): mark the session failed,
    /// surface a visible error, then resume observing. Callers hide the caption
    /// surface beforehand. `surfaceError: false` suppresses only the user-facing
    /// error (used by the once-per-episode startup-failure gating); the status
    /// surface still flips to `.failed` and the failure is always logged.
    private func failToIdle(message: String, surfaceError: Bool = true) async {
        if var session = state.currentSession {
            session.status = .failed
            session.endReason = .error
            session.endedAt = now()
            state.currentSession = session
        }
        state.sessionStatus = .failed
        await presenter.updateStatus(.failed, endReason: .error)
        if surfaceError {
            await presenter.presentError(message)
        }
        resetToIdle()
        // Back to observing — reflect it in the UI (the failure detail stays
        // visible in the engine-health line and the notification).
        await presenter.updateStatus(.idle, endReason: .error)
    }

    private func currentElapsed() -> TimeInterval {
        guard let session = state.currentSession else { return 0 }
        return session.elapsed(asOf: now())
    }

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Call \(f.string(from: date))"
    }
}
