#!/usr/bin/env bash
# Privacy-safe OpenCode real session-store audit.
set -euo pipefail

redact_home() {
  local value="$1"
  printf '%s' "${value/#$HOME/~}"
}

db_path="${GT_OPENCODE_DB_PATH:-$HOME/.local/share/opencode/opencode.db}"
artifact_dir="${GT_OPENCODE_SESSION_AUDIT_OUT_DIR:-}"
cli_sessions_file="$(mktemp -t glasstunnel-opencode-cli-sessions.XXXXXX.json)"
db_sessions_file="$(mktemp -t glasstunnel-opencode-db-sessions.XXXXXX.json)"
cleanup() {
  rm -f "$cli_sessions_file" "$db_sessions_file"
}
trap cleanup EXIT

audit_date="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
commit="$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

printf 'Glasstunnel OpenCode session-store audit\n'
printf 'Date: %s\n' "$audit_date"
printf 'Commit: %s\n' "$commit"
printf 'Database: %s\n\n' "$(redact_home "$db_path")"

if ! command -v sqlite3 >/dev/null 2>&1; then
  printf 'Result: blocked; sqlite3 is required for the OpenCode session-store audit.\n' >&2
  exit 1
fi

opencode_path="$(command -v opencode 2>/dev/null || true)"
if [[ -z "$opencode_path" ]]; then
  printf 'OpenCode CLI: missing\n'
  printf 'Result: blocked; install OpenCode CLI before real session-store verification.\n' >&2
  exit 1
fi

opencode_version="$(opencode --version 2>&1 | sed -n '1p' || printf unknown)"
printf 'OpenCode CLI: present: %s\n' "$(redact_home "$opencode_path")"
printf 'OpenCode CLI version: %s\n\n' "$opencode_version"

if [[ ! -f "$db_path" ]]; then
  printf 'Result: blocked; OpenCode database was not found at the expected path.\n' >&2
  exit 1
fi

missing=0
for table in session message part; do
  exists="$(sqlite3 "$db_path" "select count(*) from sqlite_master where type='table' and name='$table';")"
  if [[ "$exists" != "1" ]]; then
    printf '| Table %s | fail | missing |\n' "$table"
    missing=1
  fi
done

for column in id project_id directory title time_updated time_archived; do
  exists="$(sqlite3 "$db_path" "select count(*) from pragma_table_info('session') where name='$column';")"
  if [[ "$exists" != "1" ]]; then
    printf '| session.%s | fail | missing |\n' "$column"
    missing=1
  fi
done

for column in id session_id data time_created; do
  exists="$(sqlite3 "$db_path" "select count(*) from pragma_table_info('message') where name='$column';")"
  if [[ "$exists" != "1" ]]; then
    printf '| message.%s | fail | missing |\n' "$column"
    missing=1
  fi
done

for column in id message_id session_id data time_created; do
  exists="$(sqlite3 "$db_path" "select count(*) from pragma_table_info('part') where name='$column';")"
  if [[ "$exists" != "1" ]]; then
    printf '| part.%s | fail | missing |\n' "$column"
    missing=1
  fi
done

if [[ "$missing" != "0" ]]; then
  printf 'Result: failed; OpenCode database schema no longer matches Glasstunnel session-store assumptions.\n' >&2
  exit 1
fi

session_count="$(sqlite3 "$db_path" "select count(*) from session where time_archived is null;")"
message_count="$(sqlite3 "$db_path" "select count(*) from message;")"
part_count="$(sqlite3 "$db_path" "select count(*) from part;")"
empty_recent_count="$(sqlite3 "$db_path" "select count(*) from (select session.id from session left join message on message.session_id = session.id where session.time_archived is null group by session.id having count(message.id) = 0 order by session.time_updated desc, session.time_created desc, session.id desc limit 5);")"
latest_message_count="$(sqlite3 "$db_path" "with latest as (select id from session where time_archived is null and exists (select 1 from message where message.session_id = session.id) order by time_updated desc, time_created desc, id desc limit 1) select count(*) from message where session_id in (select id from latest);")"
if ! opencode session list --format json --max-count 20 >"$cli_sessions_file" 2>/dev/null; then
  printf 'Result: failed; `opencode session list --format json --max-count 20` did not complete.\n' >&2
  exit 1
