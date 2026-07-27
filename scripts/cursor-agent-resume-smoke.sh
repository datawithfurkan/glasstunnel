#!/usr/bin/env bash
# Privacy-safe bounded resume smoke for the standalone Cursor Agent CLI.
#
# This creates an empty Cursor Agent chat in a temporary workspace, sends one
# marker-only ask-mode prompt through that chat id, then sends a second prompt
# through the same chat id and verifies the previous marker is visible. It proves
# explicit chat-id continuation for the standalone Cursor Agent CLI path only.
set -euo pipefail

AGENT_PATH="${GT_CURSOR_AGENT_PATH:-$HOME/.local/bin/cursor-agent}"
MODEL="${GT_CURSOR_AGENT_RESUME_MODEL:-gpt-5.4-nano-none}"
MODE="${GT_CURSOR_AGENT_RESUME_MODE:-ask}"
TIMEOUT_SECONDS="${GT_CURSOR_AGENT_RESUME_TIMEOUT_SECONDS:-120}"
OUT_DIR="${GT_CURSOR_AGENT_RESUME_OUT_DIR:-}"
KEEP_WORKSPACE="${GT_CURSOR_AGENT_RESUME_KEEP_WORKSPACE:-0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor Agent resume smoke requires macOS." >&2
  exit 1
fi

if [[ ! -x "$AGENT_PATH" ]]; then
  echo "Cursor Agent resume smoke"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Cursor Agent executable: false"
  echo "Result: blocked; standalone cursor-agent executable is not available."
  exit 1
fi

case "$MODE" in
  ask|plan) ;;
  *)
    echo "Result: blocked; GT_CURSOR_AGENT_RESUME_MODE must be ask or plan." >&2
    exit 1
    ;;
esac

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "Result: blocked; GT_CURSOR_AGENT_RESUME_TIMEOUT_SECONDS must be numeric." >&2
    exit 1
    ;;
esac

tmp_root="$(mktemp -d -t glasstunnel-cursor-agent-resume.XXXXXX)"
workspace="$tmp_root/workspace"
stdout_first="$tmp_root/first-stdout.txt"
stderr_first="$tmp_root/first-stderr.txt"
stdout_second="$tmp_root/second-stdout.txt"
stderr_second="$tmp_root/second-stderr.txt"
models_file="$tmp_root/models.txt"
chat_file="$tmp_root/chat-id.txt"
mkdir -p "$workspace"

cleanup() {
  if [[ "$KEEP_WORKSPACE" != "1" ]]; then
    rm -rf "$tmp_root"
  else
    echo "Kept workspace: $tmp_root"
  fi
}
trap cleanup EXIT

run_with_timeout() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file" &
  local command_pid=$!
  local timed_out="false"
  local exit_code=""
  local deadline=$((SECONDS + TIMEOUT_SECONDS))

  while kill -0 "$command_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      timed_out="true"
      kill "$command_pid" 2>/dev/null || true
      wait "$command_pid" 2>/dev/null
      exit_code="timeout"
      break
    fi
    sleep 1
  done

  if [[ -z "$exit_code" ]]; then
    wait "$command_pid"
    exit_code="$?"
  fi
  set -e

  printf '%s %s\n' "$exit_code" "$timed_out"
}

set +e
"$AGENT_PATH" models >"$models_file" 2>&1
model_catalog_exit=$?
set -e

model_available="false"
if [[ "$model_catalog_exit" == "0" ]] && grep -Eq "^${MODEL//./\\.}[[:space:]]+-[[:space:]]+" "$models_file"; then
  model_available="true"
fi

if [[ "$model_available" != "true" ]]; then
  echo "Cursor Agent resume smoke"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Model: $MODEL"
  echo "Model catalog exit: $model_catalog_exit"
  echo "Model available: false"
  echo "Chat created: false"
  echo "Prompt submitted: false"
  echo "Model call made: false"
  echo "Resume attempted: false"
  echo "Result: blocked; requested model is not available in Cursor Agent catalog."
  exit 1
fi

create_result="$(run_with_timeout "$chat_file" "$tmp_root/create-stderr.txt" "$AGENT_PATH" create-chat --workspace "$workspace" --trust)"
create_exit="${create_result%% *}"
create_timed_out="${create_result##* }"
chat_id="$(tr -d '\r\n' <"$chat_file")"
chat_created="false"
if [[ "$create_timed_out" == "false" && "$create_exit" == "0" && "$chat_id" =~ ^[0-9a-fA-F-]{20,}$ ]]; then
  chat_created="true"
fi

