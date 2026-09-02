#!/usr/bin/env bash
# Record real app-support release evidence for the support matrix.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_AGENT_APP_EVIDENCE_DIR:-$ROOT_DIR/.cache/glasstunnel-evidence/agent-apps}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: pnpm qa:agent-app:record [--dry-run]

Records raw real-app evidence under ignored .cache/glasstunnel-evidence.
This script does not run the test. Run the real Mac + mobile flow first, then
record the evidence with the environment variables below.

Review and redact the result before manually creating a concise public summary
under docs/release-evidence. Never commit this script's raw output directly.

Required environment:
  GT_AGENT_APP_NAME       One of: Mac Screen, Codex desktop, Codex CLI, Cursor, Cursor Agent, Claude desktop, Claude Code, Gemini CLI, OpenCode, Terminal
  GT_AGENT_APP_RESULT     pass or fail
  GT_AGENT_APP_MAC        Redacted Mac label, for example "test Mac"
  GT_AGENT_APP_MACOS      Mac OS version, for example "macOS 15.5"
  GT_AGENT_APP_VERSION    App or CLI version tested, or "not installed" for missing-app checks
  GT_AGENT_APP_BROWSER    Safari, Chrome, or Mac local
  GT_AGENT_APP_ACCOUNT    Redacted account label, for example "primary test account"
  GT_AGENT_APP_ARTIFACT   Local screenshot, recording, or log path

Optional environment:
  GT_AGENT_APP_EVIDENCE_DIR Override evidence directory.
  GT_AGENT_APP_COMMIT       Commit tested. Defaults to current git commit.
  GT_AGENT_APP_INSTALL_PATH Install path or executable path.
  GT_AGENT_APP_PASSED       Short passed checklist.
  GT_AGENT_APP_FAILED       Short failed checklist.
  GT_AGENT_APP_NOTES        Short notes or follow-up issue refs.
  GT_AGENT_APP_PRIVACY_REVIEW Set to pass only after reviewing the record and
                              copied artifact. Defaults to pending.

For pass results, GT_AGENT_APP_ARTIFACT must point to an existing file and
GT_AGENT_APP_PASSED must summarize the real behavior that passed.
Use --dry-run to print the record without writing a file.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required." >&2
    exit 1
  fi
}

for name in \
  GT_AGENT_APP_NAME \
  GT_AGENT_APP_RESULT \
  GT_AGENT_APP_MAC \
  GT_AGENT_APP_MACOS \
  GT_AGENT_APP_VERSION \
  GT_AGENT_APP_BROWSER \
  GT_AGENT_APP_ACCOUNT \
  GT_AGENT_APP_ARTIFACT; do
  require_env "$name"
done

APP="$GT_AGENT_APP_NAME"
RESULT="$GT_AGENT_APP_RESULT"
BROWSER="$GT_AGENT_APP_BROWSER"
ARTIFACT="$GT_AGENT_APP_ARTIFACT"
COMMIT="${GT_AGENT_APP_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
INSTALL_PATH="${GT_AGENT_APP_INSTALL_PATH:-Not recorded.}"
PASSED="${GT_AGENT_APP_PASSED:-Not recorded.}"
FAILED="${GT_AGENT_APP_FAILED:-Not recorded.}"
NOTES="${GT_AGENT_APP_NOTES:-None.}"
PRIVACY_REVIEW="${GT_AGENT_APP_PRIVACY_REVIEW:-pending}"

case "$APP" in
  "Mac Screen"|"Codex desktop"|"Codex CLI"|"Cursor"|"Cursor Agent"|"Claude desktop"|"Claude Code"|"Gemini CLI"|"OpenCode"|"Terminal") ;;
  *)
    echo "GT_AGENT_APP_NAME must match a supported app row in docs/agent-app-support-matrix.md." >&2
    exit 1
    ;;
esac

case "$RESULT" in
  pass|fail) ;;
  *)
    echo "GT_AGENT_APP_RESULT must be pass or fail." >&2
    exit 1
    ;;
esac

case "$PRIVACY_REVIEW" in
  pending|pass) ;;
  *)
    echo "GT_AGENT_APP_PRIVACY_REVIEW must be pending or pass." >&2
    exit 1
    ;;
esac

case "$BROWSER" in
  Safari|Chrome|"Mac local") ;;
  *)
    echo "GT_AGENT_APP_BROWSER must be Safari, Chrome, or Mac local." >&2
    exit 1
    ;;
esac

normalized_lowercase() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | tr '[:upper:]' '[:lower:]'
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//'
}

if [[ "$RESULT" == "pass" && ! -e "$ARTIFACT" ]]; then
  echo "GT_AGENT_APP_ARTIFACT must point to an existing file for pass results." >&2
  exit 1
fi

