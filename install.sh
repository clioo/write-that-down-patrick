#!/usr/bin/env bash
#
# Builds Write That Down, wraps it in a proper .app bundle, ad-hoc code-signs it
# (so macOS can track its Microphone / Screen-Recording permission grants), and
# installs it.
#
# Usage:
#   ./install.sh                 # installs to /Applications
#   DEST=~/Applications ./install.sh
#
set -euo pipefail

APP_NAME="WriteThatDown"
DEST="${DEST:-/Applications}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Building release binary (this also fetches WhisperKit on first run)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

BUILD_APP="$SCRIPT_DIR/$APP_NAME.app"
echo "==> Assembling $APP_NAME.app …"
rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS"
cp "$BIN_PATH" "$BUILD_APP/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$BUILD_APP/Contents/Info.plist"
printf 'APPL????' > "$BUILD_APP/Contents/PkgInfo"

# Prefer a real signing identity: ad-hoc signatures get a new identity every
# build, so macOS resets the app's Microphone/Screen-Recording grants on every
# reinstall. With a stable identity (e.g. a self-signed "WriteThatDown Dev"
# cert, or any Apple Development cert), permissions stick across updates.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"[^"]+"' | tr -d '"' \
  | grep -m1 -E 'WriteThatDown|Apple Development|Developer ID Application|Mac Developer|iPhone Developer' || true)
if [[ -n "${IDENTITY:-}" ]]; then
  echo "==> Code-signing with stable identity: $IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp=none "$BUILD_APP"
else
  echo "==> Ad-hoc code-signing (no signing identity found)."
  echo "    NOTE: macOS will RESET Microphone/Screen-Recording grants on every"
  echo "    reinstall. To fix permanently, create a self-signed code-signing"
  echo "    cert named 'WriteThatDown Dev' in Keychain Access (Certificate"
  echo "    Assistant → Create a Certificate → type: Code Signing), then re-run."
  codesign --force --sign - --timestamp=none "$BUILD_APP"
fi
codesign --verify --verbose "$BUILD_APP"

echo "==> Installing to $DEST …"
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
cp -R "$BUILD_APP" "$DEST/$APP_NAME.app"
rm -rf "$BUILD_APP"

echo ""
echo "✅ Installed: $DEST/$APP_NAME.app"
echo ""
echo "Next steps:"
echo "  1. Launch it:   open \"$DEST/$APP_NAME.app\""
echo "  2. Grant permissions when prompted (or in System Settings → Privacy & Security):"
echo "       • Microphone"
echo "       • Screen Recording  (needed for system/call audio)"
echo "       • Notifications     (optional)"
echo "  3. Look for the waveform icon in the menu bar — there is no Dock icon."

CONFIG="$HOME/Library/Application Support/WriteThatDown/config.json"
if [[ -f "$CONFIG" ]]; then
  echo "  4. Using model config: $CONFIG"
  echo "     (Verify with:  \"$DEST/$APP_NAME.app/Contents/MacOS/$APP_NAME\" --print-config )"
else
  echo "  4. Transcription model: with no config file, the WhisperKit model downloads"
  echo "     once on first use. To run fully offline, create:"
  echo "       $CONFIG"
  echo "     with {\"whisperModelFolder\": \"/path/to/your-model-folder\"} — see README."
fi
