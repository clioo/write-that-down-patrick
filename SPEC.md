# Write That Down Specification

Status: Draft v4 (source-aware meetings, Pi providers, and local global dictation)

Purpose: Define a macOS application that detects likely meetings, transcribes
their audio in real time and locally, displays a live conversation workspace,
supports questions over the conversation through a user-selected Pi provider, produces an
end-of-conversation summary, and organizes transcripts on the filesystem.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and `OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this specification does not prescribe one universal policy. Implementations MUST document the selected behavior.

## 1. Problem Statement

The service is a long-running local application that continuously observes the system audio state, detects when the user enters a call, captures that call's audio, transcribes it in real time, and persists the transcript as a structured document on the filesystem.

The service solves five operational problems:

- It starts obvious meetings automatically while asking before recording
  ambiguous microphone activity.
- It processes audio locally, without sending data to the cloud.
- It keeps transcripts as readable, version-controllable files, organized predictably.
- It provides visible feedback to the user (live captions, status, notifications) without requiring the user to supervise the process.
- It lets the user ask about the current conversation and receive a summary
  without copying a transcript path into another application.

Important boundary:

- Audio capture and speech transcription remain local.
- Only transcript text and assistant conversation text cross the device boundary,
  and only through the provider and model explicitly selected by the user.
- The Pi runtime invoked by the application is a minimal model-protocol adapter. It has no coding,
  shell, or filesystem tools and never receives a transcript path.
- Transcript persistence is independent from assistant availability. An
  assistant or summary failure MUST NOT turn a successfully persisted recording
  into a failed recording session.

## 2. Goals and Non-Goals

### 2.1 Goals

- Observe the system audio state on a fixed cadence and detect the start and end of calls.
- Distinguish recognized meeting sources from ambiguous microphone activity.
- Simultaneously capture system audio and microphone audio.
- Transcribe captured audio in real time using a swappable transcription engine.
- Optionally reuse the selected local transcription engine for global, microphone-only
  dictation into the focused text field through a configurable global shortcut.
- Display a live transcript and conversation workspace during the call.
- Present the interface in English or Spanish according to the primary macOS
  language, with English as the fallback for unsupported languages.
- Support in-session Q&A and generate a summary after finalization using models
  exposed by the installed Pi provider catalog.
- Expose operational status to the user (menu bar and notifications).
- Persist transcripts in Markdown organized by date.
- Stop recording automatically after sustained audio inactivity.
- Recover from transient failures without losing already-captured transcript content.

### 2.2 Non-Goals

- Implementing provider protocols or authentication flows not exposed by Pi.
- Giving the assistant shell, filesystem, code-editing, or autonomous agent tools.
- Uploading captured audio to any AI provider.
- Search or correlation across multiple transcripts.
- Speaker identification (diarization) in v2.
- Support for operating systems other than macOS.
- Prescribing a specific transcription engine.

## 3. System Overview

### 3.1 Main Components

1. `Call Detector`

  - Observes the operating system's microphone-in-use signal.
  - Attributes activity to an application when the operating system exposes that
    information and classifies the source as automatic, confirmation-required,
    or excluded.
  - Emits source-aware transition events to the orchestrator.

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
  - Provides an explicit action that opens the full conversation workspace in
    every session state, including Idle.

7. `Transcript Writer`

  - Writes segments to a Markdown document.
  - Applies the folder structure and naming convention.

8. `Configuration Layer`

  - Exposes typed configuration values with defaults.
  - Validates configuration before operation starts.

9. `Conversation Assistant`

  - Accepts the current transcript text and in-session questions.
  - Uses a minimal, request-scoped Pi runtime with no tools.
  - Routes every model request through the provider and model selected in the UI.
  - Generates the final summary after transcript finalization.

10. `Credential Store`

  - Stores and retrieves Pi-compatible API-key and OAuth credentials from the
    macOS Keychain.
  - Never exposes credentials in transcript files, application configuration,
    process arguments, or logs.

11. `Conversation Library`

  - Indexes finalized Markdown transcripts beneath `output_dir`.
  - Presents the current session and stored conversations in a selectable list.
  - Restores each selected transcript and its saved summary, when present, as
    assistant context without requiring the user to copy a filesystem path.

12. `Global Dictation Controller`

  - Registers the user-configured shortcut (default `Command-E`) only after global
    dictation is enabled in Settings.
  - Starts microphone capture when the shortcut is pressed, buffers audio while a
    cold local model loads, and transcribes/inserts when the shortcut is released.
  - Captures microphone audio only and runs the engine selected for transcription.
  - Retains the original focused insertion target and inserts through macOS
    Accessibility, with compatible value/range and Unicode-event fallbacks.
  - MUST NOT create a recording session, transcript file, or assistant request.
  - MUST refuse to start while a meeting session is active.

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

7. `Assistant Layer`

  - Request-scoped transcript context, chat history, summary generation, and the
    selected Pi provider boundary.

### 3.3 External Dependencies

- Operating system audio capture API.
- Operating system signal indicating the microphone is in use.
- A transcription engine that satisfies the contract in §8.
- Local filesystem for transcripts.
- Operating system notification system.
- Operating system permissions for microphone and audio capture.
- macOS Accessibility permission when optional global dictation is enabled.
- macOS Keychain for provider API keys and OAuth tokens.
- Selected provider network access for chat and summary requests.
- A minimal Pi model runtime supporting the protocol used by the selected
  provider model.

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

#### 4.1.6 Detected Conversation Source

Description of the microphone-owning process used only to decide whether a
recording may start.

Fields:

- `bundle_id` (string or null)
- `display_name` (string or null)
- `visible_window_title` (string or null)
- `classification` (enum)
  * `automatic_meeting` | `confirmation_required` | `excluded`
- `meeting_kind` (enum or null)
  * `zoom` | `teams` | `google_meet`

#### 4.1.7 Assistant Conversation

Ephemeral AI state scoped to one recording session.

Fields:

- `session_id` (string)
- `provider` (string)
  * MUST identify the provider explicitly selected from the installed Pi catalog.
- `model_id` (string)
  * MUST identify a model exposed by that provider.
- `messages` (list)
  * User questions and assistant answers for this session only.
- `summary` (string or null)
- `status` (enum)
  * `unconfigured` | `ready` | `responding` | `summarizing` | `failed`

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
- `Assistant conversation lifetime`
  * Scoped to one recording session. Context from another transcript MUST NOT be
    included implicitly.

## 5. Call Detection

### 5.1 Detection Signal

- Detection MUST be based on the operating system signal indicating the microphone
  is in use by any process.
- The signal MUST be polled on a fixed cadence defined by `poll_interval_ms`.
- When process attribution is available, the detector MUST attach the owning
  application's bundle identifier and display name.
- Browser-hosted meetings SHOULD additionally use visible-window metadata to
  distinguish a Google Meet conversation from unrelated browser microphone use.
- Source inspection MUST NOT read page content, messages, or captured audio.

### 5.2 Source Classification

- Sustained microphone activity from Zoom or Microsoft Teams MUST be classified
  as `automatic_meeting`.
- Sustained microphone activity from a browser or PWA MUST be classified as
  `automatic_meeting` only when a visible Google Meet window can be identified.
- WhatsApp MUST be classified as `confirmation_required`. Recording a WhatsApp
  voice note MUST NOT start a session automatically.
- All other non-excluded applications and activity without reliable process
  attribution MUST be classified as `confirmation_required`.
- Configured exclusions, operating-system speech helpers, the capture daemon, and
  this application itself MUST be classified as `excluded` and MUST NOT prompt or
  start a recording.
- If one active source is an `automatic_meeting`, the automatic classification
  takes precedence over concurrent ambiguous sources.

### 5.3 Session Start

- A source MUST remain active for the implementation's documented confirmation
  window before it can start or prompt for a session. Brief microphone blips MUST
  be discarded.
- When an `automatic_meeting` source confirms and no session is in progress, the
  orchestrator MUST start a new session automatically.
- When a `confirmation_required` source confirms, the service MUST show a compact
  prompt identifying the likely source and asking whether to record.
- Capture, transcription, and transcript creation MUST NOT begin until the user
  accepts that prompt.
- Declining or dismissing the prompt MUST suppress further prompts for the same
  continuous microphone-use episode. Suppression MUST reset after the microphone
  is released.
- On start, the service MUST open audio capture, show the caption surface, update
  the status surface, and trigger a notification.

### 5.4 Session End

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
  - An optional pending-confirmation substate records that sustained ambiguous
    microphone activity was detected and the service is asking the user whether
    to record. No Recording Session exists and capture has not started.

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

- `Idle -> Detected`: a confirmed `automatic_meeting` source becomes active.
- `Idle (observing) -> Idle (confirmation pending)`: a confirmed
  `confirmation_required` source becomes active.
- `Idle (confirmation pending) -> Detected`: the user accepts recording while
  the source remains active.
- `Idle (confirmation pending) -> Idle (observing or suppressed)`: the user
  declines/dismisses, or the microphone is released before acceptance.
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
- A declined source episode MUST NOT produce repeated confirmation prompts until
  microphone release.

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
  external tools (see Appendix B).
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
  * `default` | `sherpa` | `native`
  * Default: `default`.
- `speech_model` (string)
  * Catalog model used when `engine = sherpa`.
- `inactivity_timeout_ms` (integer)
  * Default: `900000` (15 minutes).
- `poll_interval_ms` (integer)
  * Default: `2000`.

Implementations MUST document any additional implementation-defined values (for
example, audio level threshold or buffer size).

The selected provider and model MAY be stored as application preferences.
Provider credentials MUST NOT be represented by this configuration layer or
accepted from its JSON file; they belong exclusively in the credential store.

## 12. Privacy and Safety

- Audio MUST be processed locally and MUST NOT be sent to the conversation
  assistant or any other remote service.
- The service MAY send transcript text, the user's questions, and bounded
  in-session assistant context to the selected provider only as specified in §13.
- When the configured assistant generates the end-of-conversation summary, the
  service MUST send the finalized transcript text, not captured audio.
- The UI MUST make the local-audio/remote-text boundary clear before the first
  assistant request is made.
- The service MUST request the necessary operating system permissions on first run
  and operate only after they are granted.
- Transcripts are stored as plain text in `output_dir`; the implementation SHOULD
  document this location so the user can control its confidentiality.
- Provider-side handling and retention MAY vary by provider and model; the model
  selection UI SHOULD expose or link to the applicable policy when available.
- Global dictation audio MUST remain in memory, MUST use microphone input only,
  and MUST NOT be persisted or sent to an assistant provider.
- Global dictation MUST capture from shortcut press through shortcut release;
  local model startup MUST NOT discard speech recorded during that interval.
- Accessibility access MUST be used only to identify the focused writable control
  and insert the locally transcribed result requested by the user.

## 13. Integrated Conversation Assistant

### 13.1 Provider and Runtime Boundary

- Every assistant request MUST use the exact provider identifier and model
  selected by the user.
- Providers, models, and supported authentication methods MUST be sourced from
  the installed Pi runtime. The implementation MUST NOT silently route through
  a different provider, model, or account.
- The application MUST use Pi only as a minimal, request-scoped model runtime.
- The Pi runtime MUST expose no shell, filesystem, code-editing, web, or other
  agent tools.
- The application MUST pass transcript text directly to the runtime. It MUST NOT
  ask the runtime to discover or read the Markdown path.

### 13.2 Credentials

- API keys, OAuth access tokens, and OAuth refresh tokens MUST be stored in the
  macOS Keychain.
- Credentials MUST NOT be written to `config.json`, transcripts, logs,
  analytics, or process arguments. They MAY be materialized in an isolated,
  permission-restricted Pi credential file and MUST be deleted after the
  catalog, authentication, or one-shot request operation finishes.
- The settings UI MUST expose every interactive authentication method declared
  by the installed Pi runtime, including multi-step prompts, OAuth browser
  flows, and device-code flows.
- A completed browser OAuth callback MUST dismiss any optional manual-code
  fallback without requiring the user to paste the redirect URL.
- Device codes MUST be selectable text and MUST provide an explicit copy action.
- If credentials are missing, recording and local transcription MUST remain
  available; the assistant UI MUST explain how to connect a provider.

### 13.3 Live Conversation Q&A

- The conversation workspace MUST allow the user to submit questions while a
  recording is active.
- The workspace MUST allow the user to select a finalized conversation from the
  conversation library and submit new questions about that selected transcript.
- Each request MUST be grounded in the latest available final transcript text
  for the selected current or stored conversation.
  It MAY additionally include the current partial hypothesis, clearly identified
  as provisional.
- Assistant chat history MUST be scoped to the selected conversation and bounded
  to prevent unbounded request growth.
- Each request runs Pi in one-shot mode. The workspace MUST show request progress
  and present the complete response when that process finishes.
- An assistant request failure MUST be shown without stopping recording,
  transcription, or incremental transcript persistence.

### 13.4 End-of-Conversation Summary

- After the transcript is finalized, a configured assistant MUST automatically
  request a summary from the selected provider and model.
- The summary SHOULD prioritize decisions, action items, owners, dates, unresolved
  questions, and the most important context actually present in the transcript.
- The generated summary MUST be presented in the conversation workspace's
  Summary view.
- Summary generation MUST occur after transcript finalization so it receives the
  complete set of final segments.
- Summary failure MUST NOT alter the recording's `Saved` state and MUST remain
  visible in the Summary view.

## 14. Reference Algorithms

### 14.1 Detection Loop

```
on_tick(state):
  sample = inspect_microphone_activity()

  if state.session_status == Idle and sample.sustained and not detection.pending_prompt:
    decision = classify_source(sample)
    if decision == automatic_meeting:
      return begin_session(state)
    if decision == confirmation_required and not detection.suppressed_episode:
      show_recording_prompt(sample.source)
      detection.pending_prompt = sample.source
      return state

  if state.session_status == Idle and detection.pending_prompt:
    if user_accepted() and sample.active:
      return begin_session(state)
    if user_declined() or not sample.active:
      detection.pending_prompt = null
      detection.suppressed_episode = sample.active
      return state

  if state.session_status == Recording:
    if not sample.active or inactivity_elapsed(state):
      state = finalize_session(state, reason = inactivity_or_signal)
      return state

  if not sample.active:
    detection.suppressed_episode = false

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
  request_summary_async(final_transcript_text)  # selected provider; cannot change Saved
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

