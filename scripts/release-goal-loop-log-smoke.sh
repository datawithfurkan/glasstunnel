#!/usr/bin/env bash
# Smoke-test the goal-loop process log checker with fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VALID_LOG="$TMP_DIR/release-goal-loop-log-valid.md"
MISSING_FIELD_LOG="$TMP_DIR/release-goal-loop-log-missing-field.md"
BAD_OUTCOME_LOG="$TMP_DIR/release-goal-loop-log-bad-outcome.md"
PENDING_CI_LOG="$TMP_DIR/release-goal-loop-log-pending-ci.md"
OUT_OF_ORDER_LOG="$TMP_DIR/release-goal-loop-log-out-of-order.md"

cat > "$VALID_LOG" <<'EOF'
# Release Goal Loop Log

## 2026-06-13 20:00 Europe/Berlin - Test entry

- Start commit: `abc1234`
- Release gate: test gate
- Why chosen: test reason
- Files changed: test files
- Validation: test validation
- Manual testing: none
- Evidence recorded: test evidence
- Outcome: passed
- Uncertainty: none
- Stale-loop risk: low
- Next action: continue
- End commit: `def5678`
- CI/deploy: green
EOF

GT_GOAL_LOOP_LOG="$VALID_LOG" \
bash "$ROOT_DIR/scripts/check-release-goal-loop-log.sh" >/tmp/glasstunnel-goal-loop-log-valid.log

cat > "$MISSING_FIELD_LOG" <<'EOF'
# Release Goal Loop Log

## 2026-06-13 20:00 Europe/Berlin - Test entry

- Start commit: `abc1234`
- Release gate: test gate
- Why chosen: test reason
- Files changed: test files
- Validation: test validation
- Manual testing: none
- Evidence recorded: test evidence
- Outcome: passed
- Uncertainty: none
- Stale-loop risk: low
- Next action: continue
- End commit: `def5678`
EOF

if GT_GOAL_LOOP_LOG="$MISSING_FIELD_LOG" \
  bash "$ROOT_DIR/scripts/check-release-goal-loop-log.sh" >/tmp/glasstunnel-goal-loop-log-missing.log 2>&1; then
  echo "Expected log missing CI/deploy field to fail." >&2
  exit 1
fi

cat > "$BAD_OUTCOME_LOG" <<'EOF'
# Release Goal Loop Log

## 2026-06-13 20:00 Europe/Berlin - Test entry

- Start commit: `abc1234`
- Release gate: test gate
- Why chosen: test reason
- Files changed: test files
- Validation: test validation
- Manual testing: none
- Evidence recorded: test evidence
- Outcome: maybe
- Uncertainty: none
- Stale-loop risk: low
- Next action: continue
- End commit: `def5678`
- CI/deploy: green
EOF

if GT_GOAL_LOOP_LOG="$BAD_OUTCOME_LOG" \
  bash "$ROOT_DIR/scripts/check-release-goal-loop-log.sh" >/tmp/glasstunnel-goal-loop-log-outcome.log 2>&1; then
  echo "Expected log with invalid outcome to fail." >&2
  exit 1
fi

cat > "$PENDING_CI_LOG" <<'EOF'
# Release Goal Loop Log

## 2026-06-13 20:00 Europe/Berlin - Test entry

- Start commit: `abc1234`
- Release gate: test gate
- Why chosen: test reason
- Files changed: test files
- Validation: test validation
- Manual testing: none
- Evidence recorded: test evidence
- Outcome: passed
- Uncertainty: none
- Stale-loop risk: low
- Next action: continue
- End commit: `def5678`
- CI/deploy: pending
EOF

GT_GOAL_LOOP_LOG="$PENDING_CI_LOG" \
bash "$ROOT_DIR/scripts/check-release-goal-loop-log.sh" >/tmp/glasstunnel-goal-loop-log-pending-default.log

if GT_GOAL_LOOP_LOG="$PENDING_CI_LOG" GT_GOAL_LOOP_REQUIRE_CI_RESULT=1 \
  bash "$ROOT_DIR/scripts/check-release-goal-loop-log.sh" >/tmp/glasstunnel-goal-loop-log-pending-strict.log 2>&1; then
  echo "Expected strict log check with pending CI/deploy to fail." >&2
  exit 1
fi

cat > "$OUT_OF_ORDER_LOG" <<'EOF'
# Release Goal Loop Log

## 2026-06-14 05:00 CEST - Newer entry inserted too early

- Start commit: `abc1234`
- Release gate: test gate
- Why chosen: test reason
- Files changed: test files
- Validation: test validation
- Manual testing: none
- Evidence recorded: test evidence
- Outcome: passed
- Uncertainty: none
- Stale-loop risk: low
- Next action: continue
- End commit: `def5678`
- CI/deploy: green

## 2026-06-14 04:00 CEST - Older entry after newer entry

- Start commit: `abc1234`
- Release gate: test gate
- Why chosen: test reason
- Files changed: test files
- Validation: test validation
- Manual testing: none
- Evidence recorded: test evidence
- Outcome: passed
- Uncertainty: none
- Stale-loop risk: low
- Next action: continue
- End commit: `def5678`
- CI/deploy: green
EOF

if GT_GOAL_LOOP_LOG="$OUT_OF_ORDER_LOG" \
  bash "$ROOT_DIR/scripts/check-release-goal-loop-log.sh" >/tmp/glasstunnel-goal-loop-log-order.log 2>&1; then
  echo "Expected out-of-order dated log entries to fail." >&2
  exit 1
fi

echo "Goal-loop process log smoke passed."
