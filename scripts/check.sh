#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
monopods_logs=$(mktemp -d "${TMPDIR:-/tmp}/monopods-check.XXXXXX")
flags=(--disable-sandbox --cache-path build/cache --config-path build/config --security-path build/security)
swift build "${flags[@]}" 2>&1 | tee "$monopods_logs/build.log"
swift test "${flags[@]}" 2>&1 | tee "$monopods_logs/test.log"
count=$(awk '/Test run with [0-9]+ tests/ {for(i=1;i<=NF;i++) if($i=="with") total+=$(i+1)} END {print total+0}' "$monopods_logs/test.log")
test "${count:-0}" -ge 500
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v 2>&1 | tee "$monopods_logs/python.log"
swift-format lint --strict --recursive Package.swift Sources Tests 2>&1 | tee "$monopods_logs/format.log"
swiftlint lint --strict --no-cache 2>&1 | tee "$monopods_logs/lint.log"
plutil -lint Resources/Info.plist
bash -n scripts/check.sh scripts/bundle.sh scripts/dmg.sh scripts/release.sh scripts/sparkle-tools.sh
printf 'Checks passed: %s tests; logs: %s\n' "$count" "$monopods_logs"
