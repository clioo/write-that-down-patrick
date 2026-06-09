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
    private var permissionsOK = false
    private var didWarnPermission = false

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
        Log.orchestrator.info("Orchestrator observing (permissionsOK=\(self.permissionsOK, privacy: .public)).")
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
        Log.orchestrator.info("Orchestrator event loop ended.")
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
            guard active else { return }
            // Refresh permission state — the user may have granted access since
            // launch. Block session starts until granted (§10.2).
            let snapshot = await permissions.currentStatus()
            permissionsOK = snapshot.canStartSession
            if permissionsOK {
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
                let inactiveMs = inactiveMicTicks * config.pollIntervalMs
                if inactiveMs >= config.micInactivityGraceMs {
                    Log.orchestrator.info("Mic inactive \(inactiveMs, privacy: .public) ms → finalize (system_stop).")
                    await finalizeSession(reason: .systemStop)
                    return
                }
            }
            // Audio-level inactivity timeout (§7.3).
            if let last = state.lastAudioActivityAt {
                let elapsedMs = now().timeIntervalSince(last) * 1000
                if elapsedMs >= Double(config.inactivityTimeoutMs) {
                    Log.orchestrator.info("Audio inactive \(Int(elapsedMs), privacy: .public) ms → finalize (inactivity).")
                    await finalizeSession(reason: .inactivity)
                }
            }

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
        Log.orchestrator.info("Session \(id, privacy: .public) detected; starting capture/engine.")

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
        } catch {
            await failStartup(message: "Could not create transcript file: \(error.localizedDescription)",
                              engine: engine, capturer: capturer, writer: nil)
            return
        }
        self.writer = writer

        // Success → Recording (§6.2 Detected -> Recording).
        finalSegmentCount = 0
        inactiveMicTicks = 0
        state.currentSession = session
        state.lastAudioActivityAt = startedAt
        state.sessionStatus = .recording
        await presenter.showCaptions()
        await presenter.updateStatus(.recording, endReason: nil)
        await presenter.notifyCallStarted(session: session)
        Log.orchestrator.info("Session \(id, privacy: .public) recording.")
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
        if let writer { _ = try? writer.finalize(duration: 0) }

        if var session = state.currentSession {
            session.status = .failed
            session.endReason = .error
            session.endedAt = now()
            state.currentSession = session
        }
        self.engine = nil
        self.capturer = nil
        self.writer = nil
        state.sessionStatus = .failed
        await presenter.hideCaptions()
        await presenter.updateStatus(.failed, endReason: .error)
        await presenter.presentError(message)

        // Failed -> Idle (§6.2): resume observing.
        state.sessionStatus = .idle
        state.currentSession = nil
        inactiveMicTicks = 0
    }

    // MARK: Transcription loop (§14.3)

    private func handleAudio(_ buffer: AudioBuffer) async {
        guard state.sessionStatus == .recording, let engine = self.engine else { return }

        if buffer.rms >= config.activityThresholdRMS {
            state.lastAudioActivityAt = now()
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
        _ = try? writer?.finalize(duration: currentElapsed()); writer = nil

        if var session = state.currentSession {
            session.status = .failed
            session.endReason = .error
            session.endedAt = now()
            state.currentSession = session
        }
        state.sessionStatus = .failed
        await presenter.hideCaptions()
        await presenter.updateStatus(.failed, endReason: .error)
        await presenter.presentError("Could not write transcript: \(error.localizedDescription). Partial transcript preserved.")
        state.sessionStatus = .idle
        state.currentSession = nil
        inactiveMicTicks = 0
    }

    // MARK: Session finalization (§5.3, §14.4)

    private func finalizeSession(reason: EndReason) async {
        guard state.sessionStatus == .recording else { return }
        state.sessionStatus = .finalizing
        await presenter.updateStatus(.finalizing, endReason: reason)
        Log.orchestrator.info("Finalizing session (reason=\(reason.rawValue, privacy: .public)).")

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
            if var session = state.currentSession {
                session.status = .failed
                session.endReason = .error
                session.endedAt = now()
                state.currentSession = session
            }
            state.sessionStatus = .failed
            await presenter.updateStatus(.failed, endReason: .error)
            await presenter.presentError("Could not finalize the transcript. Partial content preserved.")
            state.sessionStatus = .idle
            state.currentSession = nil
            inactiveMicTicks = 0
            return
        }

        // Finalizing -> Saved (§6.2).
        if var session = state.currentSession {
            session.endedAt = now()
            session.endReason = reason
            session.status = .saved
            if let finalURL { session.transcriptRef = finalURL.path }
            state.currentSession = session
        }
        state.sessionStatus = .saved
        await presenter.updateStatus(.saved, endReason: reason)

        // Saved -> Idle (§6.2): return to observing.
        state.sessionStatus = .idle
        state.currentSession = nil
        inactiveMicTicks = 0
        Log.orchestrator.info("Session saved → idle.")
    }

    // MARK: Helpers

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
