#!/usr/bin/env bash
# Local dev build + install. Prefers the same Developer ID identity used by
# public releases so replacing /Applications/yaprflow.app does not create stale
# Accessibility or Input Monitoring entries. Falls back to the stable local
# identity (or ad-hoc) when the release identity is unavailable.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build.noindex/Build/Products/Release/yaprflow.app"
DEST="/Applications/yaprflow.app"

cd "$ROOT"

if [ ! -d "$ROOT/Models/parakeet-tdt-0.6b-v2/Encoder.mlmodelc" ]; then
    echo "❌ Speech model missing. See CLAUDE.md → Constraints / Gotchas for the download command." >&2
    exit 1
fi

# We can't pass the chosen identity straight to xcodebuild because SPM packages
# without a development team fail when CODE_SIGNING_ALLOWED=YES. Build unsigned
# and re-sign only the final app afterwards.
DEVELOPER_IDENTITY="${DEVELOPER_ID_APPLICATION:-7562675D2DBC9FAE3122A093F4B441380D88561B}"
LOCAL_SIGN_IDENTITY="Yaprflow Local Dev"
SIGN_IDENTITY=""
SIGN_TIMESTAMP=()

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$DEVELOPER_IDENTITY"; then
    SIGN_IDENTITY="$DEVELOPER_IDENTITY"
    SIGN_TIMESTAMP=(--timestamp)
    echo "==> Building yaprflow (Release; will re-sign with the public Developer ID)…"
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$LOCAL_SIGN_IDENTITY"; then
    SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
    echo "==> Building yaprflow (Release; public identity unavailable, using '$LOCAL_SIGN_IDENTITY')…"
    echo "    Switching back to a public build will require repairing macOS privacy entries once."
else
    echo "==> Building yaprflow (Release, ad-hoc)…"
    echo "    Rebuilds may invalidate Accessibility and Input Monitoring permissions."
fi

xcodebuild \
    -project yaprflow.xcodeproj \
    -scheme yaprflow \
    -configuration Release \
    -derivedDataPath build.noindex \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

if [ ! -d "$APP" ]; then
    echo "❌ Build succeeded but .app not found at $APP" >&2
    exit 1
fi

# Re-sign only the final app so unsigned SPM products do not require a
# development team. A secure timestamp is required for Developer ID; the
# stable self-signed fallback intentionally omits it.
if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Re-signing .app with '$SIGN_IDENTITY'…"
    codesign --force --deep --options runtime \
        "${SIGN_TIMESTAMP[@]}" \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$ROOT/yaprflow/yaprflow.entitlements" \
        "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> Quitting running yaprflow…"
osascript -e 'tell application "yaprflow" to quit' 2>/dev/null || true
for _ in {1..20}; do
    if ! pgrep -x yaprflow >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
if pgrep -x yaprflow >/dev/null 2>&1; then
    echo "❌ yaprflow did not quit within 10 seconds; leaving the installed app untouched." >&2
    exit 1
fi

echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --verify --deep --strict --verbose=2 "$DEST"
fi

echo "==> Launching…"
open "$DEST"

echo ""
echo "✅ Done. Look for the waveform icon in the menu bar."
