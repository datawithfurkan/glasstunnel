#!/usr/bin/env bash
# Privacy-safe bounded edit probe for the standalone Cursor Agent CLI.
#
# This runs Cursor Agent in a disposable workspace with one seeded file and
# verifies whether the default print-mode agent can edit that exact file. It
# proves local CLI edit/tool behavior only, not mobile routing or desktop Cursor
# app target routing.
set -euo pipefail

AGENT_PATH="${GT_CURSOR_AGENT_PATH:-$HOME/.local/bin/cursor-agent}"
MODEL="${GT_CURSOR_AGENT_EDIT_MODEL:-gpt-5.4-nano-none}"
TIMEOUT_SECONDS="${GT_CURSOR_AGENT_EDIT_TIMEOUT_SECONDS:-180}"
OUT_DIR="${GT_CURSOR_AGENT_EDIT_OUT_DIR:-}"
KEEP_WORKSPACE="${GT_CURSOR_AGENT_EDIT_KEEP_WORKSPACE:-0}"
FORCE_ENABLED="${GT_CURSOR_AGENT_EDIT_FORCE:-0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor Agent edit probe requires macOS." >&2
  exit 1
fi

if [[ ! -x "$AGENT_PATH" ]]; then
  echo "Cursor Agent edit probe"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Cursor Agent executable: false"
  echo "Result: blocked; standalone cursor-agent executable is not available."
  exit 1
fi

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "Result: blocked; GT_CURSOR_AGENT_EDIT_TIMEOUT_SECONDS must be numeric." >&2
    exit 1
    ;;
esac

case "$FORCE_ENABLED" in
  0|1) ;;
  *)
    echo "Result: blocked; GT_CURSOR_AGENT_EDIT_FORCE must be 0 or 1." >&2
    exit 1
    ;;
esac

tmp_root="$(mktemp -d -t glasstunnel-cursor-agent-edit.XXXXXX)"
workspace="$tmp_root/workspace"
stdout_file="$tmp_root/stdout.txt"
stderr_file="$tmp_root/stderr.txt"
models_file="$tmp_root/models.txt"
probe_file="$workspace/GT_CURSOR_AGENT_EDIT_PROBE.txt"
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
  echo "Cursor Agent edit probe"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Model: $MODEL"
  echo "Model catalog exit: $model_catalog_exit"
  echo "Model available: false"
  echo "Prompt submitted: false"
  echo "Model call made: false"
  echo "Result: blocked; requested model is not available in Cursor Agent catalog."
  exit 1
fi

marker="GLASSTUNNEL_CURSOR_AGENT_EDIT_$(date +%s)_$$"
printf 'before\n' >"$probe_file"
prompt="In this workspace, edit the file GT_CURSOR_AGENT_EDIT_PROBE.txt so its entire content is exactly $marker followed by one newline. Do not create, rename, or delete any other file. After editing, reply with exactly EDIT_DONE."

command=(
  "$AGENT_PATH"
  --print
  --model "$MODEL"
  --workspace "$workspace"
  --trust
)
if [[ "$FORCE_ENABLED" == "1" ]]; then
  command+=(--force)
fi
command+=("$prompt")

set +e
"${command[@]}" >"$stdout_file" 2>"$stderr_file" &
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

file_exists="false"
file_marker_only="false"
file_final_newline="false"
file_content_bytes="0"
if [[ -f "$probe_file" ]]; then
  file_exists="true"
  file_content_bytes="$(wc -c <"$probe_file" | tr -d ' ')"
  expected_with_newline="$tmp_root/expected-with-newline.txt"
  expected_without_newline="$tmp_root/expected-without-newline.txt"
  printf '%s\n' "$marker" >"$expected_with_newline"
  printf '%s' "$marker" >"$expected_without_newline"
  if cmp -s "$probe_file" "$expected_with_newline"; then
    file_marker_only="true"
    file_final_newline="true"
  elif cmp -s "$probe_file" "$expected_without_newline"; then
    file_marker_only="true"
  fi
fi

