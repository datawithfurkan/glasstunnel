#!/usr/bin/env bash
# Ensure the release goal-loop process log has a complete latest entry.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${GT_GOAL_LOOP_LOG:-$ROOT_DIR/docs/release-goal-loop-log.md}"
FAILURES=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/check-release-goal-loop-log.sh

Checks docs/release-goal-loop-log.md for the append-only structure that keeps
the public-release goal loop from repeating stale work.

Environment:
  GT_GOAL_LOOP_LOG  Override process log path.
  GT_GOAL_LOOP_REQUIRE_CI_RESULT
                    Set to 1 after a push/CI pass when the latest entry must
                    contain a resolved CI/deploy result instead of pending.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

fail() {
  echo "Goal-loop log check failed: $*" >&2
  FAILURES=$((FAILURES + 1))
}

if [[ ! -f "$LOG_FILE" ]]; then
  echo "Missing goal-loop process log: $LOG_FILE" >&2
  exit 1
fi

latest_entry="$(
  awk '
    /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
      if (entry != "") {
        latest = entry
      }
      entry = $0 "\n"
      next
    }
    entry != "" {
      entry = entry $0 "\n"
    }
    END {
      if (entry != "") {
        latest = entry
      }
      printf "%s", latest
    }
  ' "$LOG_FILE"
)"

if [[ -z "$latest_entry" ]]; then
  fail "no dated process-log entry found"
else
  for field in \
    "Start commit" \
    "Release gate" \
    "Why chosen" \
    "Files changed" \
    "Validation" \
    "Manual testing" \
    "Evidence recorded" \
    "Outcome" \
    "Uncertainty" \
    "Stale-loop risk" \
    "Next action" \
    "End commit" \
    "CI/deploy"; do
    if ! grep -Eq "^- $field: .+" <<<"$latest_entry"; then
      fail "latest entry is missing '- $field: ...'"
    fi
  done
fi

previous_entry_timestamp=""
while IFS= read -r entry_timestamp; do
  if [[ -n "$previous_entry_timestamp" && "$entry_timestamp" < "$previous_entry_timestamp" ]]; then
    fail "dated entries are not append-ordered: $entry_timestamp appears after $previous_entry_timestamp"
  fi
  previous_entry_timestamp="$entry_timestamp"
done < <(
  awk '
    /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
      print substr($0, 4, 16)
    }
  ' "$LOG_FILE"
)

if grep -Eq '^- Outcome: .*$' <<<"$latest_entry"; then
  outcome="$(grep -E '^- Outcome: ' <<<"$latest_entry" | tail -n1 | sed -E 's/^- Outcome: //')"
  case "$outcome" in
    passed|failed|narrowed|blocked|docs-only) ;;
    *)
      fail "latest entry has invalid outcome '$outcome'"
      ;;
  esac
fi

if [[ "${GT_GOAL_LOOP_REQUIRE_CI_RESULT:-0}" == "1" && -n "$latest_entry" ]]; then
  ci_deploy="$(grep -E '^- CI/deploy: ' <<<"$latest_entry" | tail -n1 | sed -E 's/^- CI\/deploy: //')"
  if [[ -z "$ci_deploy" || "$ci_deploy" =~ (^|[[:space:];,.])pending([[:space:];,.]|$) ]]; then
    fail "latest entry has unresolved CI/deploy result '$ci_deploy'"
  fi
fi

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi

echo "Goal-loop process log is structurally complete."
