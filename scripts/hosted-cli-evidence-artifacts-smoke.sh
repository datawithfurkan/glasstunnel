#!/usr/bin/env bash
# Smoke-test the hosted CLI evidence artifact checker with temporary fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_artifact() {
  local file="$1"
  local visible_field="$2"
  local model_field="${3:-runtimeModelApplied}"
  local screenshot="${file%.json}.png"

  printf 'fixture screenshot\n' > "$TMP_DIR/$screenshot"

  cat > "$TMP_DIR/$file" <<JSON
{
  "ok": true,
  "marker": "GT_MARKER",
  "recoveryMarker": "GT_RECOVERY",
  "$visible_field": true,
  "started": true,
  "runtimeControlsVisible": true,
  "$model_field": true,
  "promptSubmitted": true,
  "workingObserved": true,
  "stopRequested": true,
  "doneOrStoppedObserved": true,
  "restartedAfterStop": true,
  "readyAfterStop": true,
  "composerRecoveredAfterStop": true,
  "runtimeModelRecoveredAfterStop": true,
  "recoveryPromptSubmitted": true,
  "recoveryMarkerSeen": true,
  "recoveryDoneObserved": true,
  "markerSeen": true,
  "screenshot": "/tmp/$screenshot"
}
JSON
}

write_artifact "codex-cli-hosted-chrome-stop-recovery-prompt-20260617-000001.json" "codexCliVisible" "runtimeModelApplied"
write_artifact "gemini-cli-hosted-chrome-stop-recovery-prompt-20260617-000001.json" "geminiCliVisible"
write_artifact "opencode-hosted-chrome-fixture-stop-recovery-prompt-20260617-000001.json" "opencodeVisible"

mkdir -p "$TMP_DIR/opencode-hosted-chrome-blocked-model-20260617-000001"
printf 'fixture screenshot\n' > "$TMP_DIR/opencode-hosted-chrome-blocked-model-20260617-000001/opencode-hosted-chrome-blocked-model-20260617-000001.png"
cat > "$TMP_DIR/opencode-hosted-chrome-blocked-model-20260617-000001/opencode-hosted-chrome-blocked-model-20260617-000001.json" <<'JSON'
{
  "ok": true,
  "opencodeVisible": true,
  "started": true,
  "runtimeControlsVisible": true,
  "runtimeAppliedModel": "opencode/gpt-5-nano",
  "runtimeModelApplied": true,
  "expectedModelBlocked": true,
  "expectedFailureDetails": [
    "Provider/model is not available for this account."
  ],
  "failureDetail": "Provider/model is not available for this account.",
  "failureDetailVisible": true,
  "genericFailureText": "OpenCode prompt failed with exit code",
  "genericFailureVisible": false,
  "promptSubmitted": true,
  "screenshot": "/tmp/opencode-hosted-chrome-blocked-model-20260617-000001.png"
}
JSON

mkdir -p "$TMP_DIR/opencode-hosted-chrome-session-switch-20260617-000001"
printf 'fixture screenshot\n' > "$TMP_DIR/opencode-hosted-chrome-session-switch-20260617-000001/opencode-hosted-chrome-session-switch-20260617-000001.png"
cat > "$TMP_DIR/opencode-hosted-chrome-session-switch-20260617-000001/opencode-hosted-chrome-session-switch-20260617-000001.json" <<'JSON'
{
  "ok": true,
  "opencodeVisible": true,
  "started": true,
  "runtimeControlsVisible": true,
  "runtimeAppliedModel": "opencode/test-model",
  "runtimeModelApplied": true,
  "sessionSwitchEnabled": true,
  "sessionTargetsVisible": true,
  "sessionSwitchRequested": true,
  "sessionSwitchSelected": true,
  "sessionSwitchHistoryVisible": true,
  "staleStartupStatusVisible": false,
  "sessionDefaultLabel": "Default session",
  "sessionSwitchLabel": "Second session",
  "sessionDefaultMarker": "GT_DEFAULT_MARKER",
  "sessionSwitchMarker": "GT_SWITCH_MARKER",
  "screenshot": "opencode-hosted-chrome-session-switch-20260617-000001.png"
}
JSON

GT_HOSTED_CLI_ARTIFACT_DIR="$TMP_DIR" bash "$ROOT_DIR/scripts/check-hosted-cli-evidence-artifacts.sh" >/dev/null