if [[ "$chat_created" != "true" ]]; then
  echo "Cursor Agent resume smoke"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Model: $MODEL"
  echo "Model available: $model_available"
  echo "Chat created: false"
  echo "Create chat exit: $create_exit"
  echo "Create chat timed out: $create_timed_out"
  echo "Prompt submitted: false"
  echo "Model call made: false"
  echo "Resume attempted: false"
  echo "Result: blocked; Cursor Agent did not create a usable chat id."
  exit 1
fi

marker_one="GLASSTUNNEL_CURSOR_AGENT_RESUME_A_$(date +%s)_$$"
marker_two="GLASSTUNNEL_CURSOR_AGENT_RESUME_B_$(date +%s)_$$"
first_prompt="Store this private session token for the next turn: $marker_one. Reply exactly STORED and nothing else."
second_prompt="Reply exactly $marker_two followed by a space and the private session token from the previous turn. If there is no previous token in this chat, reply exactly NO_CONTEXT."

first_result="$(run_with_timeout "$stdout_first" "$stderr_first" "$AGENT_PATH" --print --mode "$MODE" --model "$MODEL" --workspace "$workspace" --trust --resume "$chat_id" "$first_prompt")"
first_exit="${first_result%% *}"
first_timed_out="${first_result##* }"

second_result="$(run_with_timeout "$stdout_second" "$stderr_second" "$AGENT_PATH" --print --mode "$MODE" --model "$MODEL" --workspace "$workspace" --trust --resume "$chat_id" "$second_prompt")"
second_exit="${second_result%% *}"
second_timed_out="${second_result##* }"

first_ack_seen="false"
if grep -Fq "STORED" "$stdout_first"; then
  first_ack_seen="true"
fi

first_marker_echoed="false"
if grep -Fq "$marker_one" "$stdout_first"; then
  first_marker_echoed="true"
fi

second_marker_one_seen="false"
if grep -Fq "$marker_one" "$stdout_second"; then
  second_marker_one_seen="true"
fi

second_marker_two_seen="false"
if grep -Fq "$marker_two" "$stdout_second"; then
  second_marker_two_seen="true"
fi

second_no_context="false"
if grep -Fq "NO_CONTEXT" "$stdout_second"; then
  second_no_context="true"
fi

first_stdout_line_count="$(wc -l <"$stdout_first" | tr -d ' ')"
second_stdout_line_count="$(wc -l <"$stdout_second" | tr -d ' ')"
first_stderr_line_count="$(wc -l <"$stderr_first" | tr -d ' ')"
second_stderr_line_count="$(wc -l <"$stderr_second" | tr -d ' ')"
first_stdout_byte_count="$(wc -c <"$stdout_first" | tr -d ' ')"
second_stdout_byte_count="$(wc -c <"$stdout_second" | tr -d ' ')"
first_stderr_byte_count="$(wc -c <"$stderr_first" | tr -d ' ')"
second_stderr_byte_count="$(wc -c <"$stderr_second" | tr -d ' ')"
workspace_file_count="$(find "$workspace" -type f | wc -l | tr -d ' ')"

resume_context_proved="false"
if [[ "$second_marker_one_seen" == "true" && "$second_marker_two_seen" == "true" && "$second_no_context" == "false" ]]; then
  resume_context_proved="true"
fi

result="failed"
result_detail="Cursor Agent resume did not return the expected continued-chat markers."
if [[ "$first_timed_out" == "false" && "$second_timed_out" == "false" && "$first_exit" == "0" && "$second_exit" == "0" && "$first_ack_seen" == "true" && "$resume_context_proved" == "true" ]]; then
  result="passed"
  result_detail="Cursor Agent explicit chat-id resume preserved context across two bounded ask-mode prompts."
elif [[ "$first_timed_out" == "true" || "$second_timed_out" == "true" ]]; then
  result_detail="Cursor Agent resume smoke timed out before both prompts returned."
elif [[ "$first_exit" != "0" || "$second_exit" != "0" ]]; then
  result_detail="Cursor Agent resume smoke exited non-zero before returning the expected markers."
elif [[ "$second_no_context" == "true" ]]; then
  result_detail="Cursor Agent returned NO_CONTEXT for the second prompt."
fi

