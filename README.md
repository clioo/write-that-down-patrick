# Write That Down

A macOS **menu-bar** application that automatically detects phone/video calls,
transcribes their audio in real time using **local** models, shows live captions,
and saves each transcript as a Markdown file. Its conversation workspace also
lets you ask questions while a meeting is happening and produces a summary when
it ends, using only models offered through **OpenCode Go**.

This is a conforming implementation of [`SPEC.md`](./SPEC.md) — every item in
§16.1 (*Required for Conformance*) is implemented. Section references below point
into that spec.

---

## Requirements

- macOS **13+** (deployment target; built/tested on macOS 26)
- Swift **6** toolchain (Xcode 16+/Swift 6.x)
- Swift dependencies use Swift Package Manager only
- **Pi Coding Agent** for conversation chat and summaries only. Install
  `@earendil-works/pi-coding-agent` so `pi` is available in `~/.local/bin`,
  `/opt/homebrew/bin`, or `/usr/local/bin`; a command-line launch may instead
  point `WTD_PI_PATH` at an executable. Recording, local transcription, captions,
  and Markdown output continue to work when Pi is absent.

## Build & run

```bash
# Build everything (core library + executable + local transcription runtimes).
swift build

# Run the deterministic core-conformance test suite (no audio hardware needed).
swift test

# Launch the app from the command line.
swift run WriteThatDown
```

The first time you use chat or summaries, choose **Connect OpenCode Go** in the
conversation window and save an OpenCode Go API key. The app keeps it in the
macOS Keychain. Pi is invoked once per assistant request with the provider pinned
to `opencode-go`; it is not needed by the local transcription pipeline.

