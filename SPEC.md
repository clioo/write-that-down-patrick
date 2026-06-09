# Call Transcription Service Specification

Status: Draft v1 (implementation-agnostic)

Purpose: Define a macOS application that automatically detects calls, transcribes their audio in real time and locally, displays live captions, and organizes the resulting transcripts on the filesystem.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and `OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this specification does not prescribe one universal policy. Implementations MUST document the selected behavior.

## 1. Problem Statement

The service is a long-running local application that continuously observes the system audio state, detects when the user enters a call, captures that call's audio, transcribes it in real time, and persists the transcript as a structured document on the filesystem.

The service solves four operational problems:

- It turns call transcription into an automatic flow instead of a manual per-meeting action.
- It processes audio locally, without sending data to the cloud.
- It keeps transcripts as readable, version-controllable files, organized predictably.
- It provides visible feedback to the user (live captions, status, notifications) without requiring the user to supervise the process.

Important boundary:

- The service is a capturer, transcriber, and organizer.
- The service does NOT perform questions and answers (Q&A) over transcripts.
- AI analysis is performed by external tools that the user points at the transcript folder.
- A successful session ends with a persisted transcript document, not with an analysis.

## 2. Goals and Non-Goals

### 2.1 Goals

- Observe the system audio state on a fixed cadence and detect the start and end of calls.
- Simultaneously capture system audio and microphone audio.
- Transcribe captured audio in real time using a swappable transcription engine.
- Display live captions during the call.
- Expose operational status to the user (menu bar and notifications).
- Persist transcripts in Markdown organized by date.
- Stop recording automatically after sustained audio inactivity.
- Recover from transient failures without losing already-captured transcript content.

### 2.2 Non-Goals

- Q&A, chat, or integrated AI analysis inside the application.
- Authentication against AI providers or use of subscriptions.
- Search or correlation across multiple transcripts.
- Speaker identification (diarization) in v1.
- Support for operating systems other than macOS.
- Prescribing a specific transcription engine.

## 3. System Overview

### 3.1 Main Components

1. `Call Detector`

  - Observes the operating system's microphone-in-use signal.
  - Decides when a session must start or end.
  - Emits transition events to the orchestrator.

2. `Audio Capturer`

  - Opens and reads system audio and microphone audio.
  - Delivers normalized audio buffers to the transcription engine.
  - Measures audio level to support inactivity detection.

3. `Transcription Engine`

  - Receives audio buffers and produces text segments.
  - Is swappable through a common contract (see §8).

4. `Session Orchestrator`

  - Is the single authority over session state.
  - Decides start, finalize, inactivity stop, and recovery.
  - Coordinates capture, transcription, presentation, and persistence.

5. `Caption Surface`

  - Presents text segments live in a floating window.

6. `Status Surface` (menu bar)

  - Presents session status and triggers notifications.
  - Allows manual control (stop / pause).

7. `Transcript Writer`

  - Writes segments to a Markdown document.
  - Applies the folder structure and naming convention.

8. `Configuration Layer`

  - Exposes typed configuration values with defaults.
  - Validates configuration before operation starts.

### 3.2 Abstraction Levels

The service is easiest to port and maintain when kept in these layers:

1. `Capture Layer`

  - Access to the operating system's audio APIs.

2. `Detection Layer`

  - Microphone-in-use signal and activity thresholds.

3. `Transcription Layer`

  - The engine contract and its swappable implementations.

4. `Coordination Layer`

  - The orchestrator: session state machine.

5. `Presentation Layer`

  - Live captions, menu bar, and notifications.

6. `Persistence Layer`

  - Document writing, folder structure, and naming.

### 3.3 External Dependencies

- Operating system audio capture API.
- Operating system signal indicating the microphone is in use.
- A transcription engine that satisfies the contract in §8.
- Local filesystem for transcripts.
- Operating system notification system.
- Operating system permissions for microphone and audio capture.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Recording Session

Record of one detected call from start to finish.

Fields:

- `id` (string)
  * Stable session identifier.
- `started_at` (timestamp)
- `ended_at` (timestamp or null)
- `status` (enum)
  * Session orchestration state (see §6.1).
- `audio_sources` (list)
  * Sources active during the session.
- `transcript_ref` (reference or null)
  * Points to the associated transcript.
- `end_reason` (enum or null)
  * `inactivity` | `manual` | `error` | `system_stop`

#### 4.1.2 Transcript

Document produced by a session.

Fields:

- `session_id` (string)
- `title` (string)
- `date` (local date)
- `started_at_local` (local start time)
- `duration` (duration or null until finalized)
- `segments` (list of Segment)
- `file_path` (absolute path or null until first write)

#### 4.1.3 Transcript Segment

Atomic unit of transcribed output.

Fields:

- `index` (integer, monotonically increasing from 0)
- `timestamp` (offset relative to session start)
- `text` (string)
- `is_final` (boolean)
  * `false` for partial hypotheses shown in captions.
  * `true` for confirmed text written to the document.

#### 4.1.4 Audio Source

Origin of captured audio.

Fields:

- `kind` (enum)
  * `system` | `microphone`
- `active` (boolean)

#### 4.1.5 Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `session_status` (enum, see §6.1)
- `current_session` (Recording Session or null)
- `last_audio_activity_at` (timestamp or null)
- `engine_id` (identifier of the active engine)
- `inactivity_timeout_ms` (current effective value)
- `poll_interval_ms` (current effective value)

### 4.2 Identifiers and Normalization Rules

- `Session ID`
  * Derived from the start date and time; stable for the session's lifetime.
- `Date folder name`
  * Format `YYYY-MM-DD` in local time.
- `File name`
  * See §9.3. Only characters in `[A-Za-z0-9._-]` are allowed; any other
    character MUST be replaced with `_`.
- `Segment offset`
  * Time relative to session start, not wall-clock time.

## 5. Call Detection

### 5.1 Detection Signal

- Detection MUST be based on the operating system signal indicating the microphone
  is in use by any process.
- Detection MUST NOT depend on identifying a specific application (detection is
  agnostic to the video-call app).
- The signal MUST be polled on a fixed cadence defined by `poll_interval_ms`.

### 5.2 Session Start

- When the microphone-in-use signal becomes active and no session is in progress,
  the orchestrator MUST start a new session.
- On start, the service MUST open audio capture, show the caption surface, update
  the status surface, and trigger a notification.

### 5.3 Session End

- A session MUST end when any of the following occurs:
  * The microphone-in-use signal becomes inactive in a sustained manner.
  * The audio level remains below threshold for `inactivity_timeout_ms` (see §7.3).
  * The user requests a manual stop.
- On end, the service MUST close capture, write pending segments, finalize the
  document, hide captions, and update status.

## 6. Session State Machine

The orchestrator is the only component that mutates session state.

### 6.1 Session States

1. `Idle`

  - No active session. The service observes the detection signal.

2. `Detected`

  - Microphone activity observed; capture startup is in progress.

3. `Recording`

  - Capture and transcription are active; segments are emitted.

4. `Finalizing`

  - Capture stopped; final segments are written and the document is closed.

5. `Saved`

  - The document was persisted; the session is terminal.

6. `Failed`

  - A failure prevented completing the session. The partial document SHOULD be kept.

### 6.2 Transitions

- `Idle -> Detected`: the microphone-in-use signal becomes active.
- `Detected -> Recording`: capture and engine initialized successfully.
- `Detected -> Failed`: capture or engine could not be initialized.
- `Recording -> Finalizing`: end by inactivity, manual stop, or system signal.
- `Finalizing -> Saved`: the document was closed successfully.
- `Finalizing -> Failed`: the final write failed (see §10.2).
- `Saved -> Idle`: the service returns to observing the detection signal.
- `Failed -> Idle`: after logging the error, the service returns to observing.

### 6.3 Idempotency Rules

- The orchestrator MUST guarantee at most one active session at a time.
- A transition to `Detected` MUST NOT occur while a session is in `Recording` or
  `Finalizing`.

## 7. Audio Capture

### 7.1 Sources

- The service MUST capture system audio (the output of call apps).
- The service MUST capture microphone audio.
- System audio capture SHOULD be performed via a native operating system API that
  does not require installing third-party audio drivers.

### 7.2 Buffer Delivery

- The capturer MUST deliver audio buffers to the transcription engine in an agreed
  format (sample rate and sample format implementation-defined but documented).
- The audio segment size delivered to the engine balances caption latency against
  accuracy and is implementation-defined.

### 7.3 Inactivity Detection

- The capturer MUST measure the incoming audio level.
- When the level remains below a threshold for `inactivity_timeout_ms`, the
  orchestrator MUST end the session with `end_reason = inactivity`.
- The level threshold and window are implementation-defined but MUST be documented.

## 8. Transcription Engine Contract

The transcription engine is defined through a common contract. The rest of the
application interacts with the contract and MUST NOT depend on the engine's concrete
implementation.

### 8.1 Contract

Operations:

- `start(config)`
  * Initializes the engine; MAY incur an initial load cost.
- `push(audio_buffer) -> [Segment]`
  * Receives audio and returns zero or more segments (partial or final).
- `stop() -> [Segment]`
  * Flushes and returns any pending final segments.

### 8.2 Implementations

- The service MUST provide a default implementation that is portable and open
  source, able to run on the widest possible range of macOS versions, and
  multilingual.
- The service MAY provide an optional implementation based on a native operating
  system engine for greater speed on compatible versions.
- Engine selection MUST be done via configuration (`engine`, see §11).
- Adding a new engine MUST NOT require changes outside its own implementation.

### 8.3 Segment Semantics

- Partial segments (`is_final = false`) SHOULD be used for live captions and MUST
  NOT be written to the document.
- Final segments (`is_final = true`) MUST be written to the document.

## 9. Transcript Output and Persistence

### 9.1 Document Format

The document MUST be Markdown with the following structure:

```
# <title>
**Date:** YYYY-MM-DD HH:MM
**Duration:** <n> min