echo "Cursor Agent resume smoke"
echo "Cursor Agent path: $AGENT_PATH"
echo "Model: $MODEL"
echo "Mode: $MODE"
echo "Workspace: temporary"
echo "Timeout seconds: $TIMEOUT_SECONDS"
echo "Model catalog exit: $model_catalog_exit"
echo "Model available: $model_available"
echo "Chat created: $chat_created"
echo "Prompt submitted: true"
echo "Model call made: true"
echo "Resume attempted: true"
echo "First exit: $first_exit"
echo "Second exit: $second_exit"
echo "First timed out: $first_timed_out"
echo "Second timed out: $second_timed_out"
echo "First ack seen: $first_ack_seen"
echo "First marker echoed: $first_marker_echoed"
echo "Second previous marker seen: $second_marker_one_seen"
echo "Second current marker seen: $second_marker_two_seen"
echo "Second no-context response: $second_no_context"
echo "Resume context proved: $resume_context_proved"
echo "First stdout lines: $first_stdout_line_count"
echo "Second stdout lines: $second_stdout_line_count"
echo "First stderr lines: $first_stderr_line_count"
echo "Second stderr lines: $second_stderr_line_count"
echo "Workspace file count: $workspace_file_count"
echo "Raw prompt/response stored: false"
echo "Result: $result; $result_detail"

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  artifact="$OUT_DIR/cursor-agent-resume-$(date -u +%Y-%m-%dT%H-%M-%SZ).json"
  export GT_CURSOR_AGENT_RESUME_ARTIFACT="$artifact"
  export GT_CURSOR_AGENT_RESUME_AGENT_PATH="$AGENT_PATH"
  export GT_CURSOR_AGENT_RESUME_MODEL_USED="$MODEL"
  export GT_CURSOR_AGENT_RESUME_MODE_USED="$MODE"
  export GT_CURSOR_AGENT_RESUME_TIMEOUT="$TIMEOUT_SECONDS"
  export GT_CURSOR_AGENT_RESUME_MODEL_CATALOG_EXIT="$model_catalog_exit"
  export GT_CURSOR_AGENT_RESUME_MODEL_AVAILABLE="$model_available"
  export GT_CURSOR_AGENT_RESUME_CHAT_CREATED="$chat_created"
  export GT_CURSOR_AGENT_RESUME_CREATE_EXIT="$create_exit"
  export GT_CURSOR_AGENT_RESUME_CREATE_TIMED_OUT="$create_timed_out"
  export GT_CURSOR_AGENT_RESUME_FIRST_EXIT="$first_exit"
  export GT_CURSOR_AGENT_RESUME_SECOND_EXIT="$second_exit"
  export GT_CURSOR_AGENT_RESUME_FIRST_TIMED_OUT="$first_timed_out"
  export GT_CURSOR_AGENT_RESUME_SECOND_TIMED_OUT="$second_timed_out"
  export GT_CURSOR_AGENT_RESUME_MARKER_ONE="$marker_one"
  export GT_CURSOR_AGENT_RESUME_MARKER_TWO="$marker_two"
  export GT_CURSOR_AGENT_RESUME_FIRST_ACK_SEEN="$first_ack_seen"
  export GT_CURSOR_AGENT_RESUME_FIRST_MARKER_ECHOED="$first_marker_echoed"
  export GT_CURSOR_AGENT_RESUME_SECOND_MARKER_ONE_SEEN="$second_marker_one_seen"
  export GT_CURSOR_AGENT_RESUME_SECOND_MARKER_TWO_SEEN="$second_marker_two_seen"
  export GT_CURSOR_AGENT_RESUME_SECOND_NO_CONTEXT="$second_no_context"
  export GT_CURSOR_AGENT_RESUME_CONTEXT_PROVED="$resume_context_proved"
  export GT_CURSOR_AGENT_RESUME_FIRST_STDOUT_LINES="$first_stdout_line_count"
  export GT_CURSOR_AGENT_RESUME_SECOND_STDOUT_LINES="$second_stdout_line_count"
  export GT_CURSOR_AGENT_RESUME_FIRST_STDERR_LINES="$first_stderr_line_count"
  export GT_CURSOR_AGENT_RESUME_SECOND_STDERR_LINES="$second_stderr_line_count"
  export GT_CURSOR_AGENT_RESUME_FIRST_STDOUT_BYTES="$first_stdout_byte_count"
  export GT_CURSOR_AGENT_RESUME_SECOND_STDOUT_BYTES="$second_stdout_byte_count"
  export GT_CURSOR_AGENT_RESUME_FIRST_STDERR_BYTES="$first_stderr_byte_count"
  export GT_CURSOR_AGENT_RESUME_SECOND_STDERR_BYTES="$second_stderr_byte_count"
  export GT_CURSOR_AGENT_RESUME_WORKSPACE_FILES="$workspace_file_count"
  export GT_CURSOR_AGENT_RESUME_RESULT="$result"
  export GT_CURSOR_AGENT_RESUME_RESULT_DETAIL="$result_detail"
  node <<'NODE'
