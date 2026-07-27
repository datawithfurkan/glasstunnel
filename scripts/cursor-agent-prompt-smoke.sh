#!/usr/bin/env bash
# Privacy-safe bounded prompt smoke for the standalone Cursor Agent CLI.
#
# This submits one tiny ask-mode prompt in a temporary workspace. It is intended
# to prove authenticated prompt execution for the Cursor Agent CLI path, not the
# desktop Cursor app adapter or mobile routing.
set -euo pipefail

AGENT_PATH="${GT_CURSOR_AGENT_PATH:-$HOME/.local/bin/cursor-agent}"
MODEL="${GT_CURSOR_AGENT_PROMPT_MODEL:-gpt-5.4-nano-none}"
MODE="${GT_CURSOR_AGENT_PROMPT_MODE:-ask}"
TIMEOUT_SECONDS="${GT_CURSOR_AGENT_PROMPT_TIMEOUT_SECONDS:-120}"
OUT_DIR="${GT_CURSOR_AGENT_PROMPT_OUT_DIR:-}"
KEEP_WORKSPACE="${GT_CURSOR_AGENT_PROMPT_KEEP_WORKSPACE:-0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor Agent prompt smoke requires macOS." >&2
  exit 1
fi

if [[ ! -x "$AGENT_PATH" ]]; then
  echo "Cursor Agent prompt smoke"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Cursor Agent executable: false"
  echo "Result: blocked; standalone cursor-agent executable is not available."
  exit 1
fi

case "$MODE" in
  ask|plan) ;;
  *)
    echo "Result: blocked; GT_CURSOR_AGENT_PROMPT_MODE must be ask or plan." >&2
    exit 1
    ;;
esac

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "Result: blocked; GT_CURSOR_AGENT_PROMPT_TIMEOUT_SECONDS must be numeric." >&2
    exit 1
    ;;
esac

tmp_root="$(mktemp -d -t glasstunnel-cursor-agent-prompt.XXXXXX)"
workspace="$tmp_root/workspace"
stdout_file="$tmp_root/stdout.txt"
stderr_file="$tmp_root/stderr.txt"
models_file="$tmp_root/models.txt"
mkdir -p "$workspace"

cleanup() {
  if [[ "$KEEP_WORKSPACE" != "1" ]]; then
    rm -rf "$tmp_root"
  else
    echo "Kept workspace: $tmp_root"
  fi
}
trap cleanup EXIT

set +e
"$AGENT_PATH" models >"$models_file" 2>&1
model_catalog_exit=$?
set -e

model_available="false"
if [[ "$model_catalog_exit" == "0" ]] && grep -Eq "^${MODEL//./\\.}[[:space:]]+-[[:space:]]+" "$models_file"; then
  model_available="true"
fi

if [[ "$model_available" != "true" ]]; then
  echo "Cursor Agent prompt smoke"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Model: $MODEL"
  echo "Model catalog exit: $model_catalog_exit"
  echo "Model available: false"
  echo "Prompt submitted: false"
  echo "Model call made: false"
  echo "Result: blocked; requested model is not available in Cursor Agent catalog."
  exit 1
fi

marker="GLASSTUNNEL_CURSOR_AGENT_PROMPT_SMOKE_$(date +%s)_$$"
prompt="Reply with exactly $marker and nothing else."

set +e
"$AGENT_PATH" \
  --print \
  --mode "$MODE" \
  --model "$MODEL" \
  --workspace "$workspace" \
  --trust \
  "$prompt" >"$stdout_file" 2>"$stderr_file" &
agent_pid=$!

timed_out="false"
exit_code=""
deadline=$((SECONDS + TIMEOUT_SECONDS))
while kill -0 "$agent_pid" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    timed_out="true"
    kill "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null
    exit_code="timeout"
    break
  fi
  sleep 1
done

if [[ -z "$exit_code" ]]; then
  wait "$agent_pid"
  exit_code="$?"
fi
set -e

marker_seen="false"
if grep -Fq "$marker" "$stdout_file"; then
  marker_seen="true"
fi

stdout_line_count="$(wc -l <"$stdout_file" | tr -d ' ')"
stderr_line_count="$(wc -l <"$stderr_file" | tr -d ' ')"
stdout_byte_count="$(wc -c <"$stdout_file" | tr -d ' ')"
stderr_byte_count="$(wc -c <"$stderr_file" | tr -d ' ')"
workspace_file_count="$(find "$workspace" -type f | wc -l | tr -d ' ')"

result="failed"
result_detail="Cursor Agent prompt did not return the expected marker."
if [[ "$timed_out" == "false" && "$exit_code" == "0" && "$marker_seen" == "true" ]]; then
  result="passed"
  result_detail="Cursor Agent returned the expected marker from a bounded ask-mode prompt."
elif [[ "$timed_out" == "true" ]]; then
  result_detail="Cursor Agent prompt timed out before returning."
elif [[ "$exit_code" != "0" ]]; then
  result_detail="Cursor Agent prompt exited non-zero before returning the expected marker."
fi

