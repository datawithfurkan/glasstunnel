#!/usr/bin/env bash
# Smoke-test the agent-app release-ready claim guard with fixture matrices.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EVIDENCE_DIR="$TMP_DIR/evidence"
MATRIX_FILE="$TMP_DIR/agent-app-support-matrix.md"
SOURCE_ARTIFACT="$TMP_DIR/codex evidence.png"
COMMIT="testcommit"

mkdir -p "$EVIDENCE_DIR"
printf 'fake evidence bytes\n' > "$SOURCE_ARTIFACT"

cat > "$MATRIX_FILE" <<'EOF'
# Agent App Support Matrix

## Support Summary

| App / Feature | Current repo support | Current status | Release-ready? | Primary risk |
| --- | --- | --- | --- | --- |
| Codex desktop | Window-backed desktop adapter | Needs real test | No | Needs mobile pass |
EOF

GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_REQUIRED_COMMIT="$COMMIT" \
bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-current.log

cat > "$MATRIX_FILE" <<'EOF'
# Agent App Support Matrix

## Support Summary

| App / Feature | Current repo support | Current status | Release-ready? | Primary risk |
| --- | --- | --- | --- | --- |
| Codex desktop | Window-backed desktop adapter | Release-ready | Yes | None recorded |
EOF

if GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
  GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
  GT_AGENT_APP_REQUIRED_COMMIT="$COMMIT" \
  bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-missing.log 2>&1; then
  echo "Expected release-ready claim without evidence to fail." >&2
  exit 1
fi

cat > "$EVIDENCE_DIR/codex-desktop-stale.md" <<'EOF'
# Agent App Release Evidence

- App: Codex desktop
- Result: pass
- Glasstunnel commit: oldcommit
- Mobile browser: Safari
- Artifact: artifacts/missing-stale.png

## Passed

Project labels matched and prompt delivery worked.
EOF

if GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
  GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
  GT_AGENT_APP_REQUIRED_COMMIT="$COMMIT" \
  bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-stale.log 2>&1; then
  echo "Expected release-ready claim with stale evidence to fail." >&2
  exit 1
fi

if GT_AGENT_APP_EVIDENCE_DIR="$TMP_DIR/placeholder-record" \
  GT_AGENT_APP_NAME="Codex desktop" \
  GT_AGENT_APP_RESULT="pass" \
  GT_AGENT_APP_MAC="Test Mac" \
  GT_AGENT_APP_MACOS="macOS test" \
  GT_AGENT_APP_VERSION="Codex test" \
  GT_AGENT_APP_BROWSER="Safari" \
  GT_AGENT_APP_ACCOUNT="redacted test account" \
  GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
  GT_AGENT_APP_COMMIT="$COMMIT" \
  bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-placeholder-record.log 2>&1; then
  echo "Expected recorder to reject pass evidence without GT_AGENT_APP_PASSED." >&2
  exit 1
fi

if GT_AGENT_APP_EVIDENCE_DIR="$TMP_DIR/incomplete-codex-record" \
  GT_AGENT_APP_NAME="Codex desktop" \
  GT_AGENT_APP_RESULT="pass" \
  GT_AGENT_APP_MAC="Test Mac" \
  GT_AGENT_APP_MACOS="macOS test" \
  GT_AGENT_APP_VERSION="Codex test" \
  GT_AGENT_APP_BROWSER="Safari" \
  GT_AGENT_APP_ACCOUNT="redacted test account" \
  GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
  GT_AGENT_APP_COMMIT="$COMMIT" \
  GT_AGENT_APP_PASSED="Project labels matched and prompt delivery worked." \
  bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-incomplete-codex-record.log 2>&1; then
  echo "Expected recorder to reject Codex desktop pass evidence without status/result/response updates." >&2
  exit 1
fi

if GT_AGENT_APP_EVIDENCE_DIR="$TMP_DIR/incomplete-codex-cli-record" \
  GT_AGENT_APP_NAME="Codex CLI" \
  GT_AGENT_APP_RESULT="pass" \
  GT_AGENT_APP_MAC="Test Mac" \
  GT_AGENT_APP_MACOS="macOS test" \
  GT_AGENT_APP_VERSION="Codex CLI test" \
  GT_AGENT_APP_BROWSER="Safari" \
  GT_AGENT_APP_ACCOUNT="redacted test account" \
  GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
  GT_AGENT_APP_COMMIT="$COMMIT" \
  GT_AGENT_APP_PASSED="Started a session and delivered a prompt." \
  bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-incomplete-codex-cli-record.log 2>&1; then
  echo "Expected recorder to reject Codex CLI pass evidence without interrupt/done/runtime coverage." >&2
  exit 1
