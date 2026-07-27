#!/usr/bin/env bash
# Privacy-safe audit of Cursor Agent auth and model-catalog readiness.
#
# This does not submit prompts, start agents, edit files, or call Cursor models.
set -euo pipefail

AGENT_PATH="${GT_CURSOR_AGENT_PATH:-$HOME/.local/bin/cursor-agent}"
OUT_DIR="${GT_CURSOR_AGENT_ACCOUNT_OUT_DIR:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor Agent account audit requires macOS." >&2
  exit 1
fi

if [[ ! -x "$AGENT_PATH" ]]; then
  echo "Cursor Agent account audit"
  echo "Cursor Agent path: $AGENT_PATH"
  echo "Cursor Agent executable: false"
  echo "Result: blocked; standalone cursor-agent executable is not available."
  exit 1
fi

tmp_dir="$(mktemp -d -t glasstunnel-cursor-agent-account.XXXXXX)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

run_capture() {
  local label="$1"
  shift
  set +e
  "$@" >"$tmp_dir/$label.out" 2>&1
  local code=$?
  set -e
  printf "%s" "$code" >"$tmp_dir/$label.code"
}

run_capture status "$AGENT_PATH" status --format json
run_capture about "$AGENT_PATH" about --format json
run_capture models "$AGENT_PATH" models

node - "$tmp_dir" "$AGENT_PATH" "$OUT_DIR" <<'NODE'
const fs = require("fs");
const path = require("path");

const [tmpDir, agentPath, outDir] = process.argv.slice(2);

function read(name) {
  return fs.readFileSync(path.join(tmpDir, `${name}.out`), "utf8");
}

function code(name) {
  return Number(fs.readFileSync(path.join(tmpDir, `${name}.code`), "utf8"));
}

function parseJson(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function classifyError(raw) {
  const text = raw.toLowerCase();
  return {
    authenticationRequired: /authentication required|not logged in|login/.test(text),
    networkOrServiceIssue: /network|timeout|econn|service unavailable|fetch failed/.test(text),
    rateOrQuotaIssue: /quota|rate limit|billing|payment|insufficient/.test(text),
  };
}

function safeModelIds(raw) {
  const ids = new Set();
  for (const match of raw.matchAll(/\b[a-z][a-z0-9._/-]{1,80}\b/gi)) {
    const value = match[0];
    if (/^(usage|options|commands|error|authentication|required|run|agent|login|pass|set|cursor_api_key|api|key|token)$/i.test(value)) continue;
    if (value.includes("@")) continue;
    if (!/[0-9./-]/.test(value) && !/(gpt|claude|sonnet|opus|haiku|gemini|auto|fast|pro|flash|mini|nano)/i.test(value)) continue;
    ids.add(value);
  }
  return [...ids].sort();
}

const statusRaw = read("status");
const aboutRaw = read("about");
const modelsRaw = read("models");
const statusJson = parseJson(statusRaw);
const aboutJson = parseJson(aboutRaw);
const modelIds = code("models") === 0 ? safeModelIds(modelsRaw) : [];
const modelError = code("models") === 0 ? {} : classifyError(modelsRaw);

const payload = {
  agentPath,
  statusExitCode: code("status"),
  aboutExitCode: code("about"),
  modelsExitCode: code("models"),
  isAuthenticated: Boolean(statusJson?.isAuthenticated),
  authStatus: typeof statusJson?.status === "string" ? statusJson.status : null,
  hasAccessToken: Boolean(statusJson?.hasAccessToken),
  hasRefreshToken: Boolean(statusJson?.hasRefreshToken),
  statusMessageClass: /not logged in/i.test(statusJson?.message || statusRaw) ? "not_logged_in" : code("status") === 0 ? "ok" : "unknown",
  cliVersion: typeof aboutJson?.cliVersion === "string" ? aboutJson.cliVersion : null,
  defaultModelLabel: typeof aboutJson?.model === "string" ? aboutJson.model : null,
  subscriptionTierKnown: typeof aboutJson?.subscriptionTier === "string" && aboutJson.subscriptionTier.length > 0,
  userEmailPresent: typeof aboutJson?.userEmail === "string" && aboutJson.userEmail.length > 0,
  terminalProgramKnown: typeof aboutJson?.terminalProgram === "string" && aboutJson.terminalProgram !== "unknown",
  shell: typeof aboutJson?.shell === "string" ? aboutJson.shell : null,
  modelCatalogAvailable: code("models") === 0,
  modelCount: modelIds.length,
  safeModelIds: modelIds,
  modelCatalogBlockedReason: code("models") === 0
    ? null
    : modelError.authenticationRequired
      ? "authentication_required"
      : modelError.rateOrQuotaIssue
        ? "account_or_billing"
        : modelError.networkOrServiceIssue
          ? "network_or_service"
          : "unknown",
  promptSubmitted: false,
  modelCallMade: false,
  rawAccountDataPrinted: false,
};

const result = payload.isAuthenticated && payload.modelCatalogAvailable ? "passed" : "partial";
const detail = payload.isAuthenticated
  ? "Cursor Agent is authenticated; model catalog availability is reported separately."
  : "Cursor Agent is installed but not authenticated; model catalog is blocked before any prompt or model call.";

console.log("Cursor Agent account audit");
console.log(`Cursor Agent path: ${agentPath}`);
console.log("Cursor Agent executable: true");
console.log(`Status exit: ${payload.statusExitCode}`);
console.log(`Authenticated: ${payload.isAuthenticated}`);
console.log(`Auth status: ${payload.authStatus || "unknown"}`);
console.log(`Access token present: ${payload.hasAccessToken}`);
console.log(`Refresh token present: ${payload.hasRefreshToken}`);
console.log(`CLI version: ${payload.cliVersion || "unknown"}`);
console.log(`Default model label: ${payload.defaultModelLabel || "unknown"}`);
console.log(`Subscription tier known: ${payload.subscriptionTierKnown}`);
console.log(`User email present: ${payload.userEmailPresent}`);
console.log(`Model catalog available: ${payload.modelCatalogAvailable}`);
console.log(`Model count: ${payload.modelCount}`);
console.log(`Model catalog blocked reason: ${payload.modelCatalogBlockedReason || "none"}`);
console.log("Prompt submitted: false");
console.log("Model call made: false");
console.log(`Result: ${result}; ${detail}`);

payload.result = result;
payload.resultDetail = detail;

if (outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/:/g, "-").replace(/\.\d{3}Z$/, "Z");
  const artifact = path.join(outDir, `cursor-agent-account-${stamp}.json`);
  fs.writeFileSync(artifact, `${JSON.stringify(payload, null, 2)}\n`);
  console.log(`Artifact: ${artifact}`);
}

process.exit(result === "passed" || result === "partial" ? 0 : 1);
NODE
