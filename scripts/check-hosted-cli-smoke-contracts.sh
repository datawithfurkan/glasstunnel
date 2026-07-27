#!/usr/bin/env bash
# Guard hosted CLI smokes against overclaiming prompt/stop evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

fail() {
  echo "Hosted CLI smoke contract failed: $*" >&2
  FAILURES=$((FAILURES + 1))
}

check_smoke() {
  local label="$1"
  local file="$2"
  local requires_initial_marker="${3:-1}"

  if [[ ! -f "$file" ]]; then
    fail "$label smoke file is missing: $file"
    return
  fi

  if grep -Fq "observed.doneOrStoppedObserved || observed.markerSeen" "$file"; then
    fail "$label artifact ok predicate still accepts stop/done without proving the marker returned"
  fi

  if [[ "$requires_initial_marker" == "1" ]] && ! grep -Fq "observed.markerSeen &&" "$file"; then
    fail "$label artifact ok predicate does not require the prompt marker"
  fi

  if ! grep -Fq "observed.doneOrStoppedObserved" "$file"; then
    fail "$label artifact ok predicate does not require stopped/done recovery"
  fi

  if ! grep -Fq "observed.recoveryPromptSubmitted" "$file"; then
    fail "$label artifact ok predicate does not require a post-Stop recovery prompt submission"
  fi

  if ! grep -Fq "observed.recoveryMarkerSeen" "$file"; then
    fail "$label artifact ok predicate does not require the post-Stop recovery prompt marker"
  fi

  if ! grep -Fq "observed.recoveryDoneObserved" "$file"; then
    fail "$label artifact ok predicate does not require ready/done state after the recovery prompt"
  fi

  if [[ "$label" == "Codex CLI hosted Chrome" ]]; then
    if ! grep -Fq "Codex CLI controls enabled after recovery prompt" "$file"; then
      fail "$label does not wait for enabled runtime controls after the recovery prompt before changing model"
    fi

    if ! grep -Fq "select.disabled" "$file"; then
      fail "$label select helper can still dispatch changes against disabled runtime controls"
    fi

    if ! grep -Fq "Codex CLI recovery prompt visibly idle" "$file"; then
      fail "$label does not prove the recovery prompt is visibly idle before accepting done-state"
    fi

    if ! grep -Fq "stopButtonVisible" "$file"; then
      fail "$label recovery done-state can still pass while a Stop response button is visible"
    fi

    if ! grep -Fq "Codex CLI visibly idle before screenshot" "$file"; then
      fail "$label can still capture the final evidence screenshot while the CLI is visibly running"
    fi

    if ! grep -Fq "compactStatusText" "$file"; then
      fail "$label idle checks can miss letter-spaced RUNNING/WORKING status text"
    fi
  fi

  if [[ "$label" == "OpenCode hosted Chrome" ]]; then
    if ! grep -Fq "OpenCode recovery prompt visibly idle" "$file"; then
      fail "$label does not prove the recovery prompt is visibly idle before accepting done-state"
    fi

    if ! grep -Fq "stopButtonVisible" "$file"; then
      fail "$label recovery done-state can still pass while a Stop response button is visible"
    fi

    if ! grep -Fq "compactStatusText" "$file"; then
      fail "$label idle checks can miss letter-spaced RUNNING/WORKING status text"
    fi
  fi
}

check_smoke "Codex CLI hosted Chrome" "$ROOT_DIR/scripts/codex-cli-hosted-chrome-smoke.sh"
check_smoke "OpenCode hosted Chrome" "$ROOT_DIR/scripts/opencode-hosted-chrome-smoke.sh" 0

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi

echo "Hosted CLI smoke contracts require stopped/done and post-Stop recovery-prompt evidence."
