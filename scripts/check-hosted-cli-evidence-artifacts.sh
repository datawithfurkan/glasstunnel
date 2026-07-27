#!/usr/bin/env bash
# Verify latest hosted CLI evidence artifacts prove marker, Stop, and recovery.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${GT_HOSTED_CLI_ARTIFACT_DIR:-$ROOT_DIR/.cache/glasstunnel-evidence/agent-apps/artifacts}"
FAILURES=0

fail() {
  echo "Hosted CLI evidence artifact check failed: $*" >&2
  FAILURES=$((FAILURES + 1))
}

latest_artifact() {
  local pattern="$1"
  local file
  local files=()
  local best_file=""
  local best_key=""
  local base
  local timestamp
  local candidate_key

  shopt -s nullglob
  for file in "$ARTIFACT_DIR"/$pattern; do
    files+=("$file")
  done
  shopt -u nullglob

  if [[ "${#files[@]}" -eq 0 ]]; then
    return 1
  fi

  for file in "${files[@]}"; do
    base="${file#$ARTIFACT_DIR/}"
    timestamp="00000000-000000"
    if [[ "$file" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
      timestamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}-${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
    fi
    if [[ "$file" =~ ([0-9]{8})-([0-9]{4})([0-9]{2})? ]]; then
      timestamp="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}${BASH_REMATCH[3]:-00}"
    fi
    candidate_key="$timestamp|$base"
    if [[ -z "$best_key" || "$candidate_key" > "$best_key" ]]; then
      best_key="$candidate_key"
      best_file="$file"
    fi
  done

  printf '%s\n' "$best_file"
}

check_json_fields() {
  local label="$1"
  local pattern="$2"
  shift 2
  local file

  if ! file="$(latest_artifact "$pattern")"; then
    fail "$label has no matching artifact in $ARTIFACT_DIR: $pattern"
    return
  fi

  if ! node - "$file" "$label" "$@" <<'NODE'
const fs = require("fs");
const path = require("path");

const [, , file, label, ...fields] = process.argv;
let data;

try {
  data = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  console.error(`${label}: cannot parse ${file}: ${error.message}`);
  process.exit(1);
}

const failures = [];

for (const field of fields) {
  if (data[field] !== true) {
    failures.push(`${field} is not true`);
  }
}

if (!data.marker || !data.recoveryMarker) {
  failures.push("marker and recoveryMarker must both be present");
} else if (data.marker === data.recoveryMarker) {
  failures.push("marker and recoveryMarker must be distinct");
}

if (!data.screenshot || typeof data.screenshot !== "string") {
  failures.push("screenshot path is missing");
} else {
  const artifactDir = path.dirname(file);
  const siblingWithSameName = path.join(artifactDir, path.basename(data.screenshot));
  const siblingWithJsonStem = path.join(
    artifactDir,
    `${path.basename(file, path.extname(file))}.png`,
  );
  const candidates = [
    path.isAbsolute(data.screenshot)
      ? data.screenshot
      : path.resolve(artifactDir, data.screenshot),
    siblingWithSameName,
    siblingWithJsonStem,
  ];
  const screenshotExists = candidates.some((candidate) => {
    try {
      const stat = fs.statSync(candidate);
      return stat.isFile() && stat.size > 0;
    } catch {
      return false;
    }
  });

  if (!screenshotExists) {
    failures.push(
      `screenshot artifact does not exist for ${data.screenshot}`,
    );
  }
}

if (failures.length > 0) {
  console.error(`${label}: ${file}`);
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  process.exit(1);
}

console.log(`${label}: ${file}`);
NODE
  then
    FAILURES=$((FAILURES + 1))
  fi
}

check_json_fields \
  "Codex CLI hosted Chrome" \
  "codex-cli-hosted-chrome-stop-recovery-prompt-*.json" \
  ok \
  codexCliVisible \
  started \
  runtimeControlsVisible \
  promptSubmitted \
  workingObserved \
  stopRequested \
  doneOrStoppedObserved \
  restartedAfterStop \
  composerRecoveredAfterStop \
  recoveryPromptSubmitted \
  recoveryMarkerSeen \
  recoveryDoneObserved \
  markerSeen

check_json_fields \
  "Gemini CLI hosted Chrome" \
  "gemini-cli-hosted-chrome-stop-recovery-prompt-*.json" \
  ok \
  geminiCliVisible \
  started \
  runtimeControlsVisible \
  runtimeModelApplied \
  promptSubmitted \
  workingObserved \
  stopRequested \
  doneOrStoppedObserved \
  readyAfterStop \
  composerRecoveredAfterStop \
  recoveryPromptSubmitted \
  recoveryMarkerSeen \
  recoveryDoneObserved \
  markerSeen

check_json_fields \
  "OpenCode hosted Chrome" \
  "opencode-hosted-chrome-*-stop-recovery-*.json" \
  ok \
  opencodeVisible \
  started \
  runtimeControlsVisible \
  runtimeModelApplied \
  promptSubmitted \
  workingObserved \
  stopRequested \
  doneOrStoppedObserved \
  composerRecoveredAfterStop \
  runtimeModelRecoveredAfterStop \
  recoveryPromptSubmitted \
  recoveryMarkerSeen \
  recoveryDoneObserved

check_opencode_blocked_model_artifact() {
  local file

  if ! file="$(latest_artifact "opencode-hosted-chrome-blocked-model-*/*.json")"; then
    fail "OpenCode hosted Chrome blocked-model has no matching artifact in $ARTIFACT_DIR"
    return
  fi

  if ! node - "$file" <<'NODE'
const fs = require("fs");
const path = require("path");

const [, , file] = process.argv;
let data;

try {
  data = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  console.error(`OpenCode hosted Chrome blocked-model: cannot parse ${file}: ${error.message}`);
  process.exit(1);
}

const failures = [];
const trueFields = [
  "ok",
  "opencodeVisible",
  "started",
  "runtimeControlsVisible",
  "runtimeModelApplied",
  "expectedModelBlocked",
  "promptSubmitted",
  "failureDetailVisible",
];

for (const field of trueFields) {
  if (data[field] !== true) {
    failures.push(`${field} is not true`);
  }
}

if (data.genericFailureVisible !== false) {
  failures.push("genericFailureVisible is not false");
}

if (typeof data.runtimeAppliedModel !== "string" || data.runtimeAppliedModel.trim() === "") {
  failures.push("runtimeAppliedModel is missing");
}

if (typeof data.failureDetail !== "string" || data.failureDetail.trim() === "") {
  failures.push("failureDetail is missing");
} else if (
  Array.isArray(data.expectedFailureDetails) &&
  data.expectedFailureDetails.length > 0 &&
  !data.expectedFailureDetails.includes(data.failureDetail)
) {
  failures.push("failureDetail is not one of expectedFailureDetails");
}

if (!data.screenshot || typeof data.screenshot !== "string") {
  failures.push("screenshot path is missing");
} else {
  const artifactDir = path.dirname(file);
  const siblingWithSameName = path.join(artifactDir, path.basename(data.screenshot));
  const siblingWithJsonStem = path.join(
    artifactDir,
    `${path.basename(file, path.extname(file))}.png`,
  );
  const candidates = [
    path.isAbsolute(data.screenshot)
      ? data.screenshot
      : path.resolve(artifactDir, data.screenshot),
    siblingWithSameName,
    siblingWithJsonStem,
  ];
  const screenshotExists = candidates.some((candidate) => {
    try {
      const stat = fs.statSync(candidate);
      return stat.isFile() && stat.size > 0;
    } catch {
      return false;
    }
  });

  if (!screenshotExists) {
    failures.push(`screenshot artifact does not exist for ${data.screenshot}`);
  }
}

if (failures.length > 0) {
  console.error(`OpenCode hosted Chrome blocked-model: ${file}`);
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  process.exit(1);
}

console.log(`OpenCode hosted Chrome blocked-model: ${file}`);
NODE
  then
    FAILURES=$((FAILURES + 1))
  fi
}

check_opencode_blocked_model_artifact

check_opencode_session_switch_artifact() {
  local file

  if ! file="$(latest_artifact "opencode-hosted-chrome-session-switch-*/*.json")"; then
    fail "OpenCode hosted Chrome session-switch has no matching artifact in $ARTIFACT_DIR"
    return
  fi

  if ! node - "$file" <<'NODE'
const fs = require("fs");
const path = require("path");

const [, , file] = process.argv;
let data;

try {
  data = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  console.error(`OpenCode hosted Chrome session-switch: cannot parse ${file}: ${error.message}`);
  process.exit(1);
}

const failures = [];
const trueFields = [
  "ok",
  "opencodeVisible",
  "started",
  "runtimeControlsVisible",
  "runtimeModelApplied",
  "sessionSwitchEnabled",
  "sessionTargetsVisible",
  "sessionSwitchRequested",
  "sessionSwitchSelected",
  "sessionSwitchHistoryVisible",
];

for (const field of trueFields) {
  if (data[field] !== true) {
    failures.push(`${field} is not true`);
  }
}

if (data.staleStartupStatusVisible !== false) {
  failures.push("staleStartupStatusVisible is not false");
}

if (typeof data.runtimeAppliedModel !== "string" || data.runtimeAppliedModel.trim() === "") {
  failures.push("runtimeAppliedModel is missing");
}

for (const field of ["sessionDefaultLabel", "sessionSwitchLabel", "sessionDefaultMarker", "sessionSwitchMarker"]) {
  if (typeof data[field] !== "string" || data[field].trim() === "") {
    failures.push(`${field} is missing`);
  }
}

if (data.sessionDefaultMarker && data.sessionSwitchMarker && data.sessionDefaultMarker === data.sessionSwitchMarker) {
  failures.push("sessionDefaultMarker and sessionSwitchMarker must be distinct");
}

if (!data.screenshot || typeof data.screenshot !== "string") {
  failures.push("screenshot path is missing");
} else {
  const artifactDir = path.dirname(file);
  const siblingWithSameName = path.join(artifactDir, path.basename(data.screenshot));
  const siblingWithJsonStem = path.join(
    artifactDir,
    `${path.basename(file, path.extname(file))}.png`,
  );
  const candidates = [
    path.isAbsolute(data.screenshot)
      ? data.screenshot
      : path.resolve(artifactDir, data.screenshot),
    siblingWithSameName,
    siblingWithJsonStem,
  ];
  const screenshotExists = candidates.some((candidate) => {
    try {
      const stat = fs.statSync(candidate);
      return stat.isFile() && stat.size > 0;
    } catch {
      return false;
    }
  });

  if (!screenshotExists) {
    failures.push(`screenshot artifact does not exist for ${data.screenshot}`);
  }
}

if (failures.length > 0) {
  console.error(`OpenCode hosted Chrome session-switch: ${file}`);
  for (const failure of failures) {
    console.error(`  - ${failure}`);
  }
  process.exit(1);
}

console.log(`OpenCode hosted Chrome session-switch: ${file}`);
NODE
  then
    FAILURES=$((FAILURES + 1))
  fi
}

check_opencode_session_switch_artifact

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi

echo "Hosted CLI evidence artifacts prove Stop, post-Stop recovery prompts, OpenCode blocked-model rendering, OpenCode session switching, stale-startup suppression, and durable screenshots."
