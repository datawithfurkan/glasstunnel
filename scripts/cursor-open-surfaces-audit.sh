#!/usr/bin/env bash
# Privacy-safe audit of Cursor open/control surfaces Glasstunnel can rely on.
#
# This records app/CLI/deeplink capabilities only. It does not open Cursor,
# inspect user chat text, submit prompts, or call Cursor models.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${GT_CURSOR_APP_PATH:-/Applications/Cursor.app}"
OUT_DIR="${GT_CURSOR_OPEN_SURFACES_OUT_DIR:-}"
REQUIRE_TARGET_TRUTH="${GT_CURSOR_OPEN_SURFACES_REQUIRE_TARGET_TRUTH:-0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor open-surface audit requires macOS." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Cursor open surfaces audit"
  echo "Cursor app path: $APP_PATH"
  echo "App installed: no"
  echo "Result: blocked; Cursor.app is not installed at the configured path."
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
PRODUCT_JSON="$APP_PATH/Contents/Resources/app/product.json"
CLI_PATH="$APP_PATH/Contents/Resources/app/bin/cursor"
DEEPLINK_PACKAGE="$APP_PATH/Contents/Resources/app/extensions/cursor-deeplink/package.json"
DEEPLINK_DIST="$APP_PATH/Contents/Resources/app/extensions/cursor-deeplink/dist/main.js"

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
url_schemes="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes' "$INFO_PLIST" 2>/dev/null | awk '/^[[:space:]]+[A-Za-z][A-Za-z0-9+.-]*$/ { print $1 }' | paste -sd ',' - || true)"
cursor_on_path="$(command -v cursor 2>/dev/null || true)"
cli_executable="false"
cli_reports_help="false"
cli_supports_chat="false"

help_file="$(mktemp -t glasstunnel-cursor-help.XXXXXX)"
cleanup() {
  rm -f "$help_file"
}
trap cleanup EXIT

if [[ -x "$CLI_PATH" ]]; then
  cli_executable="true"
  if "$CLI_PATH" --help >"$help_file" 2>&1; then
    cli_reports_help="true"
    if grep -q -- "--chat" "$help_file"; then
      cli_supports_chat="true"
    fi
  fi
fi

deeplink_extension_present="false"
deeplink_on_uri="false"
deeplink_create_chat="false"
deeplink_background_agent="false"
deeplink_mcp_install="false"
deeplink_prompt="false"
deeplink_prompt_workspace_routing="false"
deeplink_command="false"
deeplink_rule="false"
deeplink_background_agent_target_routing="false"
deeplink_existing_composer_route="false"
deeplink_existing_composer_candidate_count=0

if [[ -f "$DEEPLINK_PACKAGE" && -f "$DEEPLINK_DIST" ]]; then
  deeplink_extension_present="true"
  grep -q '"onUri"' "$DEEPLINK_PACKAGE" && deeplink_on_uri="true"
  grep -q '"/createchat"' "$DEEPLINK_DIST" && deeplink_create_chat="true"
  grep -q '"/mcp/install"' "$DEEPLINK_DIST" && deeplink_mcp_install="true"
  grep -q '"/background-agent' "$DEEPLINK_DIST" && deeplink_background_agent="true"
  grep -q '"/prompt"' "$DEEPLINK_DIST" && deeplink_prompt="true"
  if grep -q 'deeplink.routeToWorkspaceName' "$DEEPLINK_DIST" && grep -q 'gl(t.query,"workspace")' "$DEEPLINK_DIST"; then
    deeplink_prompt_workspace_routing="true"
  fi
  grep -q '"/command"' "$DEEPLINK_DIST" && deeplink_command="true"
  grep -q '"/rule"' "$DEEPLINK_DIST" && deeplink_rule="true"
  if grep -Eq 'openBackgroundComposerAsChat|openWindowIdForBc|composer.getBackgroundComposerInfo' "$DEEPLINK_DIST"; then
    deeplink_background_agent_target_routing="true"
  fi
  deeplink_existing_composer_candidate_count="$(
    {
      grep -Eo 'openComposer|openConversation|openChat|openThread|composerId|conversationId|chatId|threadId|sessionId' "$DEEPLINK_DIST" 2>/dev/null \
        | grep -Ev 'Background|background|bcId' \
        || true
    } | wc -l | tr -d '[:space:]'
  )"
  if grep -Eq 'openComposer|openConversation|openChat|openThread' "$DEEPLINK_DIST"; then
    deeplink_existing_composer_route="true"
  fi