edit_ack_seen="false"
if grep -Fq "EDIT_DONE" "$stdout_file"; then
  edit_ack_seen="true"
fi

stdout_line_count="$(wc -l <"$stdout_file" | tr -d ' ')"
stderr_line_count="$(wc -l <"$stderr_file" | tr -d ' ')"
stdout_byte_count="$(wc -c <"$stdout_file" | tr -d ' ')"
stderr_byte_count="$(wc -c <"$stderr_file" | tr -d ' ')"
workspace_file_count="$(find "$workspace" -type f | wc -l | tr -d ' ')"
extra_file_count="0"
if [[ "$workspace_file_count" =~ ^[0-9]+$ && "$workspace_file_count" -gt 1 ]]; then
  extra_file_count="$((workspace_file_count - 1))"
fi

result="failed"
result_detail="Cursor Agent did not prove bounded file editing."
if [[ "$timed_out" == "false" && "$exit_code" == "0" && "$file_marker_only" == "true" && "$workspace_file_count" == "1" ]]; then
  result="passed"
  result_detail="Cursor Agent edited the seeded file exactly in a disposable workspace."
elif [[ "$timed_out" == "true" ]]; then
  result_detail="Cursor Agent edit probe timed out before returning."
elif [[ "$exit_code" != "0" ]]; then
  result_detail="Cursor Agent edit probe exited non-zero."
elif [[ "$file_marker_only" != "true" ]]; then
  result_detail="Cursor Agent returned without making the expected exact file edit."
elif [[ "$workspace_file_count" != "1" ]]; then
  result_detail="Cursor Agent made the target edit but also changed workspace file count."
fi

echo "Cursor Agent edit probe"
echo "Cursor Agent path: $AGENT_PATH"
echo "Model: $MODEL"
echo "Mode: default print mode"
echo "Workspace: temporary"
echo "Timeout seconds: $TIMEOUT_SECONDS"
echo "Force enabled: $FORCE_ENABLED"
echo "Model catalog exit: $model_catalog_exit"
echo "Model available: $model_available"
echo "Prompt submitted: true"
echo "Model call made: true"
echo "Exit: $exit_code"
echo "Timed out: $timed_out"
echo "File exists: $file_exists"
echo "File marker only: $file_marker_only"
echo "File final newline: $file_final_newline"
echo "Edit ack seen: $edit_ack_seen"
echo "Workspace file count: $workspace_file_count"
echo "Extra file count: $extra_file_count"
echo "Stdout lines: $stdout_line_count"
echo "Stderr lines: $stderr_line_count"
echo "Raw prompt/response stored: false"
echo "Result: $result; $result_detail"

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  artifact="$OUT_DIR/cursor-agent-edit-$(date -u +%Y-%m-%dT%H-%M-%SZ).json"
  export GT_CURSOR_AGENT_EDIT_ARTIFACT="$artifact"
  export GT_CURSOR_AGENT_EDIT_AGENT_PATH="$AGENT_PATH"
  export GT_CURSOR_AGENT_EDIT_MODEL_USED="$MODEL"
  export GT_CURSOR_AGENT_EDIT_TIMEOUT="$TIMEOUT_SECONDS"
  export GT_CURSOR_AGENT_EDIT_FORCE_USED="$FORCE_ENABLED"
  export GT_CURSOR_AGENT_EDIT_MODEL_CATALOG_EXIT="$model_catalog_exit"
  export GT_CURSOR_AGENT_EDIT_MODEL_AVAILABLE="$model_available"
  export GT_CURSOR_AGENT_EDIT_EXIT="$exit_code"
  export GT_CURSOR_AGENT_EDIT_TIMED_OUT="$timed_out"
  export GT_CURSOR_AGENT_EDIT_MARKER="$marker"
  export GT_CURSOR_AGENT_EDIT_FILE_EXISTS="$file_exists"
  export GT_CURSOR_AGENT_EDIT_FILE_MARKER_ONLY="$file_marker_only"
  export GT_CURSOR_AGENT_EDIT_FILE_FINAL_NEWLINE="$file_final_newline"
  export GT_CURSOR_AGENT_EDIT_FILE_BYTES="$file_content_bytes"
  export GT_CURSOR_AGENT_EDIT_ACK_SEEN="$edit_ack_seen"
  export GT_CURSOR_AGENT_EDIT_WORKSPACE_FILES="$workspace_file_count"
  export GT_CURSOR_AGENT_EDIT_EXTRA_FILES="$extra_file_count"
  export GT_CURSOR_AGENT_EDIT_STDOUT_LINES="$stdout_line_count"
  export GT_CURSOR_AGENT_EDIT_STDERR_LINES="$stderr_line_count"
  export GT_CURSOR_AGENT_EDIT_STDOUT_BYTES="$stdout_byte_count"
  export GT_CURSOR_AGENT_EDIT_STDERR_BYTES="$stderr_byte_count"
  export GT_CURSOR_AGENT_EDIT_RESULT="$result"
  export GT_CURSOR_AGENT_EDIT_RESULT_DETAIL="$result_detail"
  node <<'NODE'