- A confirmed Zoom or Teams source takes `Idle -> Detected` automatically.
- A browser source takes `Idle -> Detected` automatically only when visible
  Google Meet metadata is present.
- WhatsApp, other browser use, unknown applications, and unattributed activity
  keep the session `Idle` with a pending confirmation and do not open capture
  before acceptance.
- Declining a prompt suppresses another prompt until microphone release.
- Excluded sources neither start nor prompt.
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
- Ambiguous activity presents a source-labeled accept/decline prompt without
  creating a transcript.
- The main workspace presents live transcript and chat concurrently, then exposes
  the generated summary.
- English and Spanish primary-language identifiers select their corresponding UI;
  an unsupported or missing primary language selects English.

### 15.6 Failures

- Denied permission prevents starting sessions and informs the user.
- Capture failure transitions the session to `Failed` and the service returns to `Idle`.
- Engine failure during recording preserves the final segments already captured.
- Persistence failure does not silently lose transcribed content.

### 15.7 Real Integration Profile (RECOMMENDED)

- Smoke test with a real call, verifying capture, captions, and file output.
- Verification of operating system permissions in the target environment.
- A skipped integration test SHOULD be reported as skipped, not as passed.

### 15.8 Conversation Assistant

- Every model request resolves to the provider and model selected from Pi's
  catalog; unknown values are rejected rather than used as fallbacks.
