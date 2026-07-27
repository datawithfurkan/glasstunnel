#!/usr/bin/env bash
# Audit local agent app availability using the same install concepts the Mac
# host publishes to the web UI: app bundles and CLI executables on this Mac.
set -euo pipefail

check_command() {
  local executable="$1"
  command -v "$executable" 2>/dev/null || true
}

check_app_path() {
  local app_name="$1"
  local dirs="${GT_LOCAL_APP_SEARCH_DIRS:-/Applications:$HOME/Applications}"
  local dir
  local path
  IFS=':' read -r -a search_dirs <<< "$dirs"
  for dir in "${search_dirs[@]}"; do
    [[ -z "$dir" ]] && continue
    path="${dir%/}/${app_name}.app"
    if [[ -d "$path" ]]; then
      printf '%s' "$path"
      return 0
    fi
  done
  return 1
}

stable_app_path() {
  local app_path="$1"
  local dirs="${GT_LOCAL_APP_SEARCH_DIRS:-/Applications:$HOME/Applications:/System/Applications}"
  local app_parent app_name dir root

  [[ "$app_path" == *.app ]] || return 1
  app_parent="$(cd "$(dirname "$app_path")" 2>/dev/null && pwd -P)" || return 1
  app_name="$(basename "$app_path")"
  app_path="$app_parent/$app_name"

  IFS=':' read -r -a search_dirs <<< "$dirs"
  for dir in "${search_dirs[@]}"; do
    [[ -z "$dir" ]] && continue
    root="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    [[ "$app_path" == "$root/"* ]] && return 0
  done
  return 1
}

check_nsworkspace_bundle_path() {
  local expected_csv="$1"
  local resolved
  local -a expected_ids

  [[ "${GT_LOCAL_APP_USE_NSWORKSPACE:-1}" == "1" ]] || return 1
  command -v swift >/dev/null 2>&1 || return 1

  IFS=',' read -r -a expected_ids <<< "$expected_csv"
  if [[ -n "${GT_LOCAL_APP_NSWORKSPACE_RESULT+x}" ]]; then
    resolved="$GT_LOCAL_APP_NSWORKSPACE_RESULT"
  else
    resolved="$(
      swift -e 'import AppKit; import Foundation; for id in CommandLine.arguments.dropFirst() { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { print(url.path); exit(0) } }; exit(1)' \
        "${expected_ids[@]}" 2>/dev/null || true
    )"
  fi
  if [[ -n "$resolved" ]] && stable_app_path "$resolved"; then
    printf '%s' "$resolved"
    return 0
  fi
  return 1
}

check_bundle_path() {
  local app_name="$1"
  local expected_csv="$2"
  local app_path

  app_path="$(check_app_path "$app_name" || true)"
  if [[ -n "$app_path" ]]; then
    printf '%s' "$app_path"
    return 0
  fi

  check_nsworkspace_bundle_path "$expected_csv"
}

check_file() {
  local path="$1"
  [[ -x "$path" ]] && printf '%s' "$path"
}

bundle_id() {
  local app_path="$1"
  [[ -n "$app_path" ]] || return 0
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true
}

bundle_allowed() {
  local bundle="$1"
  local expected_csv="$2"
  local expected
  IFS=',' read -r -a expected_ids <<< "$expected_csv"
  for expected in "${expected_ids[@]}"; do
    [[ "$bundle" == "$expected" ]] && return 0
  done
  return 1
}

app_detail() {
  local app_path="$1"
  local expected_csv="$2"
  local app_bundle
  if [[ -z "$app_path" ]]; then
    printf '-'
    return
  fi
  app_bundle="$(bundle_id "$app_path")"
  if [[ -z "$app_bundle" ]]; then
    printf '%s (bundle ID unknown; expected %s)' "$app_path" "$expected_csv"
  elif bundle_allowed "$app_bundle" "$expected_csv"; then
    printf '%s (bundle ID %s)' "$app_path" "$app_bundle"
  else
    printf '%s (bundle ID mismatch: %s; expected %s)' "$app_path" "$app_bundle" "$expected_csv"
  fi
}

app_publish_state() {
  local app_path="$1"
  local expected_csv="$2"
  local present_text="$3"
  local missing_text="$4"
  local app_bundle
  if [[ -z "$app_path" ]]; then
    printf '%s' "$missing_text"
    return
  fi
  app_bundle="$(bundle_id "$app_path")"
  if [[ -n "$app_bundle" ]] && bundle_allowed "$app_bundle" "$expected_csv"; then
    printf '%s' "$present_text"
  else
    printf 'do not publish; bundle ID mismatch'
  fi
}

status() {
  local value="$1"
  if [[ -n "$value" ]]; then
    printf 'present'
  else
    printf 'missing'
  fi
}

