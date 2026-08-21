#!/usr/bin/env bash
# Create a signed, notarized, and stapled DMG from a .app bundle.
# Usage: scripts/notarize-dmg.sh <path-to-app> [output-dmg]

set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: $0 <path-to-app> [output-dmg]"
    echo "Example: $0 /path/to/yaprflow.app"
    echo "Example: $0 /path/to/yaprflow.app ./yaprflow.dmg"
    exit 1
fi

APP="$1"
DMG="${2:-$(pwd)/yaprflow.dmg}"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-notary-yaprflow-mw}"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-7562675D2DBC9FAE3122A093F4B441380D88561B}"

if [ ! -d "$APP" ]; then
    echo "Error: .app not found: $APP"
    exit 1
fi
if ! codesign --verify --deep --strict "$APP"; then
    echo "Error: input app does not have a valid code signature: $APP" >&2
    exit 1
fi
if ! codesign -d --verbose=4 "$APP" 2>&1 | grep -Fq "Authority=Developer ID Application:"; then
    echo "Error: input app is not signed with a Developer ID Application certificate" >&2
    exit 1
fi
if ! codesign -d --verbose=4 "$APP" 2>&1 | grep -Eq "^CodeDirectory .*flags=.*\\(runtime\\)"; then
    echo "Error: input app is not signed with hardened runtime enabled" >&2
    exit 1
fi

echo "==> Staging app..."
STAGE="$(mktemp -d -t yaprflow-dmg.XXXXXX)"
RW_DMG="$STAGE/yaprflow-rw.dmg"
MOUNT_DIR="$STAGE/mnt"
mkdir -p "$MOUNT_DIR"
trap '
    if mount | grep -q "$MOUNT_DIR"; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
    rm -rf "$STAGE"
' EXIT

ditto "$APP" "$STAGE/yaprflow.app"
SIZE_MB=$(( $(du -sm "$STAGE/yaprflow.app" | awk '{print $1}') + 50 ))

echo "==> Creating ${SIZE_MB}MB read-write DMG..."
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname Yaprflow -ov "$RW_DMG"

echo "==> Attaching under /tmp (bypasses /Volumes TCC protection)..."
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noautoopen

echo "==> Copying app into DMG..."
ditto "$STAGE/yaprflow.app" "$MOUNT_DIR/yaprflow.app"

echo "==> Adding /Applications shortcut..."
ln -s /Applications "$MOUNT_DIR/Applications"

echo "==> Detaching..."
hdiutil detach "$MOUNT_DIR" -quiet

echo "==> Converting to compressed read-only DMG..."
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG"

echo "==> Signing DMG..."
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

echo "==> Submitting for notarization (this can take 1-5 min)..."
# `notarytool submit --wait` intermittently crashes with `Bus error: 10` while
# polling. Submit, capture the id, and poll `notarytool info` ourselves.
SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE")
echo "$SUBMIT_OUTPUT"
SUB_ID=$(echo "$SUBMIT_OUTPUT" | sed -n 's/^[[:space:]]*id:[[:space:]]*//p' | head -n1)
if [ -z "$SUB_ID" ]; then
    echo "error: could not parse submission id" >&2
    exit 1
fi

while :; do
    sleep 20
    STATUS=$(xcrun notarytool info "$SUB_ID" --keychain-profile "$KEYCHAIN_PROFILE" 2>/dev/null \
        | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -n1)
    echo "    DMG: ${STATUS:-unknown} (id: $SUB_ID)"
    case "$STATUS" in
        Accepted) break ;;
        "In Progress"|"") continue ;;
        *)
            echo "error: notarization finished with status: $STATUS" >&2
            xcrun notarytool log "$SUB_ID" --keychain-profile "$KEYCHAIN_PROFILE" >&2 || true
            exit 1
            ;;
    esac
done

echo "==> Stapling ticket..."
xcrun stapler staple "$DMG"

echo "==> Verifying..."
spctl -a -vvv -t open --context context:primary-signature "$DMG"

echo ""
echo "Done: $DMG"
du -sh "$DMG"
