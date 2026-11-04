#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LOG="$TMP_DIR/build.log"
BUDGET="$TMP_DIR/budget.tsv"
cat >"$LOG" <<'LOG'
/Users/example/cmux/Sources/AppDelegate.swift:10:1: warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'ObjectiveC'
/Users/example/cmux/Sources/AppDelegate.swift:10:1: warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'ObjectiveC'
/Users/example/cmux/Sources/AppDelegate.swift:42:9: warning: result of call to 'closePanel(_:force:)' is unused
2026-04-28T09:40:13.8874600Z /Users/example/cmux/Sources/AppDelegate.swift:44:9: warning: capture of 'observer' with non-Sendable type '(any NSObjectProtocol)?' in a '@Sendable' closure; this is an error in the Swift 6 language mode
2026-04-28T09:40:13.8874610Z /Users/example/cmux/Sources/AppDelegate.swift:44:9: warning: capture of 'observer' with non-sendable type '(any NSObjectProtocol)?' in a '@Sendable' closure
/Users/example/cmux/vendor/bonsplit/Sources/Bonsplit/Public/BonsplitView.swift:1:1: warning: ignored vendor warning
/tmp/cmux/SourcePackages/checkouts/posthog-ios/PostHog/PostHogSDK.swift:1:1: warning: ignored package warning
warning: Run script build phase 'Run Script' will be run during every build
LOG

cat >>"$LOG" <<LOG
$ROOT_DIR/.ci-source-packages/checkouts/example/Sources/Example/File.swift:1:1: warning: ignored cloned package warning
$ROOT_DIR/Packages/WarningBudgetFixture/Sources/WarningBudgetFixture/File.swift:1:1: warning: package-owned warning
LOG

python3 scripts/swift_warning_budget.py --log "$LOG" --budget "$BUDGET" --write-budget

if ! grep -q $'1\tSources/AppDelegate.swift\tadd' "$BUDGET"; then
  echo "expected AppDelegate preconcurrency warning budget entry" >&2
  exit 1
fi

if ! grep -Fq $'1\tSources/AppDelegate.swift\tcapture of '\''observer'\'' with non-sendable type '\''(any NSObjectProtocol)?'\'' in a '\''@Sendable'\'' closure' "$BUDGET"; then
  echo "expected normalized Sendable warning budget entry" >&2
  exit 1
fi

if ! grep -Fq $'1\tPackages/WarningBudgetFixture/Sources/WarningBudgetFixture/File.swift\tpackage-owned warning' "$BUDGET"; then
  echo "expected Packages warning to preserve the Packages root" >&2
  exit 1
fi

if grep -q 'vendor/bonsplit' "$BUDGET"; then
  echo "vendor warning should not be included" >&2
  exit 1
fi

if grep -q 'SourcePackages' "$BUDGET"; then
  echo "package warning should not be included" >&2
  exit 1
fi

if grep -Fq '.ci-source-packages' "$BUDGET"; then
  echo "cloned package warning should not be included" >&2
  exit 1
fi

python3 scripts/swift_warning_budget.py --log "$LOG" --budget "$BUDGET"

cat >>"$LOG" <<'LOG'
/Users/example/cmux/Sources/AppDelegate.swift:43:9: warning: result of call to 'closePanel(_:force:)' is unused
LOG

if python3 scripts/swift_warning_budget.py --log "$LOG" --budget "$BUDGET" >"$TMP_DIR/fail.out" 2>&1; then
  echo "expected warning budget failure" >&2
  exit 1
fi

if ! grep -q 'Swift warning budget exceeded' "$TMP_DIR/fail.out"; then
  echo "expected budget failure output" >&2
  cat "$TMP_DIR/fail.out" >&2
  exit 1
fi

printf 'not-a-valid-budget-line\n' >"$TMP_DIR/bad-budget.tsv"
if python3 scripts/swift_warning_budget.py --log "$LOG" --budget "$TMP_DIR/bad-budget.tsv" >"$TMP_DIR/bad.out" 2>&1; then
  echo "expected malformed budget failure" >&2
  exit 1
fi

if ! grep -q 'Error reading warning budget' "$TMP_DIR/bad.out"; then
  echo "expected malformed budget error output" >&2
  cat "$TMP_DIR/bad.out" >&2
  exit 1
fi

if grep -q 'Traceback' "$TMP_DIR/bad.out"; then
  echo "malformed budget should not print a traceback" >&2
  cat "$TMP_DIR/bad.out" >&2
  exit 1
fi