fi
if ! sqlite3 -json "$db_path" "select id, title, directory from session where time_archived is null;" >"$db_sessions_file"; then
  printf 'Result: failed; SQLite could not export OpenCode session rows for CLI/DB parity comparison.\n' >&2
  exit 1
fi
cli_json_count="$(node -e 'const fs=require("fs");try{const parsed=JSON.parse(fs.readFileSync(process.argv[1],"utf8")||"[]"); console.log(Array.isArray(parsed)?parsed.length:0)}catch{console.log(0)}' "$cli_sessions_file")"
session_parity="$(
  node - "$cli_sessions_file" "$db_sessions_file" <<'NODE'
const fs = require("fs");

function readJson(path) {
  try {
    const parsed = JSON.parse(fs.readFileSync(path, "utf8") || "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

const cliRows = readJson(process.argv[2]);
const dbRows = readJson(process.argv[3]);
const dbById = new Map();
for (const row of dbRows) {
  if (row && typeof row.id === "string" && row.id.length > 0) {
    dbById.set(row.id, row);
  }
}

let matched = 0;
let missing = 0;
let mismatched = 0;
let invalid = 0;

for (const cli of cliRows) {
  if (!cli || typeof cli.id !== "string" || cli.id.length === 0) {
    invalid += 1;
    continue;
  }
  const db = dbById.get(cli.id);
  if (!db) {
    missing += 1;
    continue;
  }
  if (db.title !== cli.title || db.directory !== cli.directory) {
    mismatched += 1;
    continue;
  }
  matched += 1;
}

process.stdout.write(`${matched}|${missing}|${mismatched}|${invalid}`);
NODE
)"
IFS='|' read -r cli_db_matched cli_db_missing cli_db_mismatched cli_db_invalid <<<"$session_parity"

printf '| Check | Status | Detail |\n'
printf '| --- | --- | --- |\n'
printf '| Database schema | pass | session/message/part tables and required columns exist |\n'
printf '| Active sessions | pass | %s non-archived sessions |\n' "$session_count"
printf '| Messages | pass | %s message rows |\n' "$message_count"
printf '| Parts | pass | %s part rows |\n' "$part_count"
printf '| Recent empty sessions | pass | %s empty rows among 5 newest sessions |\n' "$empty_recent_count"
printf '| Latest message-backed session | %s | %s message rows |\n' "$(if [[ "$latest_message_count" -gt 0 ]]; then printf pass; else printf fail; fi)" "$latest_message_count"
printf '| CLI session list JSON | %s | %s sessions returned by opencode |\n' "$(if [[ "$cli_json_count" -gt 0 ]]; then printf pass; else printf fail; fi)" "$cli_json_count"
printf '| CLI/DB session parity | %s | %s matched, %s missing, %s title/directory mismatches, %s invalid CLI rows |\n' "$(if [[ "$cli_db_matched" -gt 0 && "$cli_db_missing" -eq 0 && "$cli_db_mismatched" -eq 0 && "$cli_db_invalid" -eq 0 ]]; then printf pass; else printf fail; fi)" "$cli_db_matched" "$cli_db_missing" "$cli_db_mismatched" "$cli_db_invalid"

if [[ "$session_count" -lt 1 || "$message_count" -lt 1 || "$part_count" -lt 1 || "$latest_message_count" -lt 1 || "$cli_json_count" -lt 1 || "$cli_db_matched" -lt 1 || "$cli_db_missing" -ne 0 || "$cli_db_mismatched" -ne 0 || "$cli_db_invalid" -ne 0 ]]; then
  printf '\nResult: failed; OpenCode real session data was present but not sufficient for release evidence.\n' >&2
  exit 1
fi

printf '\nRunning gated Swift parser audit against the real default database...\n'
GT_OPENCODE_REAL_DB_AUDIT=1 swift test --package-path apps/host-macos --filter OpenCodeSessionStoreTests/testDefaultDatabaseLoadsRealSessionsWhenExplicitlyEnabled

if [[ -n "$artifact_dir" ]]; then
  mkdir -p "$artifact_dir"
  artifact_path="$artifact_dir/opencode-session-audit.json"
  OPENCODE_SESSION_AUDIT_ARTIFACT_PATH="$artifact_path" \
  OPENCODE_SESSION_AUDIT_DATE="$audit_date" \
  OPENCODE_SESSION_AUDIT_COMMIT="$commit" \
  OPENCODE_SESSION_AUDIT_DB="$(redact_home "$db_path")" \
  OPENCODE_SESSION_AUDIT_CLI_PATH="$(redact_home "$opencode_path")" \
  OPENCODE_SESSION_AUDIT_CLI_VERSION="$opencode_version" \
  OPENCODE_SESSION_AUDIT_SESSION_COUNT="$session_count" \
  OPENCODE_SESSION_AUDIT_MESSAGE_COUNT="$message_count" \
  OPENCODE_SESSION_AUDIT_PART_COUNT="$part_count" \
  OPENCODE_SESSION_AUDIT_EMPTY_RECENT_COUNT="$empty_recent_count" \
  OPENCODE_SESSION_AUDIT_LATEST_MESSAGE_COUNT="$latest_message_count" \
  OPENCODE_SESSION_AUDIT_CLI_JSON_COUNT="$cli_json_count" \
  OPENCODE_SESSION_AUDIT_CLI_DB_MATCHED="$cli_db_matched" \
  OPENCODE_SESSION_AUDIT_CLI_DB_MISSING="$cli_db_missing" \
  OPENCODE_SESSION_AUDIT_CLI_DB_MISMATCHED="$cli_db_mismatched" \
  OPENCODE_SESSION_AUDIT_CLI_DB_INVALID="$cli_db_invalid" \
    node <<'NODE'
const fs = require("fs");

function numberFromEnv(name) {
  const value = Number(process.env[name] || "0");
  return Number.isFinite(value) ? value : 0;
}

const artifact = {
  generatedAt: process.env.OPENCODE_SESSION_AUDIT_DATE,
  commit: process.env.OPENCODE_SESSION_AUDIT_COMMIT,
  result: "passed",
  privacy: "Redacted artifact: no OpenCode session titles, directories, prompts, responses, raw rows, or message text are written.",
  database: process.env.OPENCODE_SESSION_AUDIT_DB,
  cli: {
    path: process.env.OPENCODE_SESSION_AUDIT_CLI_PATH,
    version: process.env.OPENCODE_SESSION_AUDIT_CLI_VERSION,
  },
  checks: {
    schema: "passed",
    swiftParserAudit: "passed",
    activeSessions: numberFromEnv("OPENCODE_SESSION_AUDIT_SESSION_COUNT"),
    messages: numberFromEnv("OPENCODE_SESSION_AUDIT_MESSAGE_COUNT"),
    parts: numberFromEnv("OPENCODE_SESSION_AUDIT_PART_COUNT"),
    recentEmptySessionsAmongFiveNewest: numberFromEnv("OPENCODE_SESSION_AUDIT_EMPTY_RECENT_COUNT"),
    latestMessageBackedSessionMessages: numberFromEnv("OPENCODE_SESSION_AUDIT_LATEST_MESSAGE_COUNT"),
    cliSessionsReturned: numberFromEnv("OPENCODE_SESSION_AUDIT_CLI_JSON_COUNT"),
    cliDbParity: {
      matched: numberFromEnv("OPENCODE_SESSION_AUDIT_CLI_DB_MATCHED"),
      missing: numberFromEnv("OPENCODE_SESSION_AUDIT_CLI_DB_MISSING"),
      titleDirectoryMismatches: numberFromEnv("OPENCODE_SESSION_AUDIT_CLI_DB_MISMATCHED"),
      invalidCliRows: numberFromEnv("OPENCODE_SESSION_AUDIT_CLI_DB_INVALID"),
    },
  },
};

fs.writeFileSync(
  process.env.OPENCODE_SESSION_AUDIT_ARTIFACT_PATH,
  `${JSON.stringify(artifact, null, 2)}\n`,
);
NODE
  printf 'Artifact: %s\n' "$(redact_home "$artifact_path")"
fi

printf '\nResult: passed; OpenCode real session database exists, has parseable sessions/messages, and matches OpenCode CLI session IDs, titles, and directories without printing private content.\n'
