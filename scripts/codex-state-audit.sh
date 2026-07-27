#!/usr/bin/env bash
# Privacy-safe Codex desktop/CLI state audit for release verification.
#
# This reports only app/CLI version, state-file presence, and aggregate counts.
# It intentionally does not print Codex thread names, prompts, responses,
# workspace roots, raw JSON values, or session filenames.
set -euo pipefail

redact_home() {
  local value="$1"
  printf '%s' "${value/#$HOME/~}"
}

codex_app_path() {
  local dirs="${CODEX_AUDIT_APP_SEARCH_DIRS:-/Applications:$HOME/Applications:/System/Applications}"
  local dir name path resolved
  local -a search_dirs app_names
  IFS=':' read -r -a search_dirs <<< "$dirs"
  app_names=("Codex.app" "ChatGPT.app")

  for dir in "${search_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    for name in "${app_names[@]}"; do
      path="${dir%/}/$name"
      if [[ -d "$path" ]] && codex_bundle_matches "$path"; then
        printf '%s' "$path"
        return 0
      fi
    done
  done

  if [[ -n "${CODEX_AUDIT_NSWORKSPACE_RESULT+x}" ]]; then
    resolved="$CODEX_AUDIT_NSWORKSPACE_RESULT"
  elif command -v swift >/dev/null 2>&1; then
    resolved="$(
      swift -e 'import AppKit; if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { print(url.path) }' \
        2>/dev/null || true
    )"
  else
    resolved=""
  fi

  if [[ -n "$resolved" ]] && stable_app_path "$resolved" "$dirs" && codex_bundle_matches "$resolved"; then
    printf '%s' "$resolved"
    return 0
  fi
  return 1
}

codex_bundle_matches() {
  local app_path="$1"
  local bundle_id
  bundle_id="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$app_path/Contents/Info.plist" 2>/dev/null || true
  )"
  [[ "$bundle_id" == "com.openai.codex" ]]
}

stable_app_path() {
  local app_path="$1"
  local dirs="$2"
  local app_parent app_name dir root
  local -a search_dirs

  [[ "$app_path" == *.app ]] || return 1
  app_parent="$(cd "$(dirname "$app_path")" 2>/dev/null && pwd -P)" || return 1
  app_name="$(basename "$app_path")"
  app_path="$app_parent/$app_name"

  IFS=':' read -r -a search_dirs <<< "$dirs"
  for dir in "${search_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    root="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    [[ "$app_path" == "$root/"* ]] && return 0
  done
  return 1
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true
}

count_matches() {
  local pattern="$1"
  shift
  if [[ "$#" -eq 0 ]]; then
    printf '0'
    return
  fi
  if command -v rg >/dev/null 2>&1; then
    { rg --no-heading --no-line-number --no-messages --regexp "$pattern" "$@" || true; } | wc -l | tr -d '[:space:]'
  else
    { grep -h -E "$pattern" "$@" 2>/dev/null || true; } | wc -l | tr -d '[:space:]'
  fi
}