- The Pi runtime is launched without tools and receives transcript text, not a
  filesystem path.
- API-key and OAuth credentials round-trip through Keychain storage and are
  absent from logs, application configuration, transcript files, and process
  arguments; any temporary Pi credential file is request-scoped.
- A live question includes the latest available transcript text and session-only
  chat context.
- Summary generation begins only after transcript finalization.
- Missing credentials and request failures leave capture, persistence, and the
  recording's terminal `Saved` state intact.

## 16. Implementation Checklist (Definition of Done)

### 16.1 REQUIRED for Conformance

- Call detector based on the operating system's microphone-in-use signal.
- Source-aware start policy: automatic for Zoom, Teams, and visible Google Meet;
  user confirmation for WhatsApp, ambiguous, and unknown activity.
- Orchestrator with a single authoritative state and the state machine of §6.
- Simultaneous capture of system audio and microphone.
- Inactivity detection with `inactivity_timeout_ms`.
- Swappable transcription engine with the contract of §8.
- Default transcription engine that is portable and open source.
- Live captions (partial and final segments).
- Live conversation workspace with transcript, Pi-provider chat, and final
  summary.
- Conversation library navigation for finalized transcripts, with Q&A and
  summary generation scoped to the selected conversation.
- English and Spanish UI selection from the primary macOS language, with an
  English fallback.