echo "Cursor Agent prompt smoke"
echo "Cursor Agent path: $AGENT_PATH"
echo "Model: $MODEL"
echo "Mode: $MODE"
echo "Workspace: temporary"
echo "Timeout seconds: $TIMEOUT_SECONDS"
echo "Model catalog exit: $model_catalog_exit"
echo "Model available: $model_available"
echo "Prompt submitted: true"
echo "Model call made: true"
echo "Exit: $exit_code"
echo "Timed out: $timed_out"
echo "Marker seen: $marker_seen"
echo "Stdout lines: $stdout_line_count"
echo "Stderr lines: $stderr_line_count"
echo "Workspace file count: $workspace_file_count"
echo "Raw prompt/response stored: false"
echo "Result: $result; $result_detail"

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  artifact="$OUT_DIR/cursor-agent-prompt-$(date -u +%Y-%m-%dT%H-%M-%SZ).json"
  export GT_CURSOR_AGENT_PROMPT_ARTIFACT="$artifact"
  export GT_CURSOR_AGENT_PROMPT_AGENT_PATH="$AGENT_PATH"
  export GT_CURSOR_AGENT_PROMPT_MODEL_USED="$MODEL"
  export GT_CURSOR_AGENT_PROMPT_MODE_USED="$MODE"
  export GT_CURSOR_AGENT_PROMPT_TIMEOUT="$TIMEOUT_SECONDS"
  export GT_CURSOR_AGENT_PROMPT_MODEL_CATALOG_EXIT="$model_catalog_exit"
  export GT_CURSOR_AGENT_PROMPT_MODEL_AVAILABLE="$model_available"
  export GT_CURSOR_AGENT_PROMPT_EXIT="$exit_code"
  export GT_CURSOR_AGENT_PROMPT_TIMED_OUT="$timed_out"
  export GT_CURSOR_AGENT_PROMPT_MARKER_SEEN="$marker_seen"
  export GT_CURSOR_AGENT_PROMPT_MARKER="$marker"
  export GT_CURSOR_AGENT_PROMPT_STDOUT_LINES="$stdout_line_count"
  export GT_CURSOR_AGENT_PROMPT_STDERR_LINES="$stderr_line_count"
  export GT_CURSOR_AGENT_PROMPT_STDOUT_BYTES="$stdout_byte_count"
  export GT_CURSOR_AGENT_PROMPT_STDERR_BYTES="$stderr_byte_count"
  export GT_CURSOR_AGENT_PROMPT_WORKSPACE_FILES="$workspace_file_count"
  export GT_CURSOR_AGENT_PROMPT_RESULT="$result"
  export GT_CURSOR_AGENT_PROMPT_RESULT_DETAIL="$result_detail"
  node <<'NODE'
const fs = require("fs");
const env = process.env;
const payload = {
  agentPath: env.GT_CURSOR_AGENT_PROMPT_AGENT_PATH,
  model: env.GT_CURSOR_AGENT_PROMPT_MODEL_USED,
  mode: env.GT_CURSOR_AGENT_PROMPT_MODE_USED,
  timeoutSeconds: Number(env.GT_CURSOR_AGENT_PROMPT_TIMEOUT),
  modelCatalogExit: env.GT_CURSOR_AGENT_PROMPT_MODEL_CATALOG_EXIT === "timeout"
    ? "timeout"
    : Number(env.GT_CURSOR_AGENT_PROMPT_MODEL_CATALOG_EXIT),
  modelAvailable: env.GT_CURSOR_AGENT_PROMPT_MODEL_AVAILABLE === "true",
  promptSubmitted: true,
  modelCallMade: true,
  exitCode: env.GT_CURSOR_AGENT_PROMPT_EXIT === "timeout"
    ? "timeout"
    : Number(env.GT_CURSOR_AGENT_PROMPT_EXIT),
  timedOut: env.GT_CURSOR_AGENT_PROMPT_TIMED_OUT === "true",
  marker: env.GT_CURSOR_AGENT_PROMPT_MARKER,
  markerSeen: env.GT_CURSOR_AGENT_PROMPT_MARKER_SEEN === "true",
  stdoutLineCount: Number(env.GT_CURSOR_AGENT_PROMPT_STDOUT_LINES),
  stderrLineCount: Number(env.GT_CURSOR_AGENT_PROMPT_STDERR_LINES),
  stdoutByteCount: Number(env.GT_CURSOR_AGENT_PROMPT_STDOUT_BYTES),
  stderrByteCount: Number(env.GT_CURSOR_AGENT_PROMPT_STDERR_BYTES),
  workspaceFileCount: Number(env.GT_CURSOR_AGENT_PROMPT_WORKSPACE_FILES),
  rawPromptResponseStored: false,
  result: env.GT_CURSOR_AGENT_PROMPT_RESULT,
  resultDetail: env.GT_CURSOR_AGENT_PROMPT_RESULT_DETAIL,
};
fs.writeFileSync(env.GT_CURSOR_AGENT_PROMPT_ARTIFACT, `${JSON.stringify(payload, null, 2)}\n`);
console.log(`Artifact: ${env.GT_CURSOR_AGENT_PROMPT_ARTIFACT}`);
NODE
fi

[[ "$result" == "passed" ]]
