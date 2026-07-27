#!/usr/bin/env bash
# Privacy-safe Cursor state audit for release verification.
#
# This reports only schema/table presence and row counts. It intentionally does
# not print composer names, prompts, responses, or JSON values from Cursor's
# databases.
set -euo pipefail

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

sqlite_scalar() {
  local db="$1"
  local sql="$2"
  sqlite3 "$db" "$sql" 2>/dev/null || printf '0'
}

sqlite_yes_no() {
  local db="$1"
  local table="$2"
  local count
  count="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${table}';")"
  if [[ "$count" == "1" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

candidate_databases() {
  local cursor_state="$1"
  local global_db="${cursor_state}/User/globalStorage/state.vscdb"
  if [[ -f "$global_db" ]]; then
    printf '%s\n' "$global_db"
  fi

  local workspace_root="${cursor_state}/User/workspaceStorage"
  if [[ -d "$workspace_root" ]]; then
    find "$workspace_root" -maxdepth 2 -name state.vscdb -type f -print 2>/dev/null \
      | while IFS= read -r db; do
          stat -f '%m %N' "$db"
        done \
      | sort -rn \
      | head -n 3 \
      | sed 's/^[0-9][0-9]* //'
  fi
}

database_label() {
  local index="$1"
  local db="$2"
  if [[ "$db" == *"/User/globalStorage/state.vscdb" ]]; then
    printf 'global-%s' "$index"
  elif [[ "$db" == *"/User/workspaceStorage/"*"/state.vscdb" ]]; then
    printf 'workspace-%s' "$index"
  else
    printf 'database-%s' "$index"
  fi
}

app="$(cursor_app_path || true)"
cursor_state="${CURSOR_STATE_DIR:-$HOME/Library/Application Support/Cursor}"

printf 'Glasstunnel Cursor state audit\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

if [[ -n "$app" ]]; then
  info_plist="${app}/Contents/Info.plist"
  version="$(plist_value "$info_plist" "CFBundleShortVersionString")"
  build="$(plist_value "$info_plist" "CFBundleVersion")"
  printf 'Cursor app: present: %s\n' "$(redact_home "$app")"
  printf 'Cursor version: %s%s\n' "${version:-unknown}" "$(if [[ -n "${build:-}" ]]; then printf ' (%s)' "$build"; fi)"
else
  printf 'Cursor app: missing\n'
  printf 'Cursor version: unknown\n'
fi

printf 'Cursor state dir: %s\n\n' "$(redact_home "$cursor_state")"

if ! command -v sqlite3 >/dev/null 2>&1; then
  printf 'sqlite3: missing; cannot inspect Cursor state databases\n'
  exit 0
fi

databases=()
while IFS= read -r database; do
  databases+=("$database")
done < <(candidate_databases "$cursor_state")
if [[ "${#databases[@]}" -eq 0 ]]; then
  printf 'No Cursor state.vscdb databases found.\n'
  exit 0
fi

printf '| Database | ItemTable | cursorDiskKV | composerData rows | valid composer JSON rows | named rows | title rows | display-name rows | top-level label rows | exact-label source rows | subtitle rows | workspace-id rows | header-only rows | bubble rows | embedded-message rows | ItemTable chat rows |\n'
printf '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n'

total_composer_rows=0
total_valid_composer_json_rows=0
total_named_composer_rows=0
total_title_composer_rows=0
total_display_name_composer_rows=0
total_top_level_label_composer_rows=0
total_exact_label_source_rows=0
total_subtitle_composer_rows=0
total_path_like_subtitle_rows=0
total_workspace_identifier_rows=0
total_workspace_identifier_empty_window_rows=0
total_workspace_identifier_usable_rows=0
total_workspace_identifier_metadata_matches=0
total_workspace_db_composer_rows=0
total_header_rows=0
total_bubble_rows=0
total_embedded_message_rows=0
total_item_chat_rows=0
workspace_json_files=0
workspace_json_file_folders=0

database_index=0
for db in "${databases[@]}"; do
  database_index=$((database_index + 1))
  item_table="$(sqlite_yes_no "$db" "ItemTable")"
  cursor_disk_kv="$(sqlite_yes_no "$db" "cursorDiskKV")"

  composer_rows=0
  valid_composer_json_rows=0
  named_composer_rows=0
  title_composer_rows=0
  display_name_composer_rows=0
  top_level_label_composer_rows=0
  exact_label_source_rows=0
  subtitle_composer_rows=0
  path_like_subtitle_rows=0
  workspace_identifier_rows=0
  workspace_identifier_empty_window_rows=0
  workspace_identifier_usable_rows=0
  workspace_identifier_metadata_matches=0
  header_rows=0
  bubble_rows=0
  embedded_message_rows=0
  item_chat_rows=0

  if [[ "$cursor_disk_kv" == "yes" ]]; then
    composer_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%';")"
    valid_composer_json_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT));")"
    named_composer_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.name')), ''), '') <> '';")"
    title_composer_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.title')), ''), '') <> '';")"
    display_name_composer_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.displayName')), ''), '') <> '';")"
    top_level_label_composer_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.label')), ''), '') <> '';")"
    exact_label_source_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.name')), ''), NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.title')), ''), NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.displayName')), ''), NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.label')), '')) IS NOT NULL;")"
    subtitle_composer_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(json_extract(CAST(value AS TEXT), '$.subtitle')), ''), '') <> '';")"
    path_like_subtitle_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND (TRIM(json_extract(CAST(value AS TEXT), '$.subtitle')) LIKE '/%' OR TRIM(json_extract(CAST(value AS TEXT), '$.subtitle')) LIKE '~%');")"
    workspace_identifier_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND json_type(CAST(value AS TEXT), '$.workspaceIdentifier') IS NOT NULL;")"
    workspace_identifier_empty_window_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND CASE json_type(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'text' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'object' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier.id') ELSE NULL END = 'empty-window';")"
    workspace_identifier_usable_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(CASE json_type(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'text' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'object' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier.id') ELSE NULL END), ''), '') NOT IN ('', 'empty-window');")"
    header_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND CAST(value AS TEXT) LIKE '%fullConversationHeadersOnly%';")"
    bubble_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'bubbleId:%';")"
    embedded_message_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND (CAST(value AS TEXT) LIKE '%\"messages\"%' OR CAST(value AS TEXT) LIKE '%\"chatMessages\"%' OR CAST(value AS TEXT) LIKE '%\"tabs\"%');")"

    while IFS= read -r workspace_identifier; do
      [[ -n "$workspace_identifier" ]] || continue
      [[ "$workspace_identifier" != "empty-window" ]] || continue
      workspace_json="${cursor_state}/User/workspaceStorage/${workspace_identifier}/workspace.json"
      if [[ -f "$workspace_json" ]] && grep -Eq '"folder"[[:space:]]*:[[:space:]]*"file://' "$workspace_json"; then
        workspace_identifier_metadata_matches=$((workspace_identifier_metadata_matches + 1))
      fi
    done < <(sqlite3 "$db" "SELECT DISTINCT CASE json_type(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'text' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'object' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier.id') ELSE NULL END FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(CAST(value AS TEXT)) AND COALESCE(NULLIF(TRIM(CASE json_type(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'text' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier') WHEN 'object' THEN json_extract(CAST(value AS TEXT), '$.workspaceIdentifier.id') ELSE NULL END), ''), '') NOT IN ('', 'empty-window');" 2>/dev/null || true)
  fi

  if [[ "$item_table" == "yes" ]]; then
    item_chat_rows="$(sqlite_scalar "$db" "SELECT COUNT(*) FROM ItemTable WHERE key LIKE 'composerData:%' OR key LIKE 'workbench.panel.aichat%' OR key LIKE 'aichat.%' OR key LIKE 'cursor.chat%' OR key LIKE 'cursor.composer%';")"
  fi

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(database_label "$database_index" "$db")" \
    "$item_table" \
    "$cursor_disk_kv" \
    "$composer_rows" \
    "$valid_composer_json_rows" \
    "$named_composer_rows" \
    "$title_composer_rows" \
    "$display_name_composer_rows" \
    "$top_level_label_composer_rows" \
    "$exact_label_source_rows" \
    "$subtitle_composer_rows" \
    "$workspace_identifier_rows" \
    "$header_rows" \
    "$bubble_rows" \
    "$embedded_message_rows" \
    "$item_chat_rows"

  total_composer_rows=$((total_composer_rows + composer_rows))
  total_valid_composer_json_rows=$((total_valid_composer_json_rows + valid_composer_json_rows))
  total_named_composer_rows=$((total_named_composer_rows + named_composer_rows))
  total_title_composer_rows=$((total_title_composer_rows + title_composer_rows))
  total_display_name_composer_rows=$((total_display_name_composer_rows + display_name_composer_rows))
  total_top_level_label_composer_rows=$((total_top_level_label_composer_rows + top_level_label_composer_rows))
  total_exact_label_source_rows=$((total_exact_label_source_rows + exact_label_source_rows))
  total_subtitle_composer_rows=$((total_subtitle_composer_rows + subtitle_composer_rows))
  total_path_like_subtitle_rows=$((total_path_like_subtitle_rows + path_like_subtitle_rows))
  total_workspace_identifier_rows=$((total_workspace_identifier_rows + workspace_identifier_rows))
  total_workspace_identifier_empty_window_rows=$((total_workspace_identifier_empty_window_rows + workspace_identifier_empty_window_rows))
  total_workspace_identifier_usable_rows=$((total_workspace_identifier_usable_rows + workspace_identifier_usable_rows))
  total_workspace_identifier_metadata_matches=$((total_workspace_identifier_metadata_matches + workspace_identifier_metadata_matches))
  total_header_rows=$((total_header_rows + header_rows))
  total_bubble_rows=$((total_bubble_rows + bubble_rows))
  total_embedded_message_rows=$((total_embedded_message_rows + embedded_message_rows))
  total_item_chat_rows=$((total_item_chat_rows + item_chat_rows))

  if [[ "$db" == *"/User/workspaceStorage/"*"/state.vscdb" ]]; then
    total_workspace_db_composer_rows=$((total_workspace_db_composer_rows + composer_rows))
    workspace_json="${db%/state.vscdb}/workspace.json"
    if [[ -f "$workspace_json" ]]; then
      workspace_json_files=$((workspace_json_files + 1))
      if grep -Eq '"folder"[[:space:]]*:[[:space:]]*"file://' "$workspace_json"; then
        workspace_json_file_folders=$((workspace_json_file_folders + 1))
      fi
    fi
  fi
done

printf '\nSummary:\n'
printf '%s\n' "- Databases checked: ${#databases[@]}"
printf '%s\n' "- workspace metadata files checked: $workspace_json_files"
printf '%s\n' "- workspace metadata file-folder rows: $workspace_json_file_folders"
printf '%s\n' "- composerData rows: $total_composer_rows"
printf '%s\n' "- valid composer JSON rows: $total_valid_composer_json_rows"
printf '%s\n' "- named composer rows: $total_named_composer_rows"
printf '%s\n' "- title composer rows: $total_title_composer_rows"
printf '%s\n' "- display-name composer rows: $total_display_name_composer_rows"
printf '%s\n' "- top-level label composer rows: $total_top_level_label_composer_rows"
printf '%s\n' "- exact-label source composer rows: $total_exact_label_source_rows"
printf '%s\n' "- subtitle composer rows: $total_subtitle_composer_rows"
printf '%s\n' "- path-like subtitle composer rows: $total_path_like_subtitle_rows"
printf '%s\n' "- workspace-id composer rows: $total_workspace_identifier_rows"
printf '%s\n' "- empty-window workspace-id rows: $total_workspace_identifier_empty_window_rows"
printf '%s\n' "- usable workspace-id rows: $total_workspace_identifier_usable_rows"
printf '%s\n' "- usable workspace-id metadata matches: $total_workspace_identifier_metadata_matches"
printf '%s\n' "- workspace database composer rows: $total_workspace_db_composer_rows"
printf '%s\n' "- header-only composer rows: $total_header_rows"
printf '%s\n' "- bubble rows: $total_bubble_rows"
printf '%s\n' "- embedded-message composer rows: $total_embedded_message_rows"
printf '%s\n' "- ItemTable chat rows: $total_item_chat_rows"

if [[ -z "$app" ]]; then
  printf '%s\n' '- Result: Cursor is not installed in a standard Applications path on this Mac.'
elif [[ "$total_composer_rows" -gt 0 || "$total_item_chat_rows" -gt 0 ]]; then
  printf '%s\n' '- Result: Cursor state contains chat-shaped rows for Glasstunnel parser verification.'
  if [[ "$total_bubble_rows" -eq 0 ]]; then
    printf '%s\n' '- Follow-up: no separate bubble rows were found; verify a live Cursor conversation before marking message parity release-ready.'
  fi
  if [[ "$total_header_rows" -gt 0 && "$total_bubble_rows" -eq 0 && "$total_embedded_message_rows" -eq 0 ]]; then
    printf '%s\n' '- Follow-up: header-only composer rows have no matching bubble rows or embedded message arrays; this audit proves target discovery only, not message content parity.'
  fi
  if [[ "$total_composer_rows" -gt 0 && "$total_named_composer_rows" -eq 0 && "$total_subtitle_composer_rows" -eq 0 ]]; then
    printf '%s\n' '- Follow-up: composer rows do not expose names or subtitles; keep generated fallback labels and do not claim exact Cursor label parity.'
  elif [[ "$total_valid_composer_json_rows" -gt 0 && "$total_exact_label_source_rows" -eq 0 && "$total_subtitle_composer_rows" -eq 0 ]]; then
    printf '%s\n' '- Follow-up: valid composer rows expose no top-level exact label sources or subtitles; keep generated fallback labels and do not claim exact Cursor label parity.'
  elif [[ "$total_valid_composer_json_rows" -gt 0 && "$total_exact_label_source_rows" -lt "$total_valid_composer_json_rows" ]]; then
    printf '%s\n' '- Follow-up: only some valid composer rows expose top-level exact label sources; keep generated fallback labels and do not claim full Cursor label parity.'
  elif [[ "$total_composer_rows" -gt 0 && "$total_subtitle_composer_rows" -lt "$total_composer_rows" ]]; then
    printf '%s\n' '- Follow-up: only some composer rows expose subtitles; do not claim full Cursor project-path parity.'
  fi
  project_path_source_candidates=$((total_path_like_subtitle_rows + total_workspace_identifier_metadata_matches + total_workspace_db_composer_rows))
  if [[ "$workspace_json_file_folders" -gt 0 && "$project_path_source_candidates" -eq 0 ]]; then
    printf '%s\n' '- Follow-up: workspace metadata exposes file-backed project folders, but current composer rows do not link to those folders.'
  elif [[ "$workspace_json_file_folders" -gt 0 ]]; then
    printf '%s\n' '- Follow-up: workspace metadata exposes file-backed project folders; verify the Mac adapter publishes linked paths without treating generated chat labels as exact Cursor labels.'
  fi
  if [[ "$project_path_source_candidates" -eq 0 ]]; then
    printf '%s\n' '- Follow-up: current composer rows expose no usable project-path source; keep Cursor project-path parity unclaimed.'
  else
    printf '%s\n' '- Follow-up: current composer rows expose project-path source candidates; verify live watcher publication before claiming project-path parity.'
  fi
else
  printf '%s\n' '- Result: no chat-shaped Cursor rows were found. Open a Cursor chat and send one message, then rerun this audit.'
fi

if [[ "${GT_CURSOR_STATE_REQUIRE_PROJECT_PATH_TRUTH:-0}" =~ ^(1|true|yes)$ ]]; then
  project_path_source_candidates=$((total_path_like_subtitle_rows + total_workspace_identifier_metadata_matches + total_workspace_db_composer_rows))
  if [[ -z "$app" || "$total_composer_rows" -eq 0 ]]; then
    printf '%s\n' '- Project-path truth: failed; Cursor install or composer rows are missing.'
    exit 1
  fi
  if [[ "$project_path_source_candidates" -gt 0 ]]; then
    printf '%s\n' '- Project-path truth: failed; usable project-path source candidates exist and must be verified through the live watcher.'
    exit 1
  fi
  printf '%s\n' '- Project-path truth: passed; current Cursor composer rows expose no usable project-path source.'
fi

if [[ "${GT_CURSOR_STATE_REQUIRE_LABEL_SOURCE_AVAILABILITY:-0}" =~ ^(1|true|yes)$ ]]; then
  if [[ -z "$app" || "$total_valid_composer_json_rows" -eq 0 ]]; then
    printf '%s\n' '- Label-source availability: failed; Cursor install or valid composer rows are missing.'
    exit 1
  fi
  printf '%s\n' '- Label-source availability: passed; top-level exact label sources were counted separately from subtitles and fallback metadata.'
fi