detail() {
  local value="$1"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '-'
  fi
}

codex_app="$(check_bundle_path "Codex" "com.openai.codex" || true)"
cursor_app="$(check_bundle_path "Cursor" "com.todesktop.230313mzl4w4u92" || true)"
claude_app="$(check_bundle_path "Claude" "com.anthropic.claudecode,com.anthropic.claudecode.macos" || true)"
opencode_app="$(check_bundle_path "OpenCode" "ai.opencode.app,ai.opencode.desktop,dev.opencode.cli" || true)"

codex_cli="$(check_command "codex")"
claude_cli="$(check_command "claude")"
gemini_cli="$(check_command "gemini")"
opencode_cli="$(check_command "opencode")"
opencode_cli="${opencode_cli:-$(check_file "$HOME/.volta/bin/opencode" || true)}"
opencode_cli="${opencode_cli:-$(check_file "$HOME/.local/bin/opencode" || true)}"
opencode_cli="${opencode_cli:-$(check_file "$HOME/.cargo/bin/opencode" || true)}"
opencode_cli="${opencode_cli:-$(check_file "$HOME/.bun/bin/opencode" || true)}"
opencode_cli="${opencode_cli:-$(check_file "$HOME/.npm-global/bin/opencode" || true)}"
opencode_cli="${opencode_cli:-$(check_file "/Applications/OpenCode.app/Contents/MacOS/opencode-cli" || true)}"
opencode_cli="${opencode_cli:-$(check_file "$HOME/Applications/OpenCode.app/Contents/MacOS/opencode-cli" || true)}"
terminal_shell="${SHELL:-}"
terminal_shell="${terminal_shell:-$(check_file "/bin/zsh" || true)}"

printf 'Glasstunnel local app availability audit\n'
printf 'Mac: %s\n' "$(scutil --get ComputerName 2>/dev/null || hostname)"
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

printf '| App / feature | Bundle | CLI / executable | Expected local publish state |\n'
printf '| --- | --- | --- | --- |\n'
printf '| Codex desktop | %s: %s | - | %s |\n' "$(status "$codex_app")" "$(app_detail "$codex_app" "com.openai.codex")" "$(app_publish_state "$codex_app" "com.openai.codex" "publish for launch; available when a Codex window is detected" "do not publish unless a Codex window is detected")"
printf '| Cursor | %s: %s | - | %s |\n' "$(status "$cursor_app")" "$(app_detail "$cursor_app" "com.todesktop.230313mzl4w4u92")" "$(app_publish_state "$cursor_app" "com.todesktop.230313mzl4w4u92" "publish for launch; available when a Cursor window is detected" "do not publish unless a Cursor window is detected")"
printf '| Codex CLI | - | %s: %s | %s |\n' "$(status "$codex_cli")" "$(detail "$codex_cli")" "$(if [[ -n "$codex_cli" ]]; then printf 'publish as available'; else printf 'do not publish'; fi)"
printf '| Claude Code | %s: %s | %s: %s | %s |\n' "$(status "$claude_app")" "$(app_detail "$claude_app" "com.anthropic.claudecode,com.anthropic.claudecode.macos")" "$(status "$claude_cli")" "$(detail "$claude_cli")" "$(if [[ -n "$claude_cli" ]]; then printf 'publish; available only when CLI exists'; elif [[ -n "$claude_app" ]]; then app_publish_state "$claude_app" "com.anthropic.claudecode,com.anthropic.claudecode.macos" "publish; install CLI to make available" "do not publish"; else printf 'do not publish'; fi)"
printf '| Gemini CLI | - | %s: %s | %s |\n' "$(status "$gemini_cli")" "$(detail "$gemini_cli")" "$(if [[ -n "$gemini_cli" ]]; then printf 'publish as available'; else printf 'do not publish'; fi)"
printf '| OpenCode | %s: %s | %s: %s | %s |\n' "$(status "$opencode_app")" "$(app_detail "$opencode_app" "ai.opencode.app,ai.opencode.desktop,dev.opencode.cli")" "$(status "$opencode_cli")" "$(detail "$opencode_cli")" "$(if [[ -n "$opencode_cli" ]]; then printf 'publish; available only when CLI exists'; elif [[ -n "$opencode_app" ]]; then app_publish_state "$opencode_app" "ai.opencode.app,ai.opencode.desktop,dev.opencode.cli" "publish; available only when CLI exists" "do not publish"; else printf 'do not publish'; fi)"
printf '| Terminal | - | %s: %s | %s |\n' "$(status "$terminal_shell")" "$(detail "$terminal_shell")" "$(if [[ -n "$terminal_shell" ]]; then printf 'publish as available'; else printf 'do not publish'; fi)"