mkdir -p "$TMP_DIR/opencode-hosted-chrome-blocked-model-current-20260617-000002"
cp "$TMP_DIR/opencode-hosted-chrome-blocked-model-20260617-000001/opencode-hosted-chrome-blocked-model-20260617-000001.json" "$TMP_DIR/opencode-hosted-chrome-blocked-model-current-20260617-000002/opencode-hosted-chrome-2026-06-17T00-00-02-000Z.json"
printf 'fixture screenshot\n' > "$TMP_DIR/opencode-hosted-chrome-blocked-model-current-20260617-000002/opencode-hosted-chrome-2026-06-17T00-00-02-000Z.png"
perl -0pi -e 's/"genericFailureVisible": false/"genericFailureVisible": true/' "$TMP_DIR/opencode-hosted-chrome-blocked-model-current-20260617-000002/opencode-hosted-chrome-2026-06-17T00-00-02-000Z.json"

if GT_HOSTED_CLI_ARTIFACT_DIR="$TMP_DIR" bash "$ROOT_DIR/scripts/check-hosted-cli-evidence-artifacts.sh" >/dev/null 2>&1; then
  echo "Expected checker to select and reject the newest OpenCode current-style blocked-model artifact." >&2
  exit 1
fi

perl -0pi -e 's/"genericFailureVisible": true/"genericFailureVisible": false/' "$TMP_DIR/opencode-hosted-chrome-blocked-model-current-20260617-000002/opencode-hosted-chrome-2026-06-17T00-00-02-000Z.json"
GT_HOSTED_CLI_ARTIFACT_DIR="$TMP_DIR" bash "$ROOT_DIR/scripts/check-hosted-cli-evidence-artifacts.sh" >/dev/null

write_artifact "gemini-cli-hosted-chrome-stop-recovery-prompt-alpha-20260617-000002.json" "geminiCliVisible"
write_artifact "gemini-cli-hosted-chrome-stop-recovery-prompt-zstale-20260617-000001.json" "geminiCliVisible"
perl -0pi -e 's/"recoveryMarkerSeen": true/"recoveryMarkerSeen": false/' "$TMP_DIR/gemini-cli-hosted-chrome-stop-recovery-prompt-zstale-20260617-000001.json"

GT_HOSTED_CLI_ARTIFACT_DIR="$TMP_DIR" bash "$ROOT_DIR/scripts/check-hosted-cli-evidence-artifacts.sh" >/dev/null

perl -0pi -e 's/"recoveryMarkerSeen": true/"recoveryMarkerSeen": false/' "$TMP_DIR/opencode-hosted-chrome-fixture-stop-recovery-prompt-20260617-000001.json"

if GT_HOSTED_CLI_ARTIFACT_DIR="$TMP_DIR" bash "$ROOT_DIR/scripts/check-hosted-cli-evidence-artifacts.sh" >/dev/null 2>&1; then
  echo "Expected checker to reject missing OpenCode recovery marker evidence." >&2
  exit 1
fi

perl -0pi -e 's/"recoveryMarkerSeen": false/"recoveryMarkerSeen": true/' "$TMP_DIR/opencode-hosted-chrome-fixture-stop-recovery-prompt-20260617-000001.json"
rm "$TMP_DIR/opencode-hosted-chrome-fixture-stop-recovery-prompt-20260617-000001.png"

if GT_HOSTED_CLI_ARTIFACT_DIR="$TMP_DIR" bash "$ROOT_DIR/scripts/check-hosted-cli-evidence-artifacts.sh" >/dev/null 2>&1; then
  echo "Expected checker to reject missing OpenCode screenshot evidence." >&2
  exit 1
fi

printf 'fixture screenshot\n' > "$TMP_DIR/opencode-hosted-chrome-fixture-stop-recovery-prompt-20260617-000001.png"
perl -0pi -e 's/"genericFailureVisible": false/"genericFailureVisible": true/' "$TMP_DIR/opencode-hosted-chrome-blocked-model-current-20260617-000002/opencode-hosted-chrome-2026-06-17T00-00-02-000Z.json"

if GT_HOSTED_CLI_ARTIFACT_DIR="$TMP_DIR" bash "$ROOT_DIR/scripts/check-hosted-cli-evidence-artifacts.sh" >/dev/null 2>&1; then
  echo "Expected checker to reject visible OpenCode generic blocked-model failure text." >&2
  exit 1
fi

echo "Result: passed; hosted CLI evidence artifact checker rejects weak recovery, missing screenshots, and weak OpenCode blocked-model evidence."
