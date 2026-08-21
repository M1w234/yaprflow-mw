#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-hotkey-permission-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$TEST_DIR/module-cache"
export SWIFT_MODULE_CACHE_PATH="$TEST_DIR/module-cache"

/usr/bin/xcrun swiftc \
    "$REPO_ROOT/yaprflow/ModifierHotkeyListenerStatus.swift" \
    "$REPO_ROOT/scripts/test-modifier-hotkey-permissions.swift" \
    -o "$TEST_DIR/test-modifier-hotkey-permissions"

"$TEST_DIR/test-modifier-hotkey-permissions"