The default engine (WhisperKit) downloads its model from Hugging Face **the first
time it runs** unless you point it at a local model folder — see
[Local audio & privacy](#local-audio--privacy). After the first run the model is
cached locally and the transcription engine needs no further network access.

### Running as a proper `.app` bundle (recommended for real use)

SwiftPM produces a bare executable, not an `.app` bundle. The app runs fine from
`swift run`, but two things work best inside a bundle:

- **Permission prompts** are attributed to the app (the `Info.plist` usage
  strings are embedded into the binary via a linker `-sectcreate` flag — see
  `Package.swift` — so the descriptions exist either way).
- **Notifications** (`UNUserNotificationCenter`) require a real bundle; outside
  one they degrade to log lines instead of crashing.

To wrap the built binary into a minimal bundle:

```bash
swift build -c release
APP="WriteThatDown.app/Contents/MacOS"
mkdir -p "$APP"
cp .build/release/WriteThatDown "$APP/"
cp Info.plist WriteThatDown.app/Contents/Info.plist
open WriteThatDown.app    # or move it to /Applications
```

The app has **no Dock icon** (`LSUIElement` /
`NSApp.setActivationPolicy(.accessory)`). Its main conversation window and the
menu-bar waveform remain the two entry points while the app runs.

---

## How it works (architecture)

The code is split into two SwiftPM targets so the engine dependency is fully
isolated behind a protocol:

| Target | Contents | Dependencies |
| --- | --- | --- |
| `WriteThatDownKit` (library) | Domain model, config, detection, capture, orchestration, persistence, presentation, native engine, permissions | **System frameworks only** — compiles & tests offline |
| `WriteThatDown` (executable) | `WhisperKitEngine`, `SherpaOnnxEngine`, `EngineFactory`, app wiring (`main`, `AppDelegate`, `AppEnvironment`) | + WhisperKit + sherpa-onnx |

Component → spec mapping:

| Component | File(s) | Spec |
| --- | --- | --- |
| Call detector (CoreAudio process attribution + device-level fallback) | `Detection/CallDetector.swift` | §5 |
| Audio capturer (ScreenCaptureKit + AVAudioEngine, down-mixed) | `Audio/AudioCapturer.swift`, `SystemAudioCapturer.swift`, `MicrophoneCapturer.swift` | §7 |
| Transcription engine contract | `Transcription/TranscriptionEngine.swift` | §8.1 |
| Default engine (WhisperKit) | `WhisperKitEngine.swift` | §8.2 |
| Downloadable ONNX engine (Parakeet via sherpa-onnx) | `SherpaOnnxEngine.swift` | §8.2 |
| Native engine (SFSpeechRecognizer, on-device) | `Transcription/NativeSpeechEngine.swift` | §8.2 / §16.2 |
| Session orchestrator (actor, single state authority) | `Orchestration/SessionOrchestrator.swift` | §6 |
| Transcript writer (incremental Markdown) | `Persistence/TranscriptWriter.swift` | §9 |
| Caption surface (`NSPanel` HUD) | `Presentation/CaptionSurface.swift`, `CaptionView.swift` | §3.1.5 |
| Status surface (`NSStatusItem` + popover, manual stop) | `Presentation/StatusSurface.swift`, `StatusPopoverView.swift` | §3.1.6 |
| Conversation assistant (minimal Pi runtime + OpenCode Go) | `Assistant/ConversationAssistant.swift`, `PiOpenCodeGoAssistant.swift`, `OpenCodeGoCredentialStore.swift` | §13 |
| Conversation workspace | `Presentation/ConversationWorkspaceModel.swift`, `MainWindow.swift` | Appendix A |
| Notifications | `Presentation/NotificationService.swift` | §5.3 |
| Configuration (typed, validated) | `Configuration/AppConfiguration.swift` | §11 |
| Permissions | `Permissions/*.swift` | §10.1, §12 |

### Meeting begin / ongoing / end detection

- **Which apps count** — on macOS 14+ mic use is attributed to the owning
  process (CoreAudio process objects). Apps on the `excludedApps` list —
  terminals and editors by default — never trigger recording. OS speech helpers
  (`com.apple.CoreSpeech`), ScreenCaptureKit's replay daemon
  (`com.apple.replayd`), and this app's own bundle ID are also ignored. Find any
  app's bundle ID while it is using the mic with
  `WriteThatDown --who-uses-mic`.
- **Automatic meetings** — sustained mic use starts automatically only when the
  source is clearly a meeting: Zoom, Microsoft Teams, or a browser/PWA with a
  visible Google Meet window. The same `start_confirm_ms` window still filters
  short blips (`1 + ⌈start_confirm_ms / poll_interval_ms⌉` consecutive polls).
- **Everything ambiguous asks first** — WhatsApp, another browser tab, an
  unknown app, and device-level activity that cannot be attributed (including
  the macOS 13 fallback) show a compact “Meeting detected — record?” prompt.
  Nothing is captured or written until the user accepts. Declining suppresses
  repeat prompts until that mic-use episode ends, so a WhatsApp voice note does
  not create a junk conversation.
- **Permission timing** — if permissions are missing when an automatic source
  confirms, the start is held and granting access mid-meeting starts the session
  on the next poll. If permissions are missing after the user accepts an
  ambiguous-source prompt, that microphone episode remains suppressed; grant
  access, release the microphone, and begin a new episode to be prompted again.
  Automatic capture therefore begins after confirmation, so roughly the first
  `start_confirm_ms` is not recorded. Set `start_confirm_ms: 0` to remove that
  delay.
- **Ongoing** — while recording it keeps one session, mixing mic + system audio
  and transcribing in rolling chunks. The inactivity clock starts when recording
  is actually ready (model load time doesn't count against it).
- **End** — `mic released for ≥ mic_inactivity_grace_ms` → `system_stop`; audio
  below the activity threshold for `inactivity_timeout_ms` → `inactivity`
  (evaluated on the audio stream itself, with the mic poll as fallback); or the
  menu-bar **Stop** → `manual`.

### Live captions (the reading pane)

The floating captions panel is built for following a meeting, not just glancing:

- **Follow-mode scrolling** — pinned to the live edge while you're at the
  bottom. Scroll up to re-read something and auto-scroll *pauses* (new lines
  never yank the view); a **"Jump to live ↓"** pill returns you to the
  conversation.
- **Full-session scrollback** — the whole conversation stays in the panel
  (rendered lazily), not just the last few lines.
- **Resizable + remembered** — drag it into a tall reading pane; size and
  position persist across sessions and launches.
- **Text size** — A−/A＋ buttons (persisted), monospaced `[HH:MM:SS]` stamps,
  selectable text.
- **Elapsed-meeting timer** in the header, and a **copy button** for the
  transcript-so-far.
- **Show/Hide Captions** from the menu-bar popover mid-meeting — hiding the
  panel never touches the session; the transcript keeps writing.

### Conversation chat and summary

The main window keeps the live transcript on the left and a conversation-aware
assistant on the right. During an active session you can ask about decisions,
open questions, or action items without opening another app or copying a Markdown
path. The assistant receives the latest transcript text for each request, and the
**Summary** tab is populated automatically after the recording finishes.

The assistant boundary is intentionally narrow:

- The provider is always `opencode-go`; there is no Codex task, direct OpenAI
  API, or fallback to another provider.
- A minimal, request-scoped Pi runtime normalizes the OpenCode Go model APIs. It
  has no shell, filesystem, editing, or other coding-agent tools.
- The OpenCode Go API key is stored at rest in the macOS Keychain, never in
  `config.json`, transcript files, process arguments, or logs. It is supplied to
  the isolated one-shot Pi child only as the transient provider credential for
  that request.
- Audio remains local. Only transcript text, the user's question, and the small
  in-session chat context are sent to the selected OpenCode Go model. When an API
  key is configured, finalization sends the completed transcript text to create
  the automatic summary.
- Assistant errors do not interrupt capture, transcription, or Markdown
  persistence; the transcript remains the source of truth.

## Guía visual de uso

### 1. Inicia una conversación sin generar grabaciones innecesarias

Write That Down comienza a transcribir automáticamente cuando detecta una
reunión clara en **Zoom**, **Microsoft Teams** o una ventana visible de
**Google Meet**. Si el micrófono pertenece a **WhatsApp**, a otra pestaña del
navegador o a una aplicación desconocida, primero muestra una confirmación.
Selecciona **Grabar** para comenzar o **Ahora no** para ignorar ese episodio de
micrófono; no se crea ningún archivo mientras no aceptes.

![Confirmación antes de grabar una fuente ambigua](docs/screenshots/recording-confirmation.png)

### 2. Conecta OpenCode Go y pregunta durante la reunión

En el panel derecho, selecciona **Conectar OpenCode Go** y guarda tu API key.
La clave permanece en el Keychain de macOS. Después elige uno de los modelos
ofrecidos por OpenCode Go y escribe preguntas sobre decisiones, pendientes o
cualquier detalle ya presente en la transcripción. No hace falta abrir Codex ni
copiar la ruta del Markdown: cada pregunta utiliza la transcripción disponible
en ese momento.

![Chat con la conversación mientras la transcripción continúa](docs/screenshots/conversation-chat.png)

### 3. Revisa el resumen al terminar

Al finalizar la conversación, la pestaña **Resumen** se abre mientras OpenCode Go
prepara los puntos importantes, decisiones, próximos pasos y preguntas abiertas.
La transcripción se guarda primero, por lo que un fallo del asistente nunca
impide conservar el Markdown de la reunión.

![Resumen final de la conversación](docs/screenshots/final-summary.png)

### Privacidad

La captura de audio y la transcripción se procesan localmente, y los archivos
permanecen en tu Mac. Para responder preguntas o generar el resumen, la app envía
a OpenCode Go únicamente el texto necesario de la conversación y el contexto
del chat; nunca envía el audio. Pi se ejecuta una vez por solicitud, con el
proveedor fijado a `opencode-go` y sin herramientas de shell, archivos o código.

### Single-writer, race-free orchestration

`SessionOrchestrator` is a Swift `actor` and the **only** component that mutates
session state (`RuntimeState`). Every input — microphone-poll samples, mixed
audio buffers, and manual-stop — is funneled into **one** `AsyncStream<Event>`
consumed by a single serial loop. Because the loop fully handles one event
(including its `await`s) before pulling the next, there is no actor reentrancy and
final-segment ordering is deterministic. The detector's poll cadence doubles as
the inactivity-check tick, so there is no separate timer.

Everything the orchestrator touches is a **protocol** (`MicSignalSource`,
`AudioCapturing`, `TranscriptionEngine`, `TranscriptWriting`, `Presenting`,
`PermissionChecking`), which is why the state machine is covered by deterministic
unit tests with mocks — no microphone, screen, or network required.

---

## Downloadable speech models

The dashboard and menu-bar popover expose a speech-model catalog inspired by
Orca's open-source model picker. Each row shows whether the model is offline or
streaming, its installed size, recommendation status, download progress, and
download/delete actions. A model can be selected only after installation
finishes successfully; selection applies to the next call.

The first catalog model is **Parakeet TDT v3 INT8** (about 670 MB): an offline
multilingual model for 25 European languages with punctuation, capitalization,
and timestamps. Its four ONNX artifacts are downloaded from an immutable
Hugging Face revision into:

`~/Library/Application Support/WriteThatDown/SpeechModels/parakeet-tdt-0.6b-v3-int8`

Downloads are staged outside the live model directory. Every file must match
its cataloged byte count and SHA-256 digest before the directory is installed,
so an interrupted or corrupt download cannot be selected by the engine.
Model/runtime attribution is recorded in [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md).

The UI persists the selection automatically. The equivalent config is:

```json
{
  "engine": "sherpa",
  "speechModel": "parakeet-tdt-0.6b-v3-int8"
}
```

---

## Using a pre-downloaded model (fully offline)

The default engine can run with a WhisperKit model you already have on disk, with
**no download at all**. Point the app at the model folder (the one containing
`AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `MelSpectrogram.mlmodelc`,
`config.json`). For a GUI launch, use the **config file** (env vars are not
inherited by Finder-launched apps):

`~/Library/Application Support/WriteThatDown/config.json`

```json
{
  "engine": "default",
  "language": "auto",
  "whisperModel": "openai_whisper-large-v3-v20240930_626MB",
  "whisperModelFolder": "/absolute/path/to/openai_whisper-large-v3-v20240930_626MB"
}
```

With `whisperModelFolder` set, WhisperKit loads the CoreML model from that folder
with downloads disabled (`download: false`). It still needs a tokenizer; the
matching one (e.g. `openai/whisper-large-v3`) is loaded from the local
`~/Documents/huggingface` cache if present. Verify everything resolves and that
the model loads + transcribes offline with the two headless helpers:

```bash
# Show the resolved config (defaults < config file < env vars):
swift run WriteThatDown --print-config

# Load a model from a folder and run offline inference, then exit 0/1:
swift run WriteThatDown --check-model "/absolute/path/to/your-model-folder"
```

(First model load "specializes" the CoreML model for the Apple Neural Engine and
can take ~30–60 s for a large-v3 model; subsequent loads are much faster.)

## Configuration (§11)

Configuration is resolved as **built-in defaults < config file < environment
variables**, then **validated before any operation starts**
(`AppConfiguration.validated()`); an invalid value shows an error and quits. The
config file is `~/Library/Application Support/WriteThatDown/config.json` (keys:
`outputDir`, `language`, `engine`, `inactivityTimeoutMs`, `pollIntervalMs`,
`startConfirmMs`, `startRetryCooldownMs`, `whisperModel`, `whisperModelFolder`,
`speechModel` — all optional). Env vars override the file:

| Setting | Env var | Default | Notes |
| --- | --- | --- | --- |
| `output_dir` | `WTD_OUTPUT_DIR` | `~/Transcripts` | `~` is expanded |
| `language` | `WTD_LANGUAGE` | system primary language | `auto` allowed |
| `engine` | `WTD_ENGINE` | `default` | `default` (WhisperKit), `sherpa` (downloadable ONNX), or `native` (SFSpeech) |
| `inactivity_timeout_ms` | `WTD_INACTIVITY_TIMEOUT_MS` | `900000` (15 min) | §7.3 |
| `poll_interval_ms` | `WTD_POLL_INTERVAL_MS` | `2000` | §5.1 |
| `start_confirm_ms` | `WTD_START_CONFIRM_MS` | `3000` | confirm window (§5.3); `0` = start immediately |
| `start_retry_cooldown_ms` | `WTD_START_RETRY_COOLDOWN_MS` | `60000` | retry backoff after a failed session start; `0` = retry every window |
| `excludedApps` | `WTD_EXCLUDED_APPS` (comma-sep) | terminals & dev tools | bundle IDs whose mic use never counts as a call (macOS 14+); REPLACES the default list |
| WhisperKit model | `WTD_WHISPER_MODEL` | `base` | e.g. `tiny`, `base`, `small` |
| WhisperKit model folder | `WTD_WHISPER_MODEL_FOLDER` | _(none)_ | local model dir → fully offline, no download |
| Downloadable speech model | `WTD_SPEECH_MODEL` | `parakeet-tdt-0.6b-v3-int8` | catalog model used when `engine = sherpa` |

Example:

```bash
WTD_ENGINE=default WTD_LANGUAGE=en WTD_OUTPUT_DIR=~/CallNotes \
WTD_INACTIVITY_TIMEOUT_MS=300000 swift run WriteThatDown
```

### Implementation-defined values (documented per §7.2, §7.3, §11)

These are part of the implementation contract; the spec leaves the exact policy
to the implementation but requires it be documented.

| Value | Default | Meaning |
| --- | --- | --- |
| Sample rate | 16 kHz | What Whisper-class models expect; both sources resampled to it |
| Channel layout | mono | System + microphone are **down-mixed** to one stream (no diarization in v2) |
| Sample format | 32-bit float PCM, normalized [-1, 1] | Delivered buffer format (§7.2) |
| Capture buffer size | 0.1 s | Size of buffers the capturer emits to the engine |
| Transcription window | 2.0 s | Audio the engine accumulates before inference (caption latency vs. accuracy) |
| Activity threshold (RMS) | 0.005 (≈ −46 dBFS) | Below this, audio counts as silence for inactivity (§7.3) |
| Mic-off grace | 4000 ms | Sustained mic-in-use=off before ending with `system_stop` (§5.4) |
| Audio-source ring cap | 5 s per source | Bounds memory if a source bursts |

WhisperKit streaming tunables (in `WhisperKitEngine.swift`): chunks are committed
as **final** segments on detected trailing silence (≥0.6 s) past a 1.5 s minimum,
or at a 14 s hard cap; between commits the in-progress chunk is transcribed at a
throttled cadence and shown as **partial** captions; pure-silence audio is never
sent to the model.

Parakeet is an offline recognizer, so `SherpaOnnxEngine` creates live partials by
re-decoding the current utterance at a throttled cadence. It commits at trailing
silence after a 1.5 s minimum or at a 20 s hard cap, keeping inference buffers
bounded while preserving incremental transcript writes.

### End-reason mapping (§5.4, §7.3)

- **`manual`** — user clicked *Stop Recording* in the menu-bar popover.
- **`inactivity`** — audio level stayed below the activity threshold for
  `inactivity_timeout_ms`.
- **`system_stop`** — the OS mic-in-use signal stayed off for the mic-off grace
  window (the call app released the microphone).
- **`error`** — a failure finalized the session (finals are still preserved).

---

## Transcript output (§9)

```
~/Transcripts/
└── 2026-06-06/
      └── 14-25_3min.md
```

```markdown
# Call 2026-06-06 14:25
**Date:** 2026-06-06 14:25
**Duration:** 3 min

## Transcript
[00:00:05] Hey, can you hear me?
[00:00:09] Yeah, loud and clear.
```

While recording, the file is named `HH-MM_recording_.md` with a provisional
duration; final segments are appended **incrementally** and flushed to disk
(`FileHandle.synchronize`) so they survive a crash (§9.4, §10.3). On finalize the
duration header is filled in and the file is renamed to `HH-MM_<n>min.md`. File
names are sanitized so only `[A-Za-z0-9._-]` remain (§4.2). Renaming *by content*
is intentionally **not** done here — that remains an external workflow
(Appendix B of the spec).

---

## Local audio & privacy (§12)

- **Captured audio never leaves the device.** Transcription remains local for
  every speech engine; no audio buffer is uploaded to the conversation model.
- **Assistant requests do send text.** While you chat, the current transcript
  text and your question are sent to the selected OpenCode Go model. When the
  assistant is configured, the finalized transcript text is sent once more to
  generate the end-of-conversation summary. Provider processing and retention
  depend on the selected OpenCode Go model's published policy.
- The OpenCode Go credential is kept in the macOS Keychain. It is not stored
  beside transcripts or in the JSON configuration file.
- The **native** engine sets `requiresOnDeviceRecognition = true` and *refuses to
  start* if on-device recognition is unavailable for the locale, rather than
  silently falling back to network recognition.
- The **default** (WhisperKit) engine performs on-device inference. Its only
  network activity is a **one-time model download** on first run when no local
  model is configured. To run transcription **strictly offline**, pre-download
  a model and set `WTD_WHISPER_MODEL_FOLDER` to its directory; the engine then
  loads from disk with downloads disabled (`download: false`).
- The **sherpa** engine also performs inference locally. Catalog downloads use
  pinned HTTPS URLs plus exact size and SHA-256 verification, and require no
  network access after installation.
- Transcripts are plain text under `output_dir` (default `~/Transcripts`); you
  control that location's confidentiality.

## Permissions (§10.1, §12)

Requested on first launch:

- **Microphone** (AVFoundation) — required.
- **Screen Recording** (ScreenCaptureKit needs it even for audio-only) — required
  for system audio.
- **Notifications** (UserNotifications) — optional; only the "recording started"
  alert.
- **Speech Recognition** (Speech) — only when `engine = native`.

If a required permission is denied, sessions are **blocked**, a visible error is
shown, and the app keeps observing (it never crashes silently). Grant access in
**System Settings → Privacy & Security**, then start a call again.

---

## Logs & crash reports

The app logs through `os.Logger` (subsystem `com.writethatdown.app`) — nothing
ever leaves the device. Use the bundled helper:

```bash
./logs.sh                  # everything from the last hour
./logs.sh errors 6h        # errors/faults only
./logs.sh detection 30m    # why did/didn't a call start or stop
./logs.sh stream           # live tail while reproducing an issue
./logs.sh crashes          # list crash reports (~/Library/Logs/DiagnosticReports)
./logs.sh crash            # print the newest crash report
./logs.sh persist          # sudo: keep .info logs across reboots for post-mortems
```

Startup failures (engine/capture/transcript could not initialize) surface **one**
error notification per mic episode and retry at most every
`start_retry_cooldown_ms` (default 60 s; cleared the moment the mic is
released, so a new call retries immediately). The failure is always logged and
reflected in the menu-bar status regardless.

## Tests (§15)

`swift test` runs the deterministic *Core Conformance* suite, covering:

- Detection & state: Idle→Recording for an approved sustained mic source;
  confirm window ignores brief mic blips (incl. rounding boundaries);
  Zoom/Teams/visible Google Meet take the automatic route; WhatsApp, ambiguous,
  and unknown sources require acceptance;
  declining is suppressed until mic release; a permission grant mid-meeting
  starts on the next poll without a new window; no second session while
  recording; manual stop → `manual`; sustained audio-inactivity → `inactivity`;
  sustained mic-off → `system_stop`.
- Engine contract: partials shown but **not** written; finals written with
  orchestrator-assigned monotonic index.
- Persistence: date-folder creation; start-time+duration naming; incremental
  append; duration update on finalize; sanitization; whitespace skipping.
- Configuration: defaults, `~` expansion, pre-operation validation.
- Assistant boundary: requests use only the `opencode-go` provider; transcript
  text is supplied directly without filesystem or coding tools; summary starts
  after finalization; assistant failures cannot fail transcript persistence.
- Failures: denied permission blocks start & informs user; capture failure →
  Failed → Idle; engine failure mid-recording preserves captured finals;
  persistence failure surfaces visibly without silent loss.

The *Real Integration Profile* (§15.7 — a smoke test with a real call) is
environment-dependent and **not** automated here; run it manually on a target Mac
with permissions granted. A skipped integration check should be reported as
skipped, not as passed.

## Known limitations (v2)

- No speaker diarization (§2.2) — system + mic are down-mixed into one stream.
- The native (SFSpeech) engine typically commits **final** segments at session
  end rather than incrementally, because SFSpeech marks results final mainly at
  end-of-audio; partial captions update live throughout. The default WhisperKit
  engine commits finals incrementally. (Native is an optional engine, §16.2.)