fi

if GT_AGENT_APP_EVIDENCE_DIR="$TMP_DIR/incomplete-cursor-record" \
  GT_AGENT_APP_NAME="Cursor" \
  GT_AGENT_APP_RESULT="pass" \
  GT_AGENT_APP_MAC="Test Mac" \
  GT_AGENT_APP_MACOS="macOS test" \
  GT_AGENT_APP_VERSION="Cursor test" \
  GT_AGENT_APP_BROWSER="Safari" \
  GT_AGENT_APP_ACCOUNT="redacted test account" \
  GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
  GT_AGENT_APP_COMMIT="$COMMIT" \
  GT_AGENT_APP_PASSED="Project context matched and prompt input appeared." \
  bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-incomplete-cursor-record.log 2>&1; then
  echo "Expected recorder to reject Cursor pass evidence without submit/foreground-background coverage." >&2
  exit 1
fi

if GT_AGENT_APP_EVIDENCE_DIR="$TMP_DIR/incomplete-cursor-model-record" \
  GT_AGENT_APP_NAME="Cursor" \
  GT_AGENT_APP_RESULT="pass" \
  GT_AGENT_APP_MAC="Test Mac" \
  GT_AGENT_APP_MACOS="macOS test" \
  GT_AGENT_APP_VERSION="Cursor test" \
  GT_AGENT_APP_BROWSER="Safari" \
  GT_AGENT_APP_ACCOUNT="redacted test account" \
  GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
  GT_AGENT_APP_COMMIT="$COMMIT" \
  GT_AGENT_APP_PASSED="Project target matched, prompt input arrived, submit sent it, and foreground/background behavior stayed correct." \
  bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-incomplete-cursor-model-record.log 2>&1; then
  echo "Expected recorder to reject Cursor pass evidence without visible model/settings coverage." >&2
  exit 1
fi

if GT_AGENT_APP_EVIDENCE_DIR="$TMP_DIR/incomplete-terminal-record" \
  GT_AGENT_APP_NAME="Terminal" \
  GT_AGENT_APP_RESULT="pass" \
  GT_AGENT_APP_MAC="Test Mac" \
  GT_AGENT_APP_MACOS="macOS test" \
  GT_AGENT_APP_VERSION="/bin/zsh" \
  GT_AGENT_APP_BROWSER="Safari" \
  GT_AGENT_APP_ACCOUNT="redacted test account" \
  GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
  GT_AGENT_APP_COMMIT="$COMMIT" \
  GT_AGENT_APP_PASSED="Command output streamed." \
  bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-incomplete-terminal-record.log 2>&1; then
  echo "Expected recorder to reject Terminal pass evidence without long-running interrupt/recovery coverage." >&2
  exit 1
fi

cat > "$EVIDENCE_DIR/terminal-incomplete.md" <<EOF
# Agent App Release Evidence

- App: Terminal
- Result: pass
- Glasstunnel commit: $COMMIT
- Mobile browser: Safari
- Artifact: artifacts/terminal-incomplete.png

## Passed

Command output streamed.
EOF
mkdir -p "$EVIDENCE_DIR/artifacts"
printf 'fake terminal artifact\n' > "$EVIDENCE_DIR/artifacts/terminal-incomplete.png"

cat > "$MATRIX_FILE" <<'EOF'
# Agent App Support Matrix

## Support Summary

| App / Feature | Current repo support | Current status | Release-ready? | Primary risk |
| --- | --- | --- | --- | --- |
| Terminal | PTY-backed shell feature | Release-ready | Yes | None recorded |
EOF

if GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
  GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
  GT_AGENT_APP_REQUIRED_COMMIT="$COMMIT" \
  bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-terminal-incomplete-claims.log 2>&1; then
  echo "Expected release-ready Terminal claim with incomplete pass evidence to fail." >&2
  exit 1
fi

GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_NAME="Codex desktop" \
GT_AGENT_APP_RESULT="pass" \
GT_AGENT_APP_MAC="Test Mac" \
GT_AGENT_APP_MACOS="macOS test" \
GT_AGENT_APP_VERSION="Codex test" \
GT_AGENT_APP_BROWSER="Safari" \
GT_AGENT_APP_ACCOUNT="redacted test account" \
GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
GT_AGENT_APP_COMMIT="$COMMIT" \
GT_AGENT_APP_INSTALL_PATH="/Applications/Codex.app" \
GT_AGENT_APP_PRIVACY_REVIEW="pass" \
GT_AGENT_APP_PASSED="Project labels matched, prompt delivery worked, and status updated." \
bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-record.log

GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_NAME="Codex CLI" \
GT_AGENT_APP_RESULT="pass" \
GT_AGENT_APP_MAC="Test Mac" \
GT_AGENT_APP_MACOS="macOS test" \
GT_AGENT_APP_VERSION="Codex CLI test" \
GT_AGENT_APP_BROWSER="Safari" \
GT_AGENT_APP_ACCOUNT="redacted test account" \
GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
GT_AGENT_APP_COMMIT="$COMMIT" \
GT_AGENT_APP_INSTALL_PATH="/usr/local/bin/codex" \
GT_AGENT_APP_PRIVACY_REVIEW="pass" \
GT_AGENT_APP_PASSED="Started a session, delivered a prompt, interrupted it, saw done status, and changed model effort runtime settings." \
bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-codex-cli-record.log

GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_NAME="Cursor" \
GT_AGENT_APP_RESULT="pass" \
GT_AGENT_APP_MAC="Test Mac" \
GT_AGENT_APP_MACOS="macOS test" \
GT_AGENT_APP_VERSION="Cursor test" \
GT_AGENT_APP_BROWSER="Safari" \
GT_AGENT_APP_ACCOUNT="redacted test account" \
GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
GT_AGENT_APP_COMMIT="$COMMIT" \
GT_AGENT_APP_INSTALL_PATH="/Applications/Cursor.app" \
GT_AGENT_APP_PRIVACY_REVIEW="pass" \
GT_AGENT_APP_PASSED="Project target matched, prompt input arrived, submit sent it, foreground/background behavior stayed correct, and the visible Composer model/settings were recorded." \
bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-cursor-record.log

GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_NAME="Terminal" \
GT_AGENT_APP_RESULT="pass" \
GT_AGENT_APP_MAC="Test Mac" \
GT_AGENT_APP_MACOS="macOS test" \
GT_AGENT_APP_VERSION="/bin/zsh" \
GT_AGENT_APP_BROWSER="Safari" \
GT_AGENT_APP_ACCOUNT="redacted test account" \
GT_AGENT_APP_ARTIFACT="$SOURCE_ARTIFACT" \
GT_AGENT_APP_COMMIT="$COMMIT" \
GT_AGENT_APP_INSTALL_PATH="/bin/zsh" \
GT_AGENT_APP_PRIVACY_REVIEW="pass" \
GT_AGENT_APP_PASSED="Command delivery worked, output streamed, a long-running process was interrupted, and status recovered for the next command." \
bash "$ROOT_DIR/scripts/record-agent-app-evidence.sh" >/tmp/glasstunnel-agent-app-terminal-record.log

record_count="$(find "$EVIDENCE_DIR" -maxdepth 1 -name 'codex-desktop-*-safari-pass.md' -type f | wc -l | tr -d ' ')"
if [[ "$record_count" != "1" ]]; then
  echo "Expected one Codex desktop evidence record, found $record_count." >&2
  exit 1
fi

record_file="$(find "$EVIDENCE_DIR" -maxdepth 1 -name 'codex-desktop-*-safari-pass.md' -type f | head -n1)"
artifact_line="$(grep -m1 -E '^- Artifact: ' "$record_file")"
artifact_path="${artifact_line#- Artifact: }"

