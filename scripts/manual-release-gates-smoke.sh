#!/usr/bin/env bash
# Smoke-test the aggregate manual release gate checker with fixture evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
MAC_DIR="$TMP_DIR/mac-app"
MOBILE_DIR="$TMP_DIR/mobile"
AGENT_DIR="$TMP_DIR/agent-apps"
ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$MAC_DIR" "$MOBILE_DIR" "$AGENT_DIR" "$ARTIFACT_DIR"
printf 'fixture\n' > "$ARTIFACT_DIR/evidence.txt"

if GT_MANUAL_RELEASE_REQUIRE_PHYSICAL=yes \
  bash "$ROOT_DIR/scripts/check-manual-release-gates.sh" >/tmp/manual-gates-invalid.out 2>/tmp/manual-gates-invalid.err; then
  echo "Expected an invalid physical-phone gate value to fail." >&2
  exit 1
fi

expect_failure() {
  local required_apps="${1:-Codex desktop}"

  if GT_MANUAL_RELEASE_REQUIRED_COMMIT="$COMMIT" \
    GT_MANUAL_RELEASE_REQUIRE_PHYSICAL=1 \
    GT_MAC_LIVE_EVIDENCE_DIR="$MAC_DIR" \
    GT_REAL_MOBILE_EVIDENCE_DIR="$MOBILE_DIR" \
    GT_AGENT_APP_EVIDENCE_DIR="$AGENT_DIR" \
    GT_MANUAL_REQUIRED_AGENT_APPS="$required_apps" \
    bash "$ROOT_DIR/scripts/check-manual-release-gates.sh" >/tmp/manual-gates-empty.out 2>/tmp/manual-gates-empty.err; then
    echo "Expected manual gate fixture to fail for required apps: $required_apps." >&2
    exit 1
  fi
}

write_mac_record() {
  local scope="$1"
  local file="$MAC_DIR/$scope-pass.md"

  cat > "$file" <<EOF
# Mac Live Evidence

- Scope: $scope
- Result: pass
- Glasstunnel commit: $COMMIT
- Artifact: $ARTIFACT_DIR/evidence.txt
- Privacy review: pass

## Passed

Verified $scope on the bundled app fixture.
EOF
}

write_mobile_record() {
  local browser="$1"
  local scope="$2"
  local browser_slug
  local file

  browser_slug="$(printf '%s' "$browser" | tr '[:upper:]' '[:lower:]')"
  file="$MOBILE_DIR/$browser_slug-$scope-pass.md"

  cat > "$file" <<EOF
# Real Mobile Evidence

- Browser: $browser
- Scope: $scope
- Result: pass
- Phone: iPhone physical fixture
- Phone OS: iOS 18 physical fixture
- Glasstunnel commit: $COMMIT
- Screenshot or recording: $ARTIFACT_DIR/evidence.txt
- Privacy review: pass

## Passed

Verified $browser $scope on a physical-phone fixture.
EOF
}

write_agent_record() {
  local app="$1"
  local slug="$2"
  local passed="$3"
  local file="$AGENT_DIR/$slug-pass.md"

  cat > "$file" <<EOF
# Agent App Release Evidence

- App: $app
- Result: pass
- Glasstunnel commit: $COMMIT
- Artifact: $ARTIFACT_DIR/evidence.txt
- Privacy review: pass

## Passed

$passed
EOF
}

expect_failure

write_mac_record "permission-onboarding"
write_mac_record "auth-relaunch"
write_mobile_record "Safari" "release-smoke"
write_mobile_record "Safari" "screen-sharing"
write_mobile_record "Chrome" "release-smoke"
write_mobile_record "Chrome" "screen-sharing"
write_agent_record "Codex desktop" "codex-desktop" "Verified Codex desktop labels, prompt delivery, and status updates."

expect_failure "Codex CLI"
write_agent_record "Codex CLI" "codex-cli-incomplete" "Started a Codex CLI session and delivered a prompt."
expect_failure "Codex CLI"
write_agent_record "Codex CLI" "codex-cli" "Started a Codex CLI session, delivered a prompt, interrupted it, saw done status, and changed model effort runtime settings."

expect_failure "Cursor"
write_agent_record "Cursor" "cursor-incomplete" "Cursor project context matched and prompt input appeared."
expect_failure "Cursor"
write_agent_record "Cursor" "cursor-missing-model" "Cursor project target matched, prompt input arrived, submit sent it, and foreground/background behavior stayed correct."
expect_failure "Cursor"
write_agent_record "Cursor" "cursor" "Cursor project target matched, prompt input arrived, submit sent it, foreground/background behavior stayed correct, and the visible Composer model/settings were recorded."

expect_failure "Terminal"
write_agent_record "Terminal" "terminal-incomplete" "Terminal command output streamed."
expect_failure "Terminal"
write_agent_record "Terminal" "terminal" "Terminal command delivery worked, output streamed, a long-running process was interrupted, and status recovered for the next command."

GT_MANUAL_RELEASE_REQUIRED_COMMIT="$COMMIT" \
  GT_MANUAL_RELEASE_REQUIRE_PHYSICAL=1 \
  GT_MAC_LIVE_EVIDENCE_DIR="$MAC_DIR" \
  GT_REAL_MOBILE_EVIDENCE_DIR="$MOBILE_DIR" \
  GT_AGENT_APP_EVIDENCE_DIR="$AGENT_DIR" \
  GT_MANUAL_REQUIRED_AGENT_APPS="Codex desktop|Codex CLI|Cursor|Terminal" \
  bash "$ROOT_DIR/scripts/check-manual-release-gates.sh"

OPTIONAL_MOBILE_DIR="$TMP_DIR/optional-mobile"
mkdir -p "$OPTIONAL_MOBILE_DIR"
GT_MANUAL_RELEASE_REQUIRED_COMMIT="$COMMIT" \
  GT_MAC_LIVE_EVIDENCE_DIR="$MAC_DIR" \
  GT_REAL_MOBILE_EVIDENCE_DIR="$OPTIONAL_MOBILE_DIR" \
  GT_AGENT_APP_EVIDENCE_DIR="$AGENT_DIR" \
  GT_MANUAL_REQUIRED_AGENT_APPS="Codex desktop|Codex CLI|Cursor|Terminal" \
  bash "$ROOT_DIR/scripts/check-manual-release-gates.sh"

echo "Manual release gate smoke passed."