const fs = require("fs");
const env = process.env;
const toExit = (value) => value === "timeout" ? "timeout" : Number(value);
const payload = {
  agentPath: env.GT_CURSOR_AGENT_RESUME_AGENT_PATH,
  model: env.GT_CURSOR_AGENT_RESUME_MODEL_USED,
  mode: env.GT_CURSOR_AGENT_RESUME_MODE_USED,
  timeoutSeconds: Number(env.GT_CURSOR_AGENT_RESUME_TIMEOUT),
  modelCatalogExit: toExit(env.GT_CURSOR_AGENT_RESUME_MODEL_CATALOG_EXIT),
  modelAvailable: env.GT_CURSOR_AGENT_RESUME_MODEL_AVAILABLE === "true",
  chatCreated: env.GT_CURSOR_AGENT_RESUME_CHAT_CREATED === "true",
  createChatExit: toExit(env.GT_CURSOR_AGENT_RESUME_CREATE_EXIT),
  createChatTimedOut: env.GT_CURSOR_AGENT_RESUME_CREATE_TIMED_OUT === "true",
  promptSubmitted: true,
  modelCallMade: true,
  resumeAttempted: true,
  firstExitCode: toExit(env.GT_CURSOR_AGENT_RESUME_FIRST_EXIT),
  secondExitCode: toExit(env.GT_CURSOR_AGENT_RESUME_SECOND_EXIT),
  firstTimedOut: env.GT_CURSOR_AGENT_RESUME_FIRST_TIMED_OUT === "true",
  secondTimedOut: env.GT_CURSOR_AGENT_RESUME_SECOND_TIMED_OUT === "true",
  markerOne: env.GT_CURSOR_AGENT_RESUME_MARKER_ONE,
  markerTwo: env.GT_CURSOR_AGENT_RESUME_MARKER_TWO,
  firstAckSeen: env.GT_CURSOR_AGENT_RESUME_FIRST_ACK_SEEN === "true",
  firstMarkerEchoed: env.GT_CURSOR_AGENT_RESUME_FIRST_MARKER_ECHOED === "true",
  previousMarkerRevealedInSecondPrompt: false,
  secondPreviousMarkerSeen: env.GT_CURSOR_AGENT_RESUME_SECOND_MARKER_ONE_SEEN === "true",
  secondCurrentMarkerSeen: env.GT_CURSOR_AGENT_RESUME_SECOND_MARKER_TWO_SEEN === "true",
  secondNoContext: env.GT_CURSOR_AGENT_RESUME_SECOND_NO_CONTEXT === "true",
  resumeContextProved: env.GT_CURSOR_AGENT_RESUME_CONTEXT_PROVED === "true",
  firstStdoutLineCount: Number(env.GT_CURSOR_AGENT_RESUME_FIRST_STDOUT_LINES),
  secondStdoutLineCount: Number(env.GT_CURSOR_AGENT_RESUME_SECOND_STDOUT_LINES),
  firstStderrLineCount: Number(env.GT_CURSOR_AGENT_RESUME_FIRST_STDERR_LINES),
  secondStderrLineCount: Number(env.GT_CURSOR_AGENT_RESUME_SECOND_STDERR_LINES),
  firstStdoutByteCount: Number(env.GT_CURSOR_AGENT_RESUME_FIRST_STDOUT_BYTES),
  secondStdoutByteCount: Number(env.GT_CURSOR_AGENT_RESUME_SECOND_STDOUT_BYTES),
  firstStderrByteCount: Number(env.GT_CURSOR_AGENT_RESUME_FIRST_STDERR_BYTES),
  secondStderrByteCount: Number(env.GT_CURSOR_AGENT_RESUME_SECOND_STDERR_BYTES),
  workspaceFileCount: Number(env.GT_CURSOR_AGENT_RESUME_WORKSPACE_FILES),
  rawPromptResponseStored: false,
  result: env.GT_CURSOR_AGENT_RESUME_RESULT,
  resultDetail: env.GT_CURSOR_AGENT_RESUME_RESULT_DETAIL,
};
fs.writeFileSync(env.GT_CURSOR_AGENT_RESUME_ARTIFACT, `${JSON.stringify(payload, null, 2)}\n`);
console.log(`Artifact: ${env.GT_CURSOR_AGENT_RESUME_ARTIFACT}`);
NODE
fi

[[ "$result" == "passed" ]]