const fs = require("fs");
const env = process.env;
const toExit = (value) => value === "timeout" ? "timeout" : Number(value);
const payload = {
  agentPath: env.GT_CURSOR_AGENT_EDIT_AGENT_PATH,
  model: env.GT_CURSOR_AGENT_EDIT_MODEL_USED,
  mode: "default-print",
  timeoutSeconds: Number(env.GT_CURSOR_AGENT_EDIT_TIMEOUT),
  forceEnabled: env.GT_CURSOR_AGENT_EDIT_FORCE_USED === "1",
  modelCatalogExit: toExit(env.GT_CURSOR_AGENT_EDIT_MODEL_CATALOG_EXIT),
  modelAvailable: env.GT_CURSOR_AGENT_EDIT_MODEL_AVAILABLE === "true",
  promptSubmitted: true,
  modelCallMade: true,
  exitCode: toExit(env.GT_CURSOR_AGENT_EDIT_EXIT),
  timedOut: env.GT_CURSOR_AGENT_EDIT_TIMED_OUT === "true",
  marker: env.GT_CURSOR_AGENT_EDIT_MARKER,
  fileExists: env.GT_CURSOR_AGENT_EDIT_FILE_EXISTS === "true",
  fileMarkerOnly: env.GT_CURSOR_AGENT_EDIT_FILE_MARKER_ONLY === "true",
  fileFinalNewline: env.GT_CURSOR_AGENT_EDIT_FILE_FINAL_NEWLINE === "true",
  fileContentBytes: Number(env.GT_CURSOR_AGENT_EDIT_FILE_BYTES),
  editAckSeen: env.GT_CURSOR_AGENT_EDIT_ACK_SEEN === "true",
  workspaceFileCount: Number(env.GT_CURSOR_AGENT_EDIT_WORKSPACE_FILES),
  extraFileCount: Number(env.GT_CURSOR_AGENT_EDIT_EXTRA_FILES),
  stdoutLineCount: Number(env.GT_CURSOR_AGENT_EDIT_STDOUT_LINES),
  stderrLineCount: Number(env.GT_CURSOR_AGENT_EDIT_STDERR_LINES),
  stdoutByteCount: Number(env.GT_CURSOR_AGENT_EDIT_STDOUT_BYTES),
  stderrByteCount: Number(env.GT_CURSOR_AGENT_EDIT_STDERR_BYTES),
  rawPromptResponseStored: false,
  result: env.GT_CURSOR_AGENT_EDIT_RESULT,
  resultDetail: env.GT_CURSOR_AGENT_EDIT_RESULT_DETAIL,
};
fs.writeFileSync(env.GT_CURSOR_AGENT_EDIT_ARTIFACT, `${JSON.stringify(payload, null, 2)}\n`);
console.log(`Artifact: ${env.GT_CURSOR_AGENT_EDIT_ARTIFACT}`);
NODE
fi

[[ "$result" == "passed" ]]
