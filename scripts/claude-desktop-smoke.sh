#!/usr/bin/env bash
# Privacy-safe Claude desktop app smoke for release verification.
#
# Checks the local contracts the Claude desktop adapter relies on: the app's
# bundle identifier and claude:// URL scheme, desktop-owned transcripts in the
# shared Claude Code store, the user-global hooks Glasstunnel installs, and the
# Claude Code CLI flags the CLI adapter pins sessions with. It never reads
# transcript content beyond the `entrypoint` field and prints no paths outside
# the home-relative install locations.
#
# Set GT_CLAUDE_DESKTOP_LIVE_AX_PROBE=1 to additionally verify, from an
# Accessibility-trusted terminal, that the running Claude window exposes a
# settable composer matching the adapter's placeholder hint. The probe reads
# the composer only; it never writes or submits.
set -euo pipefail

BUNDLE_ID="com.anthropic.claudefordesktop"
COMPOSER_HINT="Ask Claude a question or start a task|Describe a task or ask a question|Prompt"
PROJECTS_ROOT="${GT_CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"
SETTINGS_FILE="${GT_CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
failures=0
blocked=0

row() {
  printf '| %s | %s | %s |\n' "$1" "$2" "$3"
}

fail() {
  row "$1" "fail" "$2"
  failures=$((failures + 1))
}

printf 'Glasstunnel Claude desktop smoke\n'
printf 'Date: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Commit: %s\n\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
printf '| Check | Result | Detail |\n'
printf '| --- | --- | --- |\n'

app_path=""
for candidate in "/Applications/Claude.app" "$HOME/Applications/Claude.app"; do
  if [[ -d "$candidate" ]]; then
    app_path="$candidate"
    break
  fi
done

if [[ -z "$app_path" ]]; then
  fail "Claude.app" "not installed in /Applications or ~/Applications"
else
  installed_bundle="$(defaults read "$app_path/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  if [[ "$installed_bundle" == "$BUNDLE_ID" ]]; then
    row "Claude.app" "pass" "${app_path/#$HOME/~} is $BUNDLE_ID"
  else
    fail "Claude.app" "bundle id is '${installed_bundle:-unknown}', expected $BUNDLE_ID"
  fi

  if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$app_path/Contents/Info.plist" 2>/dev/null | grep -Fq "claude"; then
    row "claude:// scheme" "pass" "registered by the app (code/continue deep links)"
  else
    fail "claude:// scheme" "the app does not register the claude URL scheme"
  fi

  # pgrep cannot always see the Electron process from a sandboxed shell;
  # matching the executable path in ps output is reliable. grep must drain
  # the pipe (no -q): under pipefail an early exit fails the whole check.
  if ps -axo comm= | grep '/Claude\.app/Contents/MacOS/Claude$' >/dev/null; then
    row "Claude running" "pass" "a Claude process is running"
  else
    row "Claude running" "info" "not running; the card launches it on demand"
  fi
fi

if [[ -d "$PROJECTS_ROOT" ]]; then
  counts="$(python3 - "$PROJECTS_ROOT" <<'PY'
import json, os, sys
root = sys.argv[1]
desktop = cli = 0
for dirpath, dirnames, filenames in os.walk(root):
    if "subagents" in dirpath.split(os.sep):
        continue
    for name in filenames:
        if not name.endswith(".jsonl"):
            continue
        entrypoint = None
        try:
            with open(os.path.join(dirpath, name), "rb") as handle:
                for raw in handle.read(256 * 1024).splitlines():
                    try:
                        record = json.loads(raw)
                    except Exception:
                        continue
                    value = record.get("entrypoint")
                    if value:
                        entrypoint = value
                        break
        except OSError:
            continue
        if entrypoint == "claude-desktop":
            desktop += 1
        else:
            cli += 1
print(f"{desktop} {cli}")
PY
)"
  desktop_count="${counts%% *}"
  cli_count="${counts##* }"
  if [[ "$desktop_count" -gt 0 ]]; then
    row "Desktop transcripts" "pass" "$desktop_count desktop-owned, $cli_count other sessions in ~/.claude/projects"
  else
    row "Desktop transcripts" "info" "no desktop-owned sessions yet; start a Claude Code session in the app"
  fi
else
  row "Desktop transcripts" "info" "~/.claude/projects does not exist yet"
fi

if [[ -f "$SETTINGS_FILE" ]]; then
  hook_state="$(python3 - "$SETTINGS_FILE" <<'PY'
import json, sys
try:
    settings = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable")
    sys.exit(0)
hooks = settings.get("hooks", {}) if isinstance(settings, dict) else {}
present = []
forwards_type = True
for event in ("Stop", "SubagentStop", "Notification"):
    entries = json.dumps(hooks.get(event, []))
    if "Glasstunnel/cc.sock" in entries:
        present.append(event)
        forwards_type = forwards_type and "notification_type" in entries
