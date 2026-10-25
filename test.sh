#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -module-cache-path "${TMPDIR:-/tmp}/inputguard-test-module-cache" \
    "$ROOT"/src/Model/*.swift \
    "$ROOT/src/Runtime/SwitchEngine.swift" \
    "$ROOT/src/Input/FocusProbe.swift" \
    "$ROOT/src/Input/AXInspect.swift" \
    "$ROOT/src/Input/InputSource.swift" \
    "$ROOT/src/Core/Constants.swift" \
    "$ROOT/src/Core/Loc.swift" \
    "$ROOT/tests/main.swift" -o "$TMP/tests"
"$TMP/tests"
