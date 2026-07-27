#!/usr/bin/env bash
# Privacy-safe Cursor stored model/settings audit.
#
# This inspects only Cursor storage fields shaped like
# providerOptions.cursor.modelName in small agent records. It does not print
# prompts, responses, composer names, database paths, raw JSON, or hashed record
# keys. The result is evidence of recently stored Cursor model usage, not proof
# of the currently active pre-submit model selector.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CURSOR_MODEL_STORAGE_OUT_DIR:-/tmp/glasstunnel-cursor-model-settings-storage-audit}"
CURSOR_STATE_DIR="${CURSOR_STATE_DIR:-$HOME/Library/Application Support/Cursor}"
ALLOWED_MODEL_SETTINGS="${GT_CURSOR_ALLOWED_MODEL_SETTINGS:-Composer 2.5 Fast}"
mkdir -p "$OUT_DIR"

redact_home() {
  local value="$1"
  printf '%s' "${value/#$HOME/~}"
}

cursor_app_path() {
  local path
  for path in "/Applications/Cursor.app" "$HOME/Applications/Cursor.app"; do
    if [[ -d "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi
  done
  return 1
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor model/settings storage audit requires macOS." >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Result: blocked; sqlite3 is required to inspect Cursor storage." >&2
  exit 1
fi

app="$(cursor_app_path || true)"
version="unknown"
build=""
if [[ -n "$app" ]]; then
  info_plist="${app}/Contents/Info.plist"
  version="$(plist_value "$info_plist" "CFBundleShortVersionString")"
  build="$(plist_value "$info_plist" "CFBundleVersion")"
fi

db="${CURSOR_STATE_DIR}/User/globalStorage/state.vscdb"
timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
artifact="${OUT_DIR}/cursor-model-settings-storage-${timestamp}.json"

if [[ ! -f "$db" ]]; then
  GT_CURSOR_MODEL_STORAGE_SUMMARY='[]' \
  GT_CURSOR_MODEL_STORAGE_MODELS='[]' \
  GT_CURSOR_MODEL_STORAGE_ARTIFACT="$artifact" \
  GT_CURSOR_MODEL_STORAGE_APP_PRESENT="$(if [[ -n "$app" ]]; then printf true; else printf false; fi)" \
  GT_CURSOR_MODEL_STORAGE_APP_PATH="$(if [[ -n "$app" ]]; then redact_home "$app"; fi)" \
  GT_CURSOR_MODEL_STORAGE_VERSION="${version:-unknown}" \
  GT_CURSOR_MODEL_STORAGE_BUILD="$build" \
  GT_CURSOR_MODEL_STORAGE_DB_PRESENT=false \
  GT_CURSOR_MODEL_STORAGE_ALLOWED="$ALLOWED_MODEL_SETTINGS" \
  node <<'NODE'
const fs = require("node:fs");
const artifact = process.env.GT_CURSOR_MODEL_STORAGE_ARTIFACT;
const payload = {
  generatedAt: new Date().toISOString(),
  commit: "unknown",
  cursorAppPresent: process.env.GT_CURSOR_MODEL_STORAGE_APP_PRESENT === "true",
  cursorAppPath: process.env.GT_CURSOR_MODEL_STORAGE_APP_PATH || null,
  cursorVersion: process.env.GT_CURSOR_MODEL_STORAGE_VERSION || "unknown",
  cursorBuild: process.env.GT_CURSOR_MODEL_STORAGE_BUILD || null,
  databasePresent: false,
  source: "Cursor globalStorage cursorDiskKV agentKv providerOptions.cursor.modelName",
  sourceIsActivePreSubmitModel: false,
  sourceTimestampPathCount: 0,
  sourceActiveSelectorPathCount: 0,
  sourceHasTimestampMetadata: false,
  sourceHasActiveSelectorMetadata: false,
  allowedModelSettings: process.env.GT_CURSOR_MODEL_STORAGE_ALLOWED || "",
  modelNameOccurrenceCount: 0,
  distinctModelNames: [],
  allowedModelNameSeen: false,
  result: "blocked",
  followUp: "Cursor globalStorage state.vscdb was not found. Launch Cursor and open a chat before auditing stored model evidence."
};
fs.writeFileSync(artifact, `${JSON.stringify(payload, null, 2)}\n`);
console.log(JSON.stringify(payload, null, 2));
NODE
  echo "Artifact: $artifact"
  exit 0
fi

summary_json="$(sqlite3 -json "$db" "
  SELECT
    COUNT(*) AS agentBlobRows,
    SUM(CASE WHEN json_valid(CAST(value AS TEXT)) THEN 1 ELSE 0 END) AS validAgentBlobRows,
    SUM(CASE WHEN NOT json_valid(CAST(value AS TEXT)) THEN 1 ELSE 0 END) AS invalidAgentBlobRows
  FROM cursorDiskKV
  WHERE key LIKE 'agentKv:blob:%';
")"

models_json="$(sqlite3 -json "$db" "
  WITH model_rows AS (
    SELECT CAST(jt.atom AS TEXT) AS modelName
    FROM cursorDiskKV c, json_tree(CAST(c.value AS TEXT)) jt
    WHERE c.key LIKE 'agentKv:blob:%'
      AND json_valid(CAST(c.value AS TEXT))
      AND jt.key = 'modelName'
      AND jt.fullkey LIKE '$.content[%].providerOptions.cursor.modelName'
  )
  SELECT modelName, COUNT(*) AS occurrenceCount
  FROM model_rows
  WHERE modelName IS NOT NULL
  GROUP BY modelName
  ORDER BY occurrenceCount DESC, modelName ASC;
")"

metadata_json="$(sqlite3 -json "$db" "
  WITH inspected_paths AS (
    SELECT lower(jt.fullkey) AS fullkey
    FROM cursorDiskKV c, json_tree(CAST(c.value AS TEXT)) jt
    WHERE c.key LIKE 'agentKv:blob:%'
      AND json_valid(CAST(c.value AS TEXT))
  )
  SELECT
    COALESCE(SUM(CASE
      WHEN fullkey LIKE '%time%'
        OR fullkey LIKE '%date%'
        OR fullkey LIKE '%created%'
        OR fullkey LIKE '%updated%'
      THEN 1 ELSE 0 END), 0) AS timestampPathCount,
    COALESCE(SUM(CASE
      WHEN fullkey LIKE '%selected%'
        OR fullkey LIKE '%active%'
        OR fullkey LIKE '%current%'
      THEN 1 ELSE 0 END), 0) AS activeSelectorPathCount
  FROM inspected_paths;
")"

commit="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"

GT_CURSOR_MODEL_STORAGE_SUMMARY="$summary_json" \
GT_CURSOR_MODEL_STORAGE_MODELS="$models_json" \
GT_CURSOR_MODEL_STORAGE_METADATA="$metadata_json" \
GT_CURSOR_MODEL_STORAGE_ARTIFACT="$artifact" \
GT_CURSOR_MODEL_STORAGE_COMMIT="$commit" \
GT_CURSOR_MODEL_STORAGE_APP_PRESENT="$(if [[ -n "$app" ]]; then printf true; else printf false; fi)" \
GT_CURSOR_MODEL_STORAGE_APP_PATH="$(if [[ -n "$app" ]]; then redact_home "$app"; fi)" \
GT_CURSOR_MODEL_STORAGE_VERSION="${version:-unknown}" \
GT_CURSOR_MODEL_STORAGE_BUILD="$build" \
GT_CURSOR_MODEL_STORAGE_DB_PRESENT=true \
GT_CURSOR_MODEL_STORAGE_ALLOWED="$ALLOWED_MODEL_SETTINGS" \
node <<'NODE'
const fs = require("node:fs");

function parseJsonEnv(name, fallback) {
  try {
    return JSON.parse(process.env[name] || JSON.stringify(fallback));
  } catch {
    return fallback;
  }
}

function normalize(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function safeModelName(value) {
  const model = String(value || "").trim();
  if (!model || model.length > 80) return null;
  if (!/^[A-Za-z0-9._/-]+$/.test(model)) return null;
  return model;
}

const summary = parseJsonEnv("GT_CURSOR_MODEL_STORAGE_SUMMARY", [{}])[0] || {};
const rawModels = parseJsonEnv("GT_CURSOR_MODEL_STORAGE_MODELS", []);
const metadata = parseJsonEnv("GT_CURSOR_MODEL_STORAGE_METADATA", [{}])[0] || {};
const models = rawModels
  .map((entry) => ({
    modelName: safeModelName(entry.modelName),
    occurrenceCount: Number(entry.occurrenceCount || 0),
  }))
  .filter((entry) => entry.modelName && entry.occurrenceCount > 0);

const allowed = String(process.env.GT_CURSOR_MODEL_STORAGE_ALLOWED || "")
  .split(",")
  .map((entry) => entry.trim())
  .filter(Boolean);
const allowedNormalized = new Set(allowed.map(normalize));
const allowedModelNameSeen = models.some((entry) => allowedNormalized.has(normalize(entry.modelName)));
const modelNameOccurrenceCount = models.reduce((sum, entry) => sum + entry.occurrenceCount, 0);
const sourceTimestampPathCount = Number(metadata.timestampPathCount || 0);
const sourceActiveSelectorPathCount = Number(metadata.activeSelectorPathCount || 0);
const result = modelNameOccurrenceCount > 0 ? (allowedModelNameSeen ? "passed" : "partial") : "partial";
const followUp = modelNameOccurrenceCount > 0
  ? "Use this as stored Cursor model evidence only. Keep prompt-submit preflight fail-closed until the active pre-submit model selector is visible, or document an explicit override."
  : "No providerOptions.cursor.modelName values were found in small Cursor agent records. Do not infer active Cursor model/settings from storage.";

const payload = {
  generatedAt: new Date().toISOString(),
  commit: process.env.GT_CURSOR_MODEL_STORAGE_COMMIT || "unknown",
  cursorAppPresent: process.env.GT_CURSOR_MODEL_STORAGE_APP_PRESENT === "true",
  cursorAppPath: process.env.GT_CURSOR_MODEL_STORAGE_APP_PATH || null,
  cursorVersion: process.env.GT_CURSOR_MODEL_STORAGE_VERSION || "unknown",
  cursorBuild: process.env.GT_CURSOR_MODEL_STORAGE_BUILD || null,
  databasePresent: process.env.GT_CURSOR_MODEL_STORAGE_DB_PRESENT === "true",
  source: "Cursor globalStorage cursorDiskKV agentKv providerOptions.cursor.modelName",
  sourceIsActivePreSubmitModel: false,
  sourceTimestampPathCount,
  sourceActiveSelectorPathCount,
  sourceHasTimestampMetadata: sourceTimestampPathCount > 0,
  sourceHasActiveSelectorMetadata: sourceActiveSelectorPathCount > 0,
  privacy: "Does not print Cursor prompts, responses, composer names, database paths, raw JSON, or hashed record keys.",
  agentBlobRows: Number(summary.agentBlobRows || 0),
  validAgentBlobRows: Number(summary.validAgentBlobRows || 0),
  invalidAgentBlobRows: Number(summary.invalidAgentBlobRows || 0),
  allowedModelSettings: allowed,
  modelNameOccurrenceCount,
  distinctModelNames: models,
  allowedModelNameSeen,
  result,
  followUp,
};

fs.writeFileSync(process.env.GT_CURSOR_MODEL_STORAGE_ARTIFACT, `${JSON.stringify(payload, null, 2)}\n`);
console.log(JSON.stringify(payload, null, 2));
NODE

echo "Artifact: $artifact"