if len(present) == 3:
    print("installed" if forwards_type else "outdated")
elif present:
    print("partial")
else:
    print("missing")
PY
)"
  case "$hook_state" in
    installed) row "Glasstunnel hooks" "pass" "Stop, SubagentStop, and Notification hooks forward notification_type" ;;
    outdated) row "Glasstunnel hooks" "info" "installed by an older build; the next adapter start upgrades them" ;;
    partial) fail "Glasstunnel hooks" "only some Glasstunnel hooks are present in ~/.claude/settings.json" ;;
    missing) row "Glasstunnel hooks" "info" "not installed yet; either Claude card installs them on first start" ;;
    *) row "Glasstunnel hooks" "info" "~/.claude/settings.json could not be read" ;;
  esac
else
  row "Glasstunnel hooks" "info" "~/.claude/settings.json does not exist yet"
fi

claude_path="$(command -v claude 2>/dev/null || true)"
if [[ -n "$claude_path" ]]; then
  help_output="$(claude --help 2>/dev/null || true)"
  if grep -Fq -- "--session-id" <<<"$help_output" && grep -Fq -- "--resume" <<<"$help_output"; then
    row "Claude Code CLI" "pass" "$(claude --version 2>/dev/null | head -1) supports --session-id and --resume"
  else
    fail "Claude Code CLI" "installed CLI lacks --session-id/--resume, which the CLI adapter pins sessions with"
  fi
else
  row "Claude Code CLI" "info" "not installed; only the desktop card is available"
fi

if [[ "${GT_CLAUDE_DESKTOP_LIVE_AX_PROBE:-0}" == "1" ]]; then
  swift_file="$(mktemp -t glasstunnel-claude-desktop-ax.XXXXXX.swift)"
  trap 'rm -f "$swift_file"' EXIT
  cat >"$swift_file" <<'SWIFT'
import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.anthropic.claudefordesktop"
// Several vocabularies separated by "|": the placeholder text of older
// builds, the placeholder of build 1.40609.1, and that build's composer
// accessibility description.
let hint = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : "ask claude|describe a task|prompt"
let hints = hint.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

guard AXIsProcessTrusted() else {
    print("blocked: Accessibility is not trusted for this terminal")
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("blocked: Claude is not running")
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(of element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

var candidates: [String] = []
var matched = false
func walk(_ element: AXUIElement, depth: Int) {
    if depth > 40 || matched { return }
    let role = (attribute(element, kAXRoleAttribute) as? String) ?? ""
    if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let placeholder = (attribute(element, kAXPlaceholderValueAttribute) as? String) ?? ""
        let description = (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
        let label = [placeholder, description].filter { !$0.isEmpty }.joined(separator: " / ")
        candidates.append("\(role) settable=\(settable.boolValue) '\(label.prefix(60))'")
        let haystack = (placeholder + " " + description).lowercased()
        if settable.boolValue, hints.contains(where: { haystack.contains($0) }) {
            matched = true
            return
        }
    }
    for child in children(of: element) { walk(child, depth: depth + 1) }
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let windows = (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = (attribute(appElement, kAXFocusedWindowAttribute) as! AXUIElement?) ?? windows.first else {
    print("fail: Claude has no accessible window")
    exit(1)
}
walk(window, depth: 0)
if matched {
    print("pass: a settable composer matching '\(hint)' is exposed")
    exit(0)
}
print("fail: no settable composer matched '\(hint)'; candidates: \(candidates.prefix(6).joined(separator: " | "))")
exit(1)
SWIFT
  set +e
  probe_output="$(swift "$swift_file" "$COMPOSER_HINT" 2>&1)"
  probe_status=$?
  set -e
  case "$probe_status" in
    0) row "Live composer (AX)" "pass" "${probe_output#pass: }" ;;
    2) row "Live composer (AX)" "blocked" "${probe_output#blocked: }"; blocked=1 ;;
    *) fail "Live composer (AX)" "${probe_output#fail: }" ;;
  esac
else
  row "Live composer (AX)" "skipped" "set GT_CLAUDE_DESKTOP_LIVE_AX_PROBE=1 in an Accessibility-trusted terminal"
fi

printf '\n'
if [[ "$failures" -gt 0 ]]; then
  printf 'Result: fail; %s check(s) failed.\n' "$failures"
  exit 1
fi
if [[ "$blocked" -eq 1 ]]; then
  printf 'Result: partial; local contracts pass, but the live composer probe was blocked.\n'
  exit 0
fi
printf 'Result: pass; Claude desktop local contracts match the adapter.\n'
