#!/usr/bin/env bash
# Run repeatable security/privacy release checks that do not read local secrets.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

run_check() {
  local label="$1"
  shift

  echo "==> $label"
  "$@"
  echo
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing required file: $path" >&2
    return 1
  fi
}

require_text() {
  local path="$1"
  local needle="$2"
  local normalized

  normalized="$(tr '\n\t' '  ' < "$path" | tr -s '[:space:]' ' ')"
  if ! grep -Fqi "$needle" <<<"$normalized"; then
    echo "Missing required security/privacy wording in $path: $needle" >&2
    return 1
  fi
}

reject_text() {
  local path="$1"
  local needle="$2"
  local normalized

  normalized="$(tr '\n\t' '  ' < "$path" | tr -s '[:space:]' ' ')"
  if grep -Fqi "$needle" <<<"$normalized"; then
    echo "Unsupported security/privacy wording in $path: $needle" >&2
    return 1
  fi
}

check_docs() {
  require_file README.md
  require_file SECURITY.md
  require_file docs/security.md
  require_file docs/known-limitations.md
  require_file docs/self-hosting.md

  require_text README.md "end-to-end encrypted"
  require_text README.md "not your code, chats, prompts, or media"
  require_text README.md "**Supported:** Mac Screen and the scoped Terminal shell path"
  require_text README.md "Preview and Experimental paths are included for testing and contribution"

  require_text SECURITY.md "docs/security.md"
  require_text SECURITY.md "security@glasstunnel.io"
  require_text SECURITY.md "Please do not open a public issue"

  require_text docs/security.md "Hosted Cloudflare/Supabase control plane"
  require_text docs/security.md "does not store captured content, prompts, chats, or media"
  require_text docs/security.md "SecretRedactor"
  require_text docs/security.md "best-effort"
  require_text docs/security.md "We do not log captured content, prompts, chats, media, SDP bodies, or ICE candidates"
  require_text docs/security.md "does not include an analytics SDK"
  require_text docs/security.md "hosting providers may still produce their own diagnostic or request logs"
  require_text docs/security.md "self-hosting"
  reject_text docs/security.md "GLASSTUNNEL_CRASH_REPORTS"
  reject_text docs/security.md "billing Pro-tier users"

  require_text docs/known-limitations.md "Preview and Experimental paths are not public-beta promises"
  require_text docs/known-limitations.md "moves to"
  require_text docs/known-limitations.md "Secret redaction is best-effort"
  require_text docs/known-limitations.md "physical-phone checks are optional"
  require_text docs/known-limitations.md "does not prove cellular handoff"
}

check_tracked_secret_files() {
  local offenders=()
  while IFS= read -r path; do
    case "$path" in
      *.env.example|*.env.sample|*.template|*.md)
        continue
        ;;
      */.env|.env|*/.env.*|.env.*|*.pem|*.p12|*.mobileprovision|*.provisionprofile|*id_rsa*|*id_ed25519*|*dev-signing-keychain-password*)
        offenders+=("$path")
        ;;
    esac
  done < <(git ls-files)

  if [[ "${#offenders[@]}" -gt 0 ]]; then
    printf 'Tracked secret-like files are not allowed in release candidates:\n' >&2
    printf '  %s\n' "${offenders[@]}" >&2
    return 1
  fi
}

check_signaling_logs() {
  local files=()
  while IFS= read -r file; do
    files+=("$file")
  done < <(find apps/signaling -type f -name '*.go' ! -path '*/internal/proto/*' -print)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No signaling Go files found." >&2
    return 1
  fi

  local forbidden='log\.(Print|Printf|Println|Fatal|Fatalf).*(env\.Payload([^[:alnum:]_]|$)|env\.Raw|Signature|SDP|sdp|ICE|candidate|prompt|chat|media|captured)'
  local matches
  matches="$(rg -n "$forbidden" "${files[@]}" || true)"
  if [[ -n "$matches" ]]; then
    echo "Signaling logs may expose content-bearing fields:" >&2
    printf '%s\n' "$matches" >&2
    return 1
  fi
}

echo "Glasstunnel security/privacy release audit"
echo "Repo: $ROOT_DIR"
echo "Commit: $(git rev-parse --short HEAD) $(git log -1 --pretty=%s)"
echo "Branch: $(git branch --show-current)"
echo

run_check "Public repository metadata and artifact guard" pnpm qa:public-repo
run_check "Public remote ref guard" pnpm qa:public-remote-refs
run_check "Public security/privacy documentation" check_docs
run_check "Tracked secret-file guard" check_tracked_secret_files
run_check "Signaling log content guard" check_signaling_logs
run_check "Secret redaction tests" swift test --package-path apps/host-macos --filter SecretRedactorTests
run_check "Device revocation tests" swift test --package-path apps/host-macos --filter DeviceRegistryTests
run_check "Envelope trust boundary tests" swift test --package-path apps/host-macos --filter SessionManagerTests
run_check "Normal settings wording boundary" swift test --package-path apps/host-macos --filter SettingsContentPolicyTests

echo "Security/privacy release audit completed."
echo "This is a local automated audit. It does not replace live hosted abuse testing or a third-party security review."
