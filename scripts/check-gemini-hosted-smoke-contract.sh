#!/usr/bin/env bash
# Guard the hosted Gemini CLI smoke against overclaiming prompt evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_FILE="${GT_GEMINI_HOSTED_SMOKE_FILE:-$ROOT_DIR/scripts/gemini-cli-hosted-chrome-smoke.sh}"
FAILURES=0

fail() {
  echo "Gemini hosted smoke contract failed: $*" >&2
  FAILURES=$((FAILURES + 1))
}

if [[ ! -f "$SMOKE_FILE" ]]; then
  echo "Missing Gemini hosted smoke file: $SMOKE_FILE" >&2
  exit 1
fi

if grep -Fq "observed.doneOrStoppedObserved || observed.markerSeen" "$SMOKE_FILE"; then
  fail "artifact ok predicate still accepts stop/done without proving the marker returned"
fi

if ! grep -Fq "observed.markerSeen &&" "$SMOKE_FILE"; then
  fail "artifact ok predicate does not require the prompt marker"
fi

if ! grep -Fq "observed.doneOrStoppedObserved" "$SMOKE_FILE"; then
  fail "artifact ok predicate does not require stopped/done recovery"
fi

if ! grep -Fq "observed.readyAfterStop" "$SMOKE_FILE"; then
  fail "artifact ok predicate does not require ready state after Stop"
fi

if ! grep -Fq "observed.composerRecoveredAfterStop" "$SMOKE_FILE"; then
  fail "artifact ok predicate does not require composer recovery after Stop"
fi

if ! grep -Fq "observed.recoveryPromptSubmitted" "$SMOKE_FILE"; then
  fail "artifact ok predicate does not require a recovery prompt submission"
fi

if ! grep -Fq "observed.recoveryMarkerSeen" "$SMOKE_FILE"; then
  fail "artifact ok predicate does not require the recovery prompt marker"
fi

if ! grep -Fq "observed.recoveryDoneObserved" "$SMOKE_FILE"; then
  fail "artifact ok predicate does not require ready state after recovery prompt"
fi

if ! grep -Fq "Gemini CLI recovery prompt visibly idle" "$SMOKE_FILE"; then
  fail "smoke does not prove the recovery prompt is visibly idle before accepting done-state"
fi

if ! grep -Fq "stopButtonVisible" "$SMOKE_FILE"; then
  fail "smoke can still accept recovery done-state while a Stop response button is visible"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi

echo "Gemini hosted smoke contract requires marker, stopped/done, and post-Stop recovery-prompt evidence."