fi

recent_model_values="$(
  find "$HOME/Library/Application Support/Cursor/logs" -type f -name '*.log' -mtime -7 -print0 2>/dev/null \
    | xargs -0 grep -Eho 'modelName":"[A-Za-z0-9._/-]+|modelName=[A-Za-z0-9._/-]+|catalogModelId=[A-Za-z0-9._/-]+' 2>/dev/null \
    | sed -E 's/^(modelName":"|modelName=|catalogModelId=)//' \
    | sort -u \
    | paste -sd ',' - \
    || true
)"

result="partial"
if [[ "$cli_executable" == "true" && "$cli_supports_chat" == "true" && "$deeplink_extension_present" == "true" ]]; then
  result="passed"
fi

target_truth_result="partial"
if [[ "$cli_executable" == "true" &&
      "$cli_supports_chat" == "true" &&
      "$deeplink_extension_present" == "true" &&
      "$deeplink_prompt" == "true" &&
      "$deeplink_prompt_workspace_routing" == "true" &&
      "$deeplink_existing_composer_route" == "false" ]]; then
  target_truth_result="passed"
fi

echo "Cursor open surfaces audit"
echo "Cursor app path: $APP_PATH"
echo "Bundle id: ${app_bundle_id:-unknown}"
echo "Version: ${app_version:-unknown}"
echo "URL schemes: ${url_schemes:-none}"
echo "cursor on PATH: ${cursor_on_path:-not found}"
echo "Bundled CLI: $CLI_PATH"
echo "Bundled CLI executable: $cli_executable"
echo "Bundled CLI help: $cli_reports_help"
echo "Bundled CLI --chat support: $cli_supports_chat"
echo "Deeplink extension present: $deeplink_extension_present"
echo "Deeplink onUri activation: $deeplink_on_uri"
echo "Deeplink /createchat route: $deeplink_create_chat"
echo "Deeplink /background-agent route: $deeplink_background_agent"
echo "Deeplink /mcp/install route: $deeplink_mcp_install"
echo "Deeplink /prompt route: $deeplink_prompt"
echo "Deeplink /prompt workspace-name routing: $deeplink_prompt_workspace_routing"
echo "Deeplink /command route: $deeplink_command"
echo "Deeplink /rule route: $deeplink_rule"
echo "Background-agent target routing route: $deeplink_background_agent_target_routing"
echo "Existing composer open route found: $deeplink_existing_composer_route"
echo "Existing composer candidate token count: $deeplink_existing_composer_candidate_count"
echo "Recent safe model ids from logs: ${recent_model_values:-none}"
echo "Result: $result; Cursor exposes a bundled --chat CLI and limited deeplink routes."
echo "Target-opening truth: $target_truth_result; Cursor exposes workspace-name prompt routing and background-agent routing, but no verified existing-composer route for parsed desktop chats."

if [[ "$REQUIRE_TARGET_TRUTH" == "1" && "$target_truth_result" != "passed" ]]; then
  echo "Result: failed; target-opening truth could not be classified from the installed Cursor open surfaces." >&2
  exit 1