count_jsonl_lines() {
  local path="$1"
  if [[ -f "$path" ]]; then
    wc -l < "$path" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

latest_modified_iso() {
  local path="$1"
  if [[ -e "$path" ]]; then
    date -u -r "$path" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf 'unknown'
  else
    printf 'missing'
  fi
}

codex_state="${CODEX_STATE_DIR:-$HOME/.codex}"
sessions_root="${CODEX_SESSIONS_DIR:-$codex_state/sessions}"
session_index="${CODEX_SESSION_INDEX:-$codex_state/session_index.jsonl}"
global_state="${CODEX_GLOBAL_STATE:-$codex_state/.codex-global-state.json}"
max_sessions="${CODEX_AUDIT_MAX_SESSIONS:-25}"
require_label_sources="${CODEX_AUDIT_REQUIRE_LABEL_SOURCES:-0}"

if ! [[ "$max_sessions" =~ ^[0-9]+$ ]] || [[ "$max_sessions" -lt 1 ]]; then
  max_sessions=25
fi

app="$(codex_app_path || true)"
codex_cli="$(command -v codex 2>/dev/null || true)"

printf 'Glasstunnel Codex state audit\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

if [[ -n "$app" ]]; then
  info_plist="${app}/Contents/Info.plist"
  version="$(plist_value "$info_plist" "CFBundleShortVersionString")"
  build="$(plist_value "$info_plist" "CFBundleVersion")"
  printf 'Codex app: present: %s\n' "$(redact_home "$app")"
  printf 'Codex app version: %s%s\n' "${version:-unknown}" "$(if [[ -n "${build:-}" ]]; then printf ' (%s)' "$build"; fi)"
else
  printf 'Codex app: missing\n'
  printf 'Codex app version: unknown\n'
fi

if [[ -n "$codex_cli" ]]; then
  cli_version="$(codex --version 2>/dev/null | sed -n '1p' || true)"
  printf 'Codex CLI: present: %s\n' "$(redact_home "$codex_cli")"
  printf 'Codex CLI version: %s\n' "${cli_version:-unknown}"
else
  printf 'Codex CLI: missing\n'
  printf 'Codex CLI version: unknown\n'
fi

printf 'Codex state dir: %s\n' "$(redact_home "$codex_state")"
printf 'Sessions root: %s\n\n' "$(redact_home "$sessions_root")"

all_sessions=()
checked_sessions=()
if [[ -d "$sessions_root" ]]; then
  while IFS= read -r session_file; do
    all_sessions+=("$session_file")
  done < <(find "$sessions_root" -type f -name '*.jsonl' -print 2>/dev/null)

  if [[ "${#all_sessions[@]}" -gt 0 ]]; then
    while IFS= read -r session_file; do
      [[ -n "$session_file" ]] && checked_sessions+=("$session_file")
    done < <(
      for session in "${all_sessions[@]}"; do
        stat -f '%m %N' "$session"
      done | sort -rn | sed -n "1,${max_sessions}p" | sed 's/^[0-9][0-9]* //'
    )
  fi
fi

session_count="${#all_sessions[@]}"
checked_session_count="${#checked_sessions[@]}"
latest_session_modified="missing"
if [[ "$session_count" -gt 0 ]]; then
  latest_session="$(
    for session in "${all_sessions[@]}"; do
      stat -f '%m %N' "$session"
    done | sort -rn | sed -n '1p' | sed 's/^[0-9][0-9]* //'
  )"
  latest_session_modified="$(latest_modified_iso "$latest_session")"
fi

session_meta_rows=0
workspace_rows=0
thread_update_rows=0
message_rows=0
user_message_rows=0
assistant_message_rows=0
input_request_rows=0
if [[ "$checked_session_count" -gt 0 ]]; then
  session_meta_rows="$(count_matches '"type"[[:space:]]*:[[:space:]]*"session_meta"' "${checked_sessions[@]}")"
  workspace_rows="$(count_matches '"cwd"[[:space:]]*:' "${checked_sessions[@]}")"
  thread_update_rows="$(count_matches '"thread_name_updated"' "${checked_sessions[@]}")"
  message_rows="$(count_matches '"type"[[:space:]]*:[[:space:]]*"message"' "${checked_sessions[@]}")"
  user_message_rows="$(count_matches '"role"[[:space:]]*:[[:space:]]*"user"' "${checked_sessions[@]}")"
  assistant_message_rows="$(count_matches '"role"[[:space:]]*:[[:space:]]*"assistant"' "${checked_sessions[@]}")"
  input_request_rows="$(count_matches '"request_user_input"' "${checked_sessions[@]}")"
fi

index_records="$(count_jsonl_lines "$session_index")"
index_thread_name_rows=0
index_unique_ids=0
indexed_session_file_matches=0
if [[ -f "$session_index" ]]; then
  index_thread_name_rows="$(grep -h -E '"thread_name"[[:space:]]*:' "$session_index" 2>/dev/null | wc -l | tr -d '[:space:]')"
  if command -v node >/dev/null 2>&1; then
    index_unique_ids="$(node - "$session_index" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
const ids = new Set();
for (const line of fs.readFileSync(path, 'utf8').split(/\r?\n/)) {
  if (!line.trim()) continue;
  try {
    const row = JSON.parse(line);
    if (typeof row.id === 'string' && row.id.trim()) ids.add(row.id.trim());
  } catch {}
}
console.log(ids.size);
NODE
)"
    if [[ "$checked_session_count" -gt 0 ]]; then
      indexed_session_file_matches="$(node - "$session_index" "${checked_sessions[@]}" <<'NODE'