case "$artifact_path" in
  artifacts/*) ;;
  *)
    echo "Expected artifact path to be stored relative to evidence directory, got: $artifact_path" >&2
    exit 1
    ;;
esac

if [[ ! -f "$EVIDENCE_DIR/$artifact_path" ]]; then
  echo "Expected copied evidence artifact at $EVIDENCE_DIR/$artifact_path." >&2
  exit 1
fi

if ! cmp -s "$SOURCE_ARTIFACT" "$EVIDENCE_DIR/$artifact_path"; then
  echo "Copied app evidence artifact does not match source artifact." >&2
  exit 1
fi

cat > "$MATRIX_FILE" <<'EOF'
# Agent App Support Matrix

## Support Summary

| App / Feature | Current repo support | Current status | Release-ready? | Primary risk |
| --- | --- | --- | --- | --- |
| Codex desktop | Window-backed desktop adapter | Release-ready | Yes | None recorded |
| Codex CLI | PTY adapter | Release-ready | Yes | None recorded |
| Cursor | App/window detection | Release-ready | Yes | None recorded |
| Terminal | PTY-backed shell feature | Release-ready | Yes | None recorded |
EOF

GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_REQUIRED_COMMIT="$COMMIT" \
bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-pass.log

GIT_FIXTURE="$TMP_DIR/git-fixture"
mkdir -p "$GIT_FIXTURE/docs"
git -C "$GIT_FIXTURE" init -q
git -C "$GIT_FIXTURE" config user.name "Glasstunnel Test"
git -C "$GIT_FIXTURE" config user.email "test@glasstunnel.local"
printf 'tested implementation\n' > "$GIT_FIXTURE/product.txt"
git -C "$GIT_FIXTURE" add product.txt
git -C "$GIT_FIXTURE" commit -qm "implementation"
IMPLEMENTATION_COMMIT="$(git -C "$GIT_FIXTURE" rev-parse --short HEAD)"
printf 'release claim\n' > "$GIT_FIXTURE/docs/release.md"
git -C "$GIT_FIXTURE" add docs/release.md
git -C "$GIT_FIXTURE" commit -qm "docs claim"
DOCS_COMMIT="$(git -C "$GIT_FIXTURE" rev-parse --short HEAD)"

cat > "$MATRIX_FILE" <<'EOF'
# Agent App Support Matrix

## Support Summary

| App / Feature | Current repo support | Current status | Release-ready? | Primary risk |
| --- | --- | --- | --- | --- |
| Codex desktop | Window-backed desktop adapter | Release-ready | Yes | None recorded |
EOF

cat > "$EVIDENCE_DIR/codex-desktop-docs-descendant.md" <<EOF
# Agent App Release Evidence

- App: Codex desktop
- Result: pass
- Glasstunnel commit: $IMPLEMENTATION_COMMIT
- Mobile browser: Safari
- Artifact: $artifact_path
- Privacy review: pass

## Passed

Project labels matched, prompt delivery worked, and status updated.
EOF

GT_AGENT_APP_REPO_DIR="$GIT_FIXTURE" \
GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_REQUIRED_COMMIT="$DOCS_COMMIT" \
bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-docs-descendant.log

mkdir -p "$GIT_FIXTURE/scripts"
printf 'release packaging only\n' > "$GIT_FIXTURE/scripts/build-app.sh"
git -C "$GIT_FIXTURE" add scripts/build-app.sh
git -C "$GIT_FIXTURE" commit -qm "release process change"
RELEASE_PROCESS_COMMIT="$(git -C "$GIT_FIXTURE" rev-parse --short HEAD)"

GT_AGENT_APP_REPO_DIR="$GIT_FIXTURE" \
GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_REQUIRED_COMMIT="$RELEASE_PROCESS_COMMIT" \
bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-release-process-descendant.log

printf 'mobile evidence checker only\n' > "$GIT_FIXTURE/scripts/check-real-mobile-evidence.sh"
git -C "$GIT_FIXTURE" add scripts/check-real-mobile-evidence.sh
git -C "$GIT_FIXTURE" commit -qm "mobile evidence process change"
MOBILE_EVIDENCE_PROCESS_COMMIT="$(git -C "$GIT_FIXTURE" rev-parse --short HEAD)"

GT_AGENT_APP_REPO_DIR="$GIT_FIXTURE" \
GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_AGENT_APP_REQUIRED_COMMIT="$MOBILE_EVIDENCE_PROCESS_COMMIT" \
bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-mobile-evidence-process-descendant.log

printf 'changed after evidence\n' >> "$GIT_FIXTURE/product.txt"
git -C "$GIT_FIXTURE" add product.txt
git -C "$GIT_FIXTURE" commit -qm "product change"
PRODUCT_COMMIT="$(git -C "$GIT_FIXTURE" rev-parse --short HEAD)"

if GT_AGENT_APP_REPO_DIR="$GIT_FIXTURE" \
  GT_AGENT_APP_MATRIX="$MATRIX_FILE" \
  GT_AGENT_APP_EVIDENCE_DIR="$EVIDENCE_DIR" \
  GT_AGENT_APP_REQUIRED_COMMIT="$PRODUCT_COMMIT" \
  bash "$ROOT_DIR/scripts/check-agent-app-release-claims.sh" >/tmp/glasstunnel-agent-app-claims-product-descendant.log 2>&1; then
  echo "Expected evidence to become stale after a product-code change." >&2
  exit 1
fi

echo "Agent-app release claim smoke passed."
