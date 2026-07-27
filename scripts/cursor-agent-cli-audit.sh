#!/usr/bin/env bash
# Privacy-safe audit of Cursor terminal/agent CLI surfaces.
#
# This checks only installed executable/help and bundled extension metadata. It
# does not open Cursor, submit prompts, install tools, or call Cursor models.
set -euo pipefail

APP_PATH="${GT_CURSOR_APP_PATH:-/Applications/Cursor.app}"
OUT_DIR="${GT_CURSOR_AGENT_CLI_OUT_DIR:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor agent CLI audit requires macOS." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Cursor agent CLI audit"
  echo "Cursor app path: $APP_PATH"
  echo "App installed: no"
  echo "Result: blocked; Cursor.app is not installed at the configured path."
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
CLI_PATH="$APP_PATH/Contents/Resources/app/bin/cursor"
AGENT_EXEC_PACKAGE="$APP_PATH/Contents/Resources/app/extensions/cursor-agent-exec/package.json"
AGENT_WORKER_PACKAGE="$APP_PATH/Contents/Resources/app/extensions/cursor-agent-worker/package.json"
LOCAL_AGENT_PATH="$HOME/.local/bin/cursor-agent"

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
cursor_on_path="$(command -v cursor 2>/dev/null || true)"
cursor_agent_on_path="$(command -v cursor-agent 2>/dev/null || true)"

local_agent_present="false"
local_agent_executable="false"
path_agent_present="false"
path_agent_executable="false"
bundled_cli_agent_help="false"
agent_exec_extension_present="false"
agent_worker_extension_present="false"
agent_exec_description=""
agent_worker_description=""
standalone_agent_help_reports="false"
standalone_agent_help_exit_code=""
standalone_agent_help_timed_out="false"

help_file="$(mktemp -t glasstunnel-cursor-agent-help.XXXXXX)"
cursor_help_file="$(mktemp -t glasstunnel-cursor-main-help.XXXXXX)"
cleanup() {
  rm -f "$help_file" "$cursor_help_file"
}
trap cleanup EXIT

if [[ -e "$LOCAL_AGENT_PATH" ]]; then
  local_agent_present="true"
  [[ -x "$LOCAL_AGENT_PATH" ]] && local_agent_executable="true"
fi

if [[ -n "$cursor_agent_on_path" ]]; then
  path_agent_present="true"
  [[ -x "$cursor_agent_on_path" ]] && path_agent_executable="true"
fi

if [[ -x "$CLI_PATH" ]]; then
  "$CLI_PATH" --help >"$cursor_help_file" 2>&1 || true
  if grep -Eq '(^|[[:space:]])agent([[:space:]]|$)|cursor-agent' "$cursor_help_file"; then
    bundled_cli_agent_help="true"
  fi
fi

read_package_field() {
  local package_file="$1"
  local field="$2"
  node - "$package_file" "$field" <<'NODE'
const fs = require("fs");
const [file, field] = process.argv.slice(2);
try {
  const value = JSON.parse(fs.readFileSync(file, "utf8"))[field];
  if (typeof value === "string") console.log(value.replace(/\s+/g, " ").trim());
} catch {}
NODE
}

if [[ -f "$AGENT_EXEC_PACKAGE" ]]; then
  agent_exec_extension_present="true"
  agent_exec_description="$(read_package_field "$AGENT_EXEC_PACKAGE" description)"
fi

if [[ -f "$AGENT_WORKER_PACKAGE" ]]; then
  agent_worker_extension_present="true"
  agent_worker_description="$(read_package_field "$AGENT_WORKER_PACKAGE" description)"
fi

agent_help_candidate=""
if [[ "$local_agent_executable" == "true" ]]; then
  agent_help_candidate="$LOCAL_AGENT_PATH"
elif [[ "$path_agent_executable" == "true" ]]; then
  agent_help_candidate="$cursor_agent_on_path"
fi