## Transcript
[HH:MM:SS] <segment text>
[HH:MM:SS] <segment text>
...
```

- Each final segment MUST be written on its own line with its timestamp.
- The duration header MAY be written provisionally and updated on finalization.

### 9.2 Folder Structure

```
<output_dir>/
  └── YYYY-MM-DD/
        ├── HH-MM_<duration>.md
        └── HH-MM_<duration>.md
```

- There MUST be one folder per date (local time).
- There MUST be one file per session.
- The date folder MUST be created if it does not exist.

### 9.3 Naming Convention

- The automatic file name MUST be composed of the start time and duration:
  `HH-MM_<duration>.md`.
- Renaming by content is NOT the application's responsibility; it is delegated to
  external tools (see §13).
- The name MUST be sanitized per §4.2.

### 9.4 Incremental Writing

- The writer SHOULD persist final segments incrementally during the session, not
  only at the end, to minimize loss on failure.
- On finalization, the writer MUST update the duration metadata.

## 10. Failure Model and Recovery

### 10.1 Failure Classes

1. `Permission Failures`
  - Microphone or system audio capture permission denied.
2. `Capture Failures`
  - An audio source could not be opened or read.
3. `Engine Failures`
  - The engine failed to initialize or failed during transcription.
4. `Persistence Failures`
  - The folder could not be created or the document could not be written.

### 10.2 Recovery Behavior

- Permission failures: the service MUST inform the user visibly and MUST NOT start
  sessions until permissions are granted.
- Capture failures in `Detected`: the session MUST transition to `Failed`; the
  service MUST return to `Idle` and keep observing.
- Engine failures during `Recording`: the service SHOULD finalize the session,
  preserving the final segments already captured.
- Persistence failures: the service MUST attempt to preserve already-transcribed
  content and emit a visible error; it MUST NOT silently lose the session.

### 10.3 No-Loss Invariant

- Once a segment is final, the service SHOULD guarantee it is persisted, even if the
  session ends abnormally.

## 11. Configuration Specification

Typed values with defaults. Implementations MUST validate configuration before
operation starts.

- `output_dir` (path)
  * Default: `~/Transcripts`
  * `~` MUST be expanded.
- `language` (string)
  * Default: the user's primary language; MAY be `auto`.
- `engine` (enum)
  * `default` | `native`
  * Default: `default`.
- `inactivity_timeout_ms` (integer)
  * Default: `900000` (15 minutes).
- `poll_interval_ms` (integer)
  * Default: `2000`.

Implementations MUST document any additional implementation-defined values (for
example, audio level threshold or buffer size).

## 12. Privacy and Safety

- Audio MUST be processed locally; the service MUST NOT send audio or transcripts to
  remote services in v1.
- The service MUST request the necessary operating system permissions on first run
  and operate only after they are granted.
- Transcripts are stored as plain text in `output_dir`; the implementation SHOULD
  document this location so the user can control its confidentiality.

## 13. External Reading and Q&A (Boundary)

- The service does not provide Q&A or AI chat.
- Transcripts reside in `output_dir` in Markdown.
- The user MAY point an external AI tool with filesystem access at `output_dir` for
  analysis or content-based renaming.
- Any such integration is outside the v1 conformance scope.

## 14. Reference Algorithms (Implementation-Agnostic)

### 14.1 Detection Loop

```
on_tick(state):
  mic_active = os_microphone_in_use()

  if state.session_status == Idle and mic_active:
    state = begin_session(state)
    return state

  if state.session_status == Recording:
    if not mic_active or inactivity_elapsed(state):
      state = finalize_session(state, reason = inactivity_or_signal)
      return state

  schedule_tick(state.poll_interval_ms)
  return state