- Menu bar status surface with manual control and an always-available action to
  open the full application workspace.
- Notification when a call is detected and started.
- Markdown writing with the structure of §9.1.
- Date-based folder structure and start-time+duration naming (§9.2, §9.3).
- Incremental persistence of final segments.
- Failure handling per §10 without silent loss.
- Typed configuration layer with defaults and pre-operation validation.
- Minimal tool-free Pi runtime pinned to the selected provider and model.
- Pi provider catalog and interactive authentication methods in the settings UI.
- Provider API-key and OAuth credential storage in macOS Keychain.
- Assistant failures isolated from recording and persistence correctness.

### 16.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- Native operating system transcription engine as an option (`engine = native`).
- External-tool-assisted file renaming (outside the app).
- TODO: speaker identification (diarization).
- TODO: export to additional formats.

### 16.3 Operational Validation Before Production (RECOMMENDED)

- Run the Real Integration Profile of §15.7 with a real call.
- Verify permission behavior in the target environment.

## Appendix A. Conversation Workspace

The main window provides the richer reading and assistant experience while the
floating caption surface remains independently hideable.

- It MUST be driven solely from the orchestrator's segment stream.
- It MUST NOT become a requirement for capture or persistence correctness.
- It MUST present current-session history with follow-mode auto-scroll that can be
  paused when the user reads earlier text.
- It MUST provide a conversation sidebar containing the current session and
  non-empty finalized transcripts discovered below `output_dir`, newest first.
- Selecting a stored conversation MUST update the transcript, duration, chat,
  summary, copy, and reveal-file actions to that conversation.
- It MUST keep transcript and assistant panes usable at the same time during an
  active conversation.
- It MUST expose distinct Chat and Summary views and identify the selected model
  with its provider and model name.

## Appendix B. External Transcript Use

- The application continues to expose transcripts as Markdown files in
  `output_dir`.
- Users MAY process those files with external tools, but external tools are not
  required for the built-in Q&A and summary flow.
- Content-based file renaming remains outside v2 conformance scope.
