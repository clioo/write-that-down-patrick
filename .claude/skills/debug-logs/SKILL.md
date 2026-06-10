---
name: debug-logs
description: Read Write That Down's logs and crash reports to diagnose crashes, failed sessions, missing transcripts, or detection problems ("my call never started/stopped"). Use whenever the user reports the app crashed, failed, behaved unexpectedly, an error notification appeared, or the menu-bar icon is missing/blank.
---

# Debugging Write That Down via logs

The app is a menu-bar macOS app (`/Applications/WriteThatDown.app`, built from this repo). It has **no log files of its own** — everything goes through `os.Logger` under subsystem **`com.writethatdown.app`** (see `Sources/WriteThatDownKit/Support/Log.swift`).

## Quick start

Use the repo helper (preferred):

```bash
./logs.sh                  # everything, last hour
./logs.sh errors 6h        # errors/faults only, last 6 hours
./logs.sh detection 30m    # detection + orchestrator: why a call did/didn't start or stop
./logs.sh stream           # live tail while reproducing
./logs.sh crashes          # list crash reports
./logs.sh crash            # dump the newest crash report (.ips)
./logs.sh persist          # sudo: make .info logs durable for post-mortem work
```

Raw equivalents if `logs.sh` is unavailable:

```bash
log show --predicate 'subsystem == "com.writethatdown.app"' --info --last 1h
log stream --predicate 'subsystem == "com.writethatdown.app"' --info
```

## Log categories (filter with `category == "…"`)

| Category | What it tells you |
|---|---|
| `detection` | CallDetector start/stop, poll cadence |
| `orchestrator` | Session lifecycle: confirm-window blips ("Mic blip ignored (N/M confirm ticks)"), session start, finalize reasons (`inactivity`/`manual`/`system_stop`/`error`), startup failures + retry cooldown |
| `capture` | ScreenCaptureKit + mic start/stop, SCStream errors |
| `engine` | WhisperKit/SFSpeech init + transcription failures |
| `persistence` | Transcript begin/append/finalize, file paths |
| `presentation` | User-visible errors (always logged with full text) |
| `permissions` | TCC state |
| `app` | Config resolution (config-file applied/invalid, override warnings) |

## Crash reports

- Location: `~/Library/Logs/DiagnosticReports/WriteThatDown-*.ips` (JSON; `./logs.sh crash` prints the newest).
- If the app dies instantly at launch with no crash report, run the binary directly to see stderr: `"/Applications/WriteThatDown.app/Contents/MacOS/WriteThatDown"` — config warnings and invalid-config errors go to stderr, which GUI launches discard.

## Diagnostic helpers built into the binary

```bash
"/Applications/WriteThatDown.app/Contents/MacOS/WriteThatDown" --print-config              # resolved config; exit 1 if invalid
"/Applications/WriteThatDown.app/Contents/MacOS/WriteThatDown" --check-model "/path/to/folder"  # offline self-test of a LOCAL model folder, exit 0/1
"/Applications/WriteThatDown.app/Contents/MacOS/WriteThatDown" --download-model "<modelName>"    # download a model variant (one-time) then self-test, exit 0/1
```

Config file: `~/Library/Application Support/WriteThatDown/config.json` (camelCase keys). It is read **once at launch** — a running instance keeps its old config until relaunched. An invalid file is ignored with a loud warning in `app` logs + stderr.

## Known failure signatures

- **"Unable to load model … Compile the model with Xcode or MLModel.compileModel"** → the model folder contains **Git LFS pointer files**, not real weights. Check: `find <model-folder> -name weight.bin -exec wc -c {} +` — pointers are ~134 bytes; real weights are MB–GB. Fix: remove `whisperModelFolder` from config.json so WhisperKit downloads to its own cache (`~/.cache/huggingface` / `~/Documents/huggingface`), then **quit and relaunch** (config is launch-time only). Verify the download works first with `--download-model "<name>"`.
- **Error still names the OLD model path after a config change** → a **stale running instance** is using the old config. `pkill -x WriteThatDown` then relaunch. Config is read once at launch.
- **Repeated error notifications during one call** → stale instance predating the failure-cooldown logic, or a persistent startup failure. Expected behavior since the cooldown: ONE visible error per mic episode, retries at most every `startRetryCooldownMs` (default 60 s). Check `orchestrator` logs for "Session startup failed".
- **Session never starts during a call** → `./logs.sh detection`: look for "Mic blip ignored" (confirm window `startConfirmMs` too long vs `pollIntervalMs`), "Permission required" (mic/Screen Recording denied), or silent retry-cooldown suppression after an earlier failure.
- **Menu-bar icon missing** → app not running (`pgrep -x WriteThatDown`), or it crashed at launch (`./logs.sh crash`, run binary directly for stderr).
- **No notifications** → notifications require a real `.app` bundle launch; `swift run` suppresses them by design (logged in `presentation`).
- **`.info` logs missing from `log show`** → memory-buffered by default; run `./logs.sh persist` before reproducing.

## Rebuilding / reinstalling

`./install.sh` rebuilds release, signs ad-hoc, installs to `/Applications`. **Quit the running instance first** (`pkill -x WriteThatDown`) — otherwise the old process keeps running with old code AND old config. Tests: `swift test` (deterministic, no hardware needed).