```

### 14.2 Session Start

```
function begin_session(state):
  session = new_session(started_at = now_local())
  if not open_audio_capture():
    return fail_session(state, session, "capture_error")
  if not engine.start(config):
    close_audio_capture()
    return fail_session(state, session, "engine_error")

  show_caption_surface()
  set_status(Recording)
  notify_user("recording")

  state.current_session = session
  state.session_status = Recording
  state.last_audio_activity_at = now()
  return state
```

### 14.3 Transcription Loop

```
on_audio_buffer(buffer, state):
  if level(buffer) >= activity_threshold:
    state.last_audio_activity_at = now()

  segments = engine.push(buffer)
  for seg in segments:
    if seg.is_final:
      transcript_writer.append_final(seg)   # incremental persistence
      caption_surface.commit(seg)
    else:
      caption_surface.show_partial(seg)
  return state
```

### 14.4 Session Finalization

```
function finalize_session(state, reason):
  set_status(Finalizing)
  final_segments = engine.stop()
  for seg in final_segments:
    transcript_writer.append_final(seg)

  if not transcript_writer.finalize(duration = elapsed(state.current_session)):
    hide_caption_surface()
    state.session_status = Failed
    set_status(Idle)
    return state

  hide_caption_surface()
  state.current_session.ended_at = now_local()
  state.current_session.end_reason = reason
  state.session_status = Saved
  set_status(Idle)
  state.current_session = null
  return state
