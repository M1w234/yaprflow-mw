#!/usr/bin/env bash
# Generate the signed Sparkle feed that ships beside the notarized DMG.
# The private EdDSA key stays in the macOS Keychain under SPARKLE_ACCOUNT.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 2 || $# -gt 4 ]]; then
    echo "usage: scripts/generate-appcast.sh <dmg-path> <version> [output-path] [release-notes]" >&2
    exit 1
fi

DMG_PATH="$1"
VERSION="$2"
OUTPUT_PATH="${3:-build/appcast.xml}"
RELEASE_NOTES="${4:-}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-yaprflow}"
GH_REPO="${GH_REPO:-M1w234/yaprflow-mw}"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: update archive not found: $DMG_PATH" >&2
    exit 1
fi

find_sparkle_tool() {
    local tool_name="$1"
    local candidate
    local candidates=(
        "${SPARKLE_TOOLS_DIR:-}/$tool_name"
        "build.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool_name"
        "build/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool_name"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if ! GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)"; then
    echo "==> Resolving Sparkle publishing tools"
    xcodebuild \
        -project yaprflow.xcodeproj \
        -scheme yaprflow \
        -resolvePackageDependencies \
        -clonedSourcePackagesDirPath build.noindex/SourcePackages
    GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)"
fi

if ! GENERATE_KEYS="$(find_sparkle_tool generate_keys)"; then
    echo "error: Sparkle generate_keys tool was not found after package resolution" >&2
    exit 1
fi

if ! "$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p >/dev/null; then
    cat >&2 <<EOF
error: no Sparkle signing key was found for account '$SPARKLE_ACCOUNT'.
Create it once with:
  $GENERATE_KEYS --account $SPARKLE_ACCOUNT
EOF
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-appcast.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp "$DMG_PATH" "$STAGING_DIR/yaprflow.dmg"

if [[ -z "$RELEASE_NOTES" ]]; then
    RELEASE_NOTES="This update includes the latest Yaprflow improvements and fixes."
fi
printf '%s\n' "$RELEASE_NOTES" > "$STAGING_DIR/yaprflow.md"

echo "==> Generating signed Sparkle appcast"
"$GENERATE_APPCAST" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$GH_REPO/releases/download/v$VERSION/" \
    --link "https://yaprflow.com/" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    --embed-release-notes \
    -o "$STAGING_DIR/appcast.xml" \
    "$STAGING_DIR"

if ! grep -Fq 'sparkle:edSignature=' "$STAGING_DIR/appcast.xml"; then
    echo "error: generated appcast is missing an EdDSA archive signature" >&2
    exit 1
fi
if ! grep -Fq "releases/download/v$VERSION/yaprflow.dmg" "$STAGING_DIR/appcast.xml"; then
    echo "error: generated appcast does not reference the v$VERSION DMG" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
cp "$STAGING_DIR/appcast.xml" "$OUTPUT_PATH"

echo "==> Signed appcast: $OUTPUT_PATH"