if [[ -n "$agent_help_candidate" ]]; then
  "$agent_help_candidate" --help >"$help_file" 2>&1 &
  help_pid=$!
  for _ in {1..50}; do
    if ! kill -0 "$help_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$help_pid" 2>/dev/null; then
    standalone_agent_help_timed_out="true"
    kill "$help_pid" 2>/dev/null || true
    wait "$help_pid" 2>/dev/null || true
    standalone_agent_help_exit_code="timeout"
  else
    if wait "$help_pid"; then
      standalone_agent_help_exit_code="0"
    else
      standalone_agent_help_exit_code="$?"
    fi
  fi
  if grep -Eq 'Usage|Commands|Options|agent' "$help_file"; then
    standalone_agent_help_reports="true"
  fi
fi

result="partial"
result_detail="Cursor bundles agent extensions, but a standalone cursor-agent CLI is not verified unless an executable help surface is present."
if [[ "$local_agent_executable" == "true" || "$path_agent_executable" == "true" ]]; then
  if [[ "$standalone_agent_help_reports" == "true" && "$standalone_agent_help_timed_out" == "false" ]]; then
    result="passed"
    result_detail="Standalone cursor-agent help is verified. No prompt was submitted and no Cursor model call was made."
  fi
fi

echo "Cursor agent CLI audit"
echo "Cursor app path: $APP_PATH"
echo "Bundle id: ${app_bundle_id:-unknown}"
echo "Version: ${app_version:-unknown}"
echo "cursor on PATH: ${cursor_on_path:-not found}"
echo "Bundled Cursor CLI: $CLI_PATH"
echo "Bundled Cursor CLI advertises agent command: $bundled_cli_agent_help"
echo "Local cursor-agent path: $LOCAL_AGENT_PATH"
echo "Local cursor-agent present: $local_agent_present"
echo "Local cursor-agent executable: $local_agent_executable"
echo "cursor-agent on PATH: ${cursor_agent_on_path:-not found}"
echo "PATH cursor-agent executable: $path_agent_executable"
echo "Standalone cursor-agent help reports: $standalone_agent_help_reports"
echo "Standalone cursor-agent help exit: ${standalone_agent_help_exit_code:-not run}"
echo "Standalone cursor-agent help timed out: $standalone_agent_help_timed_out"
echo "Bundled cursor-agent-exec extension present: $agent_exec_extension_present"
echo "Bundled cursor-agent-worker extension present: $agent_worker_extension_present"
echo "cursor-agent-exec description: ${agent_exec_description:-none}"
echo "cursor-agent-worker description: ${agent_worker_description:-none}"
echo "Note: invoking 'cursor agent' can bootstrap/install the standalone cursor-agent; this audit does not run that command."
echo "Result: $result; $result_detail"

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  artifact="$OUT_DIR/cursor-agent-cli-$(date -u +%Y-%m-%dT%H-%M-%SZ).json"
  export GT_AUDIT_CURSOR_APP_PATH="$APP_PATH"
  export GT_AUDIT_CURSOR_BUNDLE_ID="$app_bundle_id"
  export GT_AUDIT_CURSOR_VERSION="$app_version"
  export GT_AUDIT_CURSOR_ON_PATH="$cursor_on_path"
  export GT_AUDIT_CURSOR_CLI_PATH="$CLI_PATH"
  export GT_AUDIT_CURSOR_CLI_AGENT_HELP="$bundled_cli_agent_help"
  export GT_AUDIT_CURSOR_LOCAL_AGENT_PATH="$LOCAL_AGENT_PATH"
  export GT_AUDIT_CURSOR_LOCAL_AGENT_PRESENT="$local_agent_present"
  export GT_AUDIT_CURSOR_LOCAL_AGENT_EXECUTABLE="$local_agent_executable"
  export GT_AUDIT_CURSOR_AGENT_ON_PATH="$cursor_agent_on_path"
  export GT_AUDIT_CURSOR_PATH_AGENT_PRESENT="$path_agent_present"
  export GT_AUDIT_CURSOR_PATH_AGENT_EXECUTABLE="$path_agent_executable"
  export GT_AUDIT_CURSOR_STANDALONE_AGENT_HELP="$standalone_agent_help_reports"
  export GT_AUDIT_CURSOR_STANDALONE_AGENT_HELP_EXIT="$standalone_agent_help_exit_code"
  export GT_AUDIT_CURSOR_STANDALONE_AGENT_HELP_TIMEOUT="$standalone_agent_help_timed_out"
  export GT_AUDIT_CURSOR_AGENT_EXEC_EXTENSION="$agent_exec_extension_present"
  export GT_AUDIT_CURSOR_AGENT_WORKER_EXTENSION="$agent_worker_extension_present"
  export GT_AUDIT_CURSOR_AGENT_EXEC_DESCRIPTION="$agent_exec_description"
  export GT_AUDIT_CURSOR_AGENT_WORKER_DESCRIPTION="$agent_worker_description"
  export GT_AUDIT_CURSOR_RESULT="$result"
  export GT_AUDIT_CURSOR_RESULT_DETAIL="$result_detail"
  node - "$artifact" <<'NODE'