```

## 15. Test and Validation Matrix

A conforming implementation SHOULD include tests covering the behaviors defined in
this specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that are shipped.
- `Real Integration Profile`: environment-dependent checks RECOMMENDED before
  production use.

### 15.1 Detection and State

- `Idle -> Detected` occurs when the microphone signal becomes active.
- A second session is not started while one is in `Recording`.
- Sustained inactivity ends the session with `end_reason = inactivity`.
- Manual stop ends the session with `end_reason = manual`.

### 15.2 Audio Capture

- Both sources (system and microphone) are captured.
- Level measurement updates the last-activity timestamp.
- Absence of audio below threshold triggers inactivity.

### 15.3 Transcription Engine

- The default engine initializes, transcribes, and stops per the contract.
- Changing `engine` selects the corresponding implementation with no other changes.
- Partial segments are not written to the document.
- Final segments are written to the document.

### 15.4 Persistence

- The date folder is created if it does not exist.
- The file name uses start time and duration, and is sanitized.
- Final segments are persisted incrementally.
- Duration metadata is updated on finalization.

### 15.5 Presentation

- The caption surface shows on start and hides on finalization.
- The status surface reflects the current session state.
- A notification is triggered when a call is detected and started.

### 15.6 Failures

- Denied permission prevents starting sessions and informs the user.
- Capture failure transitions the session to `Failed` and the service returns to `Idle`.
- Engine failure during recording preserves the final segments already captured.
- Persistence failure does not silently lose transcribed content.

### 15.7 Real Integration Profile (RECOMMENDED)

- Smoke test with a real call, verifying capture, captions, and file output.
- Verification of operating system permissions in the target environment.
- A skipped integration test SHOULD be reported as skipped, not as passed.

## 16. Implementation Checklist (Definition of Done)

### 16.1 REQUIRED for Conformance

- Call detector based on the operating system's microphone-in-use signal.
- Orchestrator with a single authoritative state and the state machine of §6.
- Simultaneous capture of system audio and microphone.
- Inactivity detection with `inactivity_timeout_ms`.
- Swappable transcription engine with the contract of §8.
- Default transcription engine that is portable and open source.
- Live captions (partial and final segments).
- Menu bar status surface with manual control.
- Notification when a call is detected and started.
- Markdown writing with the structure of §9.1.
- Date-based folder structure and start-time+duration naming (§9.2, §9.3).
- Incremental persistence of final segments.
- Failure handling per §10 without silent loss.
- Typed configuration layer with defaults and pre-operation validation.

### 16.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- Native operating system transcription engine as an option (`engine = native`).
- Live reading UI beyond the floating captions (see Appendix A).
- External-tool-assisted file renaming (outside the app).
- TODO: speaker identification (diarization).
- TODO: export to additional formats.

### 16.3 Operational Validation Before Production (RECOMMENDED)

- Run the Real Integration Profile of §15.7 with a real call.
- Verify permission behavior in the target environment.

## Appendix A. Live Reading UI (OPTIONAL)

This appendix describes an OPTIONAL extension providing a richer reading view than
the floating caption surface.

- The reading UI is an extension and is NOT REQUIRED for conformance.
- It MUST be driven solely from the orchestrator's segment stream.
- It MUST NOT become a requirement for capture or persistence correctness.
- It MAY present the current session's history with auto-scroll.

## Appendix B. External Q&A Integration (OPTIONAL)

This appendix describes the intended pattern for AI analysis, which lives outside the
application.

- The application exposes transcripts as Markdown files in `output_dir`.
- An external AI tool with filesystem access MAY be pointed at `output_dir` to answer
  questions or rename by content.
- This integration is NOT part of the v1 conformance scope and MUST NOT introduce
  network dependencies inside the application.