if [[ "$RESULT" == "pass" ]]; then
  case "$(normalized_lowercase "$PASSED")" in
    ""|"not recorded."|"none."|"n/a"|"na")
      echo "GT_AGENT_APP_PASSED must summarize what passed for pass results." >&2
      exit 1
      ;;
  esac
fi

require_passed_term() {
  local passed="$1"
  local message="$2"
  shift 2
  local term

  for term in "$@"; do
    case "$passed" in
      *"$term"*) return 0 ;;
    esac
  done

  echo "$message" >&2
  exit 1
}

if [[ "$RESULT" == "pass" ]]; then
  normalized_passed="$(normalized_lowercase "$PASSED")"

  case "$APP" in
    "Codex desktop")
      require_passed_term "$normalized_passed" "Codex desktop pass evidence must mention label/name parity." label name
      require_passed_term "$normalized_passed" "Codex desktop pass evidence must mention prompt delivery." prompt
      require_passed_term "$normalized_passed" "Codex desktop pass evidence must mention status, result, or response updates." status result response
      ;;
    "Codex CLI")
      require_passed_term "$normalized_passed" "Codex CLI pass evidence must mention starting or launching a session." start started launch session
      require_passed_term "$normalized_passed" "Codex CLI pass evidence must mention prompt delivery." prompt
      require_passed_term "$normalized_passed" "Codex CLI pass evidence must mention interrupt, stop, or cancel behavior." interrupt stop cancel
      require_passed_term "$normalized_passed" "Codex CLI pass evidence must mention done, status, result, or response updates." done status result response
      require_passed_term "$normalized_passed" "Codex CLI pass evidence must mention model, runtime, effort, or fast mode behavior." model runtime effort fast
      ;;
    "Cursor")
      require_passed_term "$normalized_passed" "Cursor pass evidence must mention project, chat, context, or target parity." project chat context target
      require_passed_term "$normalized_passed" "Cursor pass evidence must mention prompt or input delivery." prompt input
      require_passed_term "$normalized_passed" "Cursor pass evidence must mention submit, return, or send behavior." submit return send
      require_passed_term "$normalized_passed" "Cursor pass evidence must mention foreground or background behavior." foreground background
      require_passed_term "$normalized_passed" "Cursor pass evidence must mention the visible model or settings." model setting settings composer
      ;;
    "Terminal")
      require_passed_term "$normalized_passed" "Terminal pass evidence must mention command delivery." command
      require_passed_term "$normalized_passed" "Terminal pass evidence must mention output or streaming." output stream
      require_passed_term "$normalized_passed" "Terminal pass evidence must mention long-running command or process behavior." long-running "long running" sleep process
      require_passed_term "$normalized_passed" "Terminal pass evidence must mention interrupt, stop, or cancel behavior." interrupt stop cancel
      require_passed_term "$normalized_passed" "Terminal pass evidence must mention recovery, next-command acceptance, or status after interrupt." recover recovery "next command" "accepts next" status
      ;;
  esac
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
APP_SLUG="$(slugify "$APP")"
BROWSER_SLUG="$(slugify "$BROWSER")"
OUT_FILE="$OUT_DIR/$APP_SLUG-$STAMP-$BROWSER_SLUG-$RESULT.md"
RECORDED_ARTIFACT="$ARTIFACT"

copy_artifact() {
  local source="$1"
  local artifact_dir="$OUT_DIR/artifacts"
  local base
  local safe_base
  local dest

  [[ -e "$source" ]] || return 0

  base="$(basename "$source")"
  safe_base="$(printf '%s' "$base" | tr -c '[:alnum:]._-' '-')"
  dest="$artifact_dir/$APP_SLUG-$STAMP-$BROWSER_SLUG-$RESULT-$safe_base"

  mkdir -p "$artifact_dir"
  cp "$source" "$dest"
  RECORDED_ARTIFACT="artifacts/$(basename "$dest")"
}

if [[ "$DRY_RUN" != "1" ]]; then
  copy_artifact "$ARTIFACT"
fi

RECORD="$(cat <<EOF
# Agent App Release Evidence

- Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- App: $APP
- Result: $RESULT
- Mac: $GT_AGENT_APP_MAC
- macOS: $GT_AGENT_APP_MACOS
- App version: $GT_AGENT_APP_VERSION
- Install path: $INSTALL_PATH
- Mobile browser: $BROWSER
- Test account: $GT_AGENT_APP_ACCOUNT
- Glasstunnel commit: $COMMIT
- Artifact: $RECORDED_ARTIFACT
- Privacy review: $PRIVACY_REVIEW

## Passed

$PASSED

## Failed

$FAILED

## Notes

$NOTES
EOF
)"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s\n' "$RECORD"
else
  mkdir -p "$OUT_DIR"
  printf '%s\n' "$RECORD" > "$OUT_FILE"
  echo "Agent app release evidence: $OUT_FILE"
fi
