#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-number-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

/usr/bin/xcrun swiftc \
    -module-cache-path "$TEST_DIR/module-cache" \
    -parse-as-library \
    "$REPO_ROOT/yaprflow/SpokenNumberFormatter.swift" \
    "$REPO_ROOT/scripts/test-spoken-number-formatter.swift" \
    -o "$TEST_DIR/test-spoken-number-formatter"

"$TEST_DIR/test-spoken-number-formatter"