const fs = require("fs");
const artifact = process.argv[2];
const env = process.env;
const payload = {
  appPath: env.GT_AUDIT_CURSOR_APP_PATH,
  bundleId: env.GT_AUDIT_CURSOR_BUNDLE_ID,
  version: env.GT_AUDIT_CURSOR_VERSION,
  cursorOnPath: env.GT_AUDIT_CURSOR_ON_PATH || null,
  bundledCliPath: env.GT_AUDIT_CURSOR_CLI_PATH,
  bundledCliAdvertisesAgentCommand: env.GT_AUDIT_CURSOR_CLI_AGENT_HELP === "true",
  localAgentPath: env.GT_AUDIT_CURSOR_LOCAL_AGENT_PATH,
  localAgentPresent: env.GT_AUDIT_CURSOR_LOCAL_AGENT_PRESENT === "true",
  localAgentExecutable: env.GT_AUDIT_CURSOR_LOCAL_AGENT_EXECUTABLE === "true",
  cursorAgentOnPath: env.GT_AUDIT_CURSOR_AGENT_ON_PATH || null,
  pathAgentPresent: env.GT_AUDIT_CURSOR_PATH_AGENT_PRESENT === "true",
  pathAgentExecutable: env.GT_AUDIT_CURSOR_PATH_AGENT_EXECUTABLE === "true",
  standaloneAgentHelpReports: env.GT_AUDIT_CURSOR_STANDALONE_AGENT_HELP === "true",
  standaloneAgentHelpExit: env.GT_AUDIT_CURSOR_STANDALONE_AGENT_HELP_EXIT || null,
  standaloneAgentHelpTimedOut: env.GT_AUDIT_CURSOR_STANDALONE_AGENT_HELP_TIMEOUT === "true",
  bundledAgentExecExtensionPresent: env.GT_AUDIT_CURSOR_AGENT_EXEC_EXTENSION === "true",
  bundledAgentWorkerExtensionPresent: env.GT_AUDIT_CURSOR_AGENT_WORKER_EXTENSION === "true",
  bundledAgentExecDescription: env.GT_AUDIT_CURSOR_AGENT_EXEC_DESCRIPTION || null,
  bundledAgentWorkerDescription: env.GT_AUDIT_CURSOR_AGENT_WORKER_DESCRIPTION || null,
  result: env.GT_AUDIT_CURSOR_RESULT,
  resultDetail: env.GT_AUDIT_CURSOR_RESULT_DETAIL,
};
fs.writeFileSync(artifact, `${JSON.stringify(payload, null, 2)}\n`);
console.log(`Artifact: ${artifact}`);
NODE
fi
