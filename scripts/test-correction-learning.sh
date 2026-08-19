#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yaprflow-correction-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

xcrun swiftc \
    -module-cache-path "$TEST_DIR/module-cache" \
    -parse-as-library \
    "$REPO_ROOT/yaprflow/CorrectionInference.swift" \
    "$REPO_ROOT/yaprflow/TextValueObservation.swift" \
    "$REPO_ROOT/yaprflow/Vocabulary.swift" \
    "$REPO_ROOT/scripts/test-correction-learning.swift" \
    -o "$TEST_DIR/test-correction-learning"

"$TEST_DIR/test-correction-learning"