const fs = require('fs');
const indexPath = process.argv[2];
const sessionPaths = process.argv.slice(3);
const ids = new Set();
for (const line of fs.readFileSync(indexPath, 'utf8').split(/\r?\n/)) {
  if (!line.trim()) continue;
  try {
    const row = JSON.parse(line);
    if (typeof row.id === 'string' && row.id.trim()) ids.add(row.id.trim());
  } catch {}
}
let matches = 0;
for (const sessionPath of sessionPaths) {
  for (const id of ids) {
    if (sessionPath.includes(id)) {
      matches += 1;
      break;
    }
  }
}
console.log(matches);
NODE
)"
    fi
  fi
fi

global_project_order=0
global_saved_roots=0
global_active_roots=0
if [[ -f "$global_state" && "$(command -v node 2>/dev/null || true)" != "" ]]; then
  global_counts="$(node - "$global_state" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
try {
  const json = JSON.parse(fs.readFileSync(path, 'utf8'));
  const count = (key) => Array.isArray(json[key]) ? json[key].length : 0;
  console.log([
    count('project-order'),
    count('electron-saved-workspace-roots'),
    count('active-workspace-roots'),
  ].join(' '));
} catch {
  console.log('0 0 0');
}
NODE
)"
  read -r global_project_order global_saved_roots global_active_roots <<< "$global_counts"
fi

printf '| Source | Present | Count / latest |\n'
printf '| --- | --- | --- |\n'
printf '| Session JSONL files | %s | %s files; latest modified %s |\n' \
  "$(if [[ "$session_count" -gt 0 ]]; then printf yes; else printf no; fi)" \
  "$session_count" \
  "$latest_session_modified"
printf '| Checked session sample | %s | latest %s of %s session files |\n' \
  "$(if [[ "$checked_session_count" -gt 0 ]]; then printf yes; else printf no; fi)" \
  "$checked_session_count" \
  "$session_count"
printf '| session_index.jsonl | %s | %s records; %s with thread names; %s unique IDs; %s matching session files |\n' \
  "$(if [[ -f "$session_index" ]]; then printf yes; else printf no; fi)" \
  "$index_records" \
  "$index_thread_name_rows" \
  "$index_unique_ids" \
  "$indexed_session_file_matches"
printf '| .codex-global-state.json | %s | %s project-order; %s saved roots; %s active roots |\n' \
  "$(if [[ -f "$global_state" ]]; then printf yes; else printf no; fi)" \
  "$global_project_order" \
  "$global_saved_roots" \
  "$global_active_roots"

printf '\nSession JSONL shape in checked sample:\n'
printf '%s\n' "- session_meta rows: $session_meta_rows"
printf '%s\n' "- workspace cwd rows: $workspace_rows"
printf '%s\n' "- thread_name_updated rows: $thread_update_rows"
printf '%s\n' "- message rows: $message_rows"
printf '%s\n' "- user message rows: $user_message_rows"
printf '%s\n' "- assistant message rows: $assistant_message_rows"
printf '%s\n' "- request_user_input rows: $input_request_rows"

printf '\nSummary:\n'
if [[ -z "$app" && -z "$codex_cli" ]]; then
  printf '%s\n' '- Result: Codex app and CLI are not installed in standard paths on this Mac.'
elif [[ "$session_count" -eq 0 ]]; then
  printf '%s\n' '- Result: no Codex session JSONL files were found. Open Codex and create a chat before verifying desktop parity.'
elif [[ "$thread_update_rows" -gt 0 || "$index_thread_name_rows" -gt 0 ]]; then
  printf '%s\n' '- Result: Codex state contains thread-name sources for Glasstunnel parser verification.'
  if [[ "$indexed_session_file_matches" -gt 0 ]]; then
    printf '%s\n' '- Result: session_index records match local session filenames, so renamed thread labels can be audited.'
  else
    printf '%s\n' '- Follow-up: session_index exists but no records matched local session filenames; verify live label parity before marking Codex desktop release-ready.'
  fi
else
  printf '%s\n' '- Result: Codex sessions exist but no thread-name source was found. Verify whether Codex changed its local state shape.'
fi

if [[ "$require_label_sources" == "1" || "$require_label_sources" == "true" || "$require_label_sources" == "yes" ]]; then
  if [[ "$thread_update_rows" -gt 0 || "$indexed_session_file_matches" -gt 0 ]]; then
    printf '%s\n' '- Strict label-source check: passed.'
  else
    printf '%s\n' '- Strict label-source check: failed. No checked Codex session had a JSONL thread-name update or matching session_index label source.'
    exit 1
  fi
fi
