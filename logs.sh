#!/usr/bin/env bash
#
# Read Write That Down logs and crash reports.
#
# The app logs everything through os.Logger under the subsystem
# "com.writethatdown.app", split into categories:
#   detection     mic-in-use polling, blip/confirm-window decisions
#   orchestrator  session lifecycle (start/finalize/end reasons/failures)
#   capture       ScreenCaptureKit + AVAudioEngine
#   engine        WhisperKit / SFSpeech transcription
#   persistence   transcript writing/finalize
#   presentation  captions/menu-bar/notifications, user-visible errors
#   permissions   TCC state
#   app           configuration, launch
#
# Usage:
#   ./logs.sh                      # everything from the last hour
#   ./logs.sh recent 30m           # everything from the last 30 minutes
#   ./logs.sh errors [window]      # errors/faults only
#   ./logs.sh detection [window]   # detection + orchestrator (why didn't my call start/stop?)
#   ./logs.sh stream               # live tail (Ctrl-C to stop)
#   ./logs.sh crashes              # list crash reports
#   ./logs.sh crash                # print the newest crash report
#   ./logs.sh persist              # make .info logs durable across reboots (sudo)
#
set -euo pipefail

SUBSYSTEM="com.writethatdown.app"
APP_NAME="WriteThatDown"
CMD="${1:-recent}"
WINDOW="${2:-1h}"

case "$CMD" in
  recent)
    log show --predicate "subsystem == \"$SUBSYSTEM\"" --info --last "$WINDOW"
    ;;
  errors)
    # messageType 16 = Error, 17 = Fault
    log show --predicate "subsystem == \"$SUBSYSTEM\" AND messageType IN {16, 17}" --last "$WINDOW"
    ;;
  detection)
    log show --predicate "subsystem == \"$SUBSYSTEM\" AND category IN {\"detection\", \"orchestrator\"}" --info --last "$WINDOW"
    ;;
  stream)
    echo "Streaming $SUBSYSTEM logs (Ctrl-C to stop)…" >&2
    log stream --predicate "subsystem == \"$SUBSYSTEM\"" --info
    ;;
  crashes)
    FOUND=$(ls -t ~/Library/Logs/DiagnosticReports/${APP_NAME}-*.ips 2>/dev/null | head -10 || true)
    if [[ -n "$FOUND" ]]; then
      echo "$FOUND"
    else
      echo "No crash reports for $APP_NAME in ~/Library/Logs/DiagnosticReports/."
    fi
    ;;
  crash)
    LATEST=$(ls -t ~/Library/Logs/DiagnosticReports/${APP_NAME}-*.ips 2>/dev/null | head -1 || true)
    if [[ -n "$LATEST" ]]; then
      echo "=== $LATEST ===" >&2
      cat "$LATEST"
    else
      echo "No crash reports for $APP_NAME." >&2
      exit 1
    fi
    ;;
  persist)
    # .info messages live in a memory ring buffer by default and can be evicted.
    # This makes them durable (survives reboots) so post-mortem debugging works.
    echo "Enabling persistent info-level logging for $SUBSYSTEM (requires sudo)…" >&2
    sudo log config --subsystem "$SUBSYSTEM" --mode "persist:info"
    sudo log config --status --subsystem "$SUBSYSTEM"
    ;;
  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
    exit 2
    ;;
esac