fi

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  artifact="$OUT_DIR/cursor-open-surfaces-$(date -u +%Y-%m-%dT%H-%M-%SZ).json"
  export GT_AUDIT_CURSOR_APP_PATH="$APP_PATH"
  export GT_AUDIT_CURSOR_BUNDLE_ID="$app_bundle_id"
  export GT_AUDIT_CURSOR_VERSION="$app_version"
  export GT_AUDIT_CURSOR_URL_SCHEMES="$url_schemes"
  export GT_AUDIT_CURSOR_ON_PATH="$cursor_on_path"
  export GT_AUDIT_CURSOR_CLI_PATH="$CLI_PATH"
  export GT_AUDIT_CURSOR_CLI_EXECUTABLE="$cli_executable"
  export GT_AUDIT_CURSOR_CLI_HELP="$cli_reports_help"
  export GT_AUDIT_CURSOR_CLI_CHAT="$cli_supports_chat"
  export GT_AUDIT_CURSOR_DEEPLINK_PRESENT="$deeplink_extension_present"
  export GT_AUDIT_CURSOR_DEEPLINK_ON_URI="$deeplink_on_uri"
  export GT_AUDIT_CURSOR_DEEPLINK_CREATE_CHAT="$deeplink_create_chat"
  export GT_AUDIT_CURSOR_DEEPLINK_BACKGROUND_AGENT="$deeplink_background_agent"
  export GT_AUDIT_CURSOR_DEEPLINK_MCP_INSTALL="$deeplink_mcp_install"
  export GT_AUDIT_CURSOR_DEEPLINK_PROMPT="$deeplink_prompt"
  export GT_AUDIT_CURSOR_DEEPLINK_PROMPT_WORKSPACE="$deeplink_prompt_workspace_routing"
  export GT_AUDIT_CURSOR_DEEPLINK_COMMAND="$deeplink_command"
  export GT_AUDIT_CURSOR_DEEPLINK_RULE="$deeplink_rule"
  export GT_AUDIT_CURSOR_BACKGROUND_AGENT_TARGET_ROUTING="$deeplink_background_agent_target_routing"
  export GT_AUDIT_CURSOR_EXISTING_COMPOSER_ROUTE="$deeplink_existing_composer_route"
  export GT_AUDIT_CURSOR_EXISTING_COMPOSER_CANDIDATE_COUNT="$deeplink_existing_composer_candidate_count"
  export GT_AUDIT_CURSOR_RECENT_MODEL_VALUES="$recent_model_values"
  export GT_AUDIT_CURSOR_RESULT="$result"
  export GT_AUDIT_CURSOR_TARGET_TRUTH_RESULT="$target_truth_result"
  node - "$artifact" <<'NODE'
const fs = require("fs");
const artifact = process.argv[2];
const env = process.env;
const payload = {
  appPath: env.GT_AUDIT_CURSOR_APP_PATH,
  bundleId: env.GT_AUDIT_CURSOR_BUNDLE_ID,
  version: env.GT_AUDIT_CURSOR_VERSION,
  urlSchemes: (env.GT_AUDIT_CURSOR_URL_SCHEMES || "").split(",").filter(Boolean),
  cursorOnPath: env.GT_AUDIT_CURSOR_ON_PATH || null,
  bundledCliPath: env.GT_AUDIT_CURSOR_CLI_PATH,
  bundledCliExecutable: env.GT_AUDIT_CURSOR_CLI_EXECUTABLE === "true",
  bundledCliReportsHelp: env.GT_AUDIT_CURSOR_CLI_HELP === "true",
  bundledCliSupportsChat: env.GT_AUDIT_CURSOR_CLI_CHAT === "true",
  deeplinkExtensionPresent: env.GT_AUDIT_CURSOR_DEEPLINK_PRESENT === "true",
  deeplinkOnUri: env.GT_AUDIT_CURSOR_DEEPLINK_ON_URI === "true",
  deeplinkCreateChat: env.GT_AUDIT_CURSOR_DEEPLINK_CREATE_CHAT === "true",
  deeplinkBackgroundAgent: env.GT_AUDIT_CURSOR_DEEPLINK_BACKGROUND_AGENT === "true",
  deeplinkMcpInstall: env.GT_AUDIT_CURSOR_DEEPLINK_MCP_INSTALL === "true",
  deeplinkPrompt: env.GT_AUDIT_CURSOR_DEEPLINK_PROMPT === "true",
  deeplinkPromptWorkspaceNameRouting: env.GT_AUDIT_CURSOR_DEEPLINK_PROMPT_WORKSPACE === "true",
  deeplinkCommand: env.GT_AUDIT_CURSOR_DEEPLINK_COMMAND === "true",
  deeplinkRule: env.GT_AUDIT_CURSOR_DEEPLINK_RULE === "true",
  backgroundAgentTargetRouting: env.GT_AUDIT_CURSOR_BACKGROUND_AGENT_TARGET_ROUTING === "true",
  existingComposerOpenRouteFound: env.GT_AUDIT_CURSOR_EXISTING_COMPOSER_ROUTE === "true",
  existingComposerCandidateTokenCount: Number(env.GT_AUDIT_CURSOR_EXISTING_COMPOSER_CANDIDATE_COUNT || 0),
  recentSafeModelIdsFromLogs: (env.GT_AUDIT_CURSOR_RECENT_MODEL_VALUES || "").split(",").filter(Boolean),
  result: env.GT_AUDIT_CURSOR_RESULT,
  targetOpeningTruthResult: env.GT_AUDIT_CURSOR_TARGET_TRUTH_RESULT,
};
fs.writeFileSync(artifact, `${JSON.stringify(payload, null, 2)}\n`);
console.log(`Artifact: ${artifact}`);
NODE
fi
