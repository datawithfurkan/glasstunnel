#!/usr/bin/env bash
# Verify that real-phone evidence recording stores artifacts with the record.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EVIDENCE_DIR="$TMP_DIR/evidence"
SIMULATOR_EVIDENCE_DIR="$TMP_DIR/simulator-evidence"
SOURCE_ARTIFACT="$TMP_DIR/source screenshot.png"
printf 'fake screenshot bytes\n' > "$SOURCE_ARTIFACT"

if GT_REAL_MOBILE_EVIDENCE_DIR="$SIMULATOR_EVIDENCE_DIR" \
  GT_REAL_MOBILE_BROWSER="Safari" \
  GT_REAL_MOBILE_RESULT="pass" \
  GT_REAL_MOBILE_SCOPE="screen-sharing" \
  GT_REAL_MOBILE_DEVICE="iPhone Simulator" \
  GT_REAL_MOBILE_OS="iOS 18.5 Simulator" \
  GT_REAL_MOBILE_MAC="Test Mac" \
  GT_REAL_MOBILE_MACOS="macOS test" \
  GT_REAL_MOBILE_SCREENSHOT="$SOURCE_ARTIFACT" \
  GT_REAL_MOBILE_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/record-real-mobile-qa.sh" >/tmp/glasstunnel-mobile-evidence-simulator-record.log 2>&1; then
  echo "Expected recorder to reject simulator-labelled pass evidence." >&2
  exit 1
fi

mkdir -p "$SIMULATOR_EVIDENCE_DIR/artifacts"
cp "$SOURCE_ARTIFACT" "$SIMULATOR_EVIDENCE_DIR/artifacts/simulator.png"
cat > "$SIMULATOR_EVIDENCE_DIR/20260101-000000-safari-screen-sharing-pass.md" <<'EOF'
# Real Mobile QA Evidence

- Date: 2026-01-01T00:00:00Z
- Scope: screen-sharing
- Result: pass
- Browser: Safari
- Phone: iPhone Simulator
- Phone OS: iOS 18.5 Simulator
- Mac: Test Mac
- macOS: macOS test
- Glasstunnel commit: testcommit
- URL: https://app.glasstunnel.io
- Test account: redacted test account
- Screenshot or recording: artifacts/simulator.png

## Passed

Simulator-only.

## Failed

None.

## Notes

This must not satisfy real-phone evidence.
EOF

if GT_REAL_MOBILE_EVIDENCE_DIR="$SIMULATOR_EVIDENCE_DIR" \
  GT_REAL_MOBILE_REQUIRED_BROWSERS="Safari" \
  GT_REAL_MOBILE_REQUIRED_SCOPES="screen-sharing" \
  GT_REAL_MOBILE_REQUIRED_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-simulator-check.log 2>&1; then
  echo "Expected checker to reject simulator-labelled pass evidence." >&2
  exit 1
fi

GT_REAL_MOBILE_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_REAL_MOBILE_BROWSER="Safari" \
GT_REAL_MOBILE_RESULT="pass" \
GT_REAL_MOBILE_SCOPE="screen-sharing" \
GT_REAL_MOBILE_DEVICE="iPhone test" \
GT_REAL_MOBILE_OS="iOS test" \
GT_REAL_MOBILE_MAC="Test Mac" \
GT_REAL_MOBILE_MACOS="macOS test" \
GT_REAL_MOBILE_SCREENSHOT="$SOURCE_ARTIFACT" \
GT_REAL_MOBILE_COMMIT="testcommit" \
GT_REAL_MOBILE_PASSED="Screen rendered, tap input worked, stop cleared the stream." \
bash "$ROOT_DIR/scripts/record-real-mobile-qa.sh" >/tmp/glasstunnel-mobile-evidence-recorder-smoke.log

record_count="$(find "$EVIDENCE_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')"
if [[ "$record_count" != "1" ]]; then
  echo "Expected one mobile evidence record, found $record_count." >&2
  exit 1
fi

record_file="$(find "$EVIDENCE_DIR" -maxdepth 1 -name '*.md' -type f | head -n1)"
artifact_line="$(grep -m1 -E '^- Screenshot or recording: ' "$record_file")"
artifact_path="${artifact_line#- Screenshot or recording: }"

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
  echo "Copied artifact does not match source artifact." >&2
  exit 1
fi

PLACEHOLDER_EVIDENCE_DIR="$TMP_DIR/placeholder-evidence"
mkdir -p "$PLACEHOLDER_EVIDENCE_DIR/artifacts"
cp "$SOURCE_ARTIFACT" "$PLACEHOLDER_EVIDENCE_DIR/artifacts/placeholder.png"
cat > "$PLACEHOLDER_EVIDENCE_DIR/20260101-000000-safari-screen-sharing-pass.md" <<'EOF'
# Real Mobile QA Evidence

- Date: 2026-01-01T00:00:00Z
- Scope: screen-sharing
- Result: pass
- Browser: Safari
- Phone: iPhone test
- Phone OS: iOS test
- Mac: Test Mac
- macOS: macOS test
- Glasstunnel commit: testcommit
- URL: https://app.glasstunnel.io
- Test account: redacted test account
- Screenshot or recording: artifacts/placeholder.png

## Passed

Not recorded.

## Failed

None.

## Notes

This must not satisfy real-phone evidence.
EOF

if GT_REAL_MOBILE_EVIDENCE_DIR="$PLACEHOLDER_EVIDENCE_DIR" \
  GT_REAL_MOBILE_REQUIRED_BROWSERS="Safari" \
  GT_REAL_MOBILE_REQUIRED_SCOPES="screen-sharing" \
  GT_REAL_MOBILE_REQUIRED_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-placeholder-check.log 2>&1; then
  echo "Expected checker to reject pass evidence without a real Passed checklist." >&2
  exit 1
fi

if GT_REAL_MOBILE_EVIDENCE_DIR="$TMP_DIR/placeholder-record" \
  GT_REAL_MOBILE_BROWSER="Safari" \
  GT_REAL_MOBILE_RESULT="pass" \
  GT_REAL_MOBILE_SCOPE="screen-sharing" \
  GT_REAL_MOBILE_DEVICE="iPhone test" \
  GT_REAL_MOBILE_OS="iOS test" \
  GT_REAL_MOBILE_MAC="Test Mac" \
  GT_REAL_MOBILE_MACOS="macOS test" \
  GT_REAL_MOBILE_SCREENSHOT="$SOURCE_ARTIFACT" \
  GT_REAL_MOBILE_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/record-real-mobile-qa.sh" >/tmp/glasstunnel-mobile-evidence-placeholder-record.log 2>&1; then
  echo "Expected recorder to reject pass evidence without GT_REAL_MOBILE_PASSED." >&2
  exit 1
fi

GT_REAL_MOBILE_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_REAL_MOBILE_REQUIRED_BROWSERS="Safari" \
GT_REAL_MOBILE_REQUIRED_SCOPES="screen-sharing" \
GT_REAL_MOBILE_REQUIRED_COMMIT="othercommit" \
bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-stale-commit-check.log 2>&1 && {
  echo "Expected checker to reject pass evidence from a different commit." >&2
  exit 1
}

GT_REAL_MOBILE_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_REAL_MOBILE_REQUIRED_BROWSERS="Safari" \
GT_REAL_MOBILE_REQUIRED_SCOPES="screen-sharing" \
GT_REAL_MOBILE_REQUIRED_COMMIT="testcommit" \
bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-check-smoke.log

WEAK_TERMINAL_SESSION_EVIDENCE_DIR="$TMP_DIR/weak-terminal-session-evidence"
GT_REAL_MOBILE_EVIDENCE_DIR="$WEAK_TERMINAL_SESSION_EVIDENCE_DIR" \
GT_REAL_MOBILE_BROWSER="Chrome" \
GT_REAL_MOBILE_RESULT="pass" \
GT_REAL_MOBILE_SCOPE="terminal-session-controls" \
GT_REAL_MOBILE_DEVICE="iPhone test" \
GT_REAL_MOBILE_OS="iOS test" \
GT_REAL_MOBILE_MAC="Test Mac" \
GT_REAL_MOBILE_MACOS="macOS test" \
GT_REAL_MOBILE_SCREENSHOT="$SOURCE_ARTIFACT" \
GT_REAL_MOBILE_COMMIT="testcommit" \
GT_REAL_MOBILE_PASSED="Opened Terminal from the phone." \
bash "$ROOT_DIR/scripts/record-real-mobile-qa.sh" >/tmp/glasstunnel-mobile-evidence-weak-terminal-session-record.log

if GT_REAL_MOBILE_EVIDENCE_DIR="$WEAK_TERMINAL_SESSION_EVIDENCE_DIR" \
  GT_REAL_MOBILE_REQUIRED_BROWSERS="Chrome" \
  GT_REAL_MOBILE_REQUIRED_SCOPES="terminal-session-controls" \
  GT_REAL_MOBILE_REQUIRED_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-weak-terminal-session-check.log 2>&1; then
  echo "Expected checker to reject terminal-session-controls evidence without the full session-control journey." >&2
  exit 1
fi

TERMINAL_SESSION_EVIDENCE_DIR="$TMP_DIR/terminal-session-evidence"
GT_REAL_MOBILE_EVIDENCE_DIR="$TERMINAL_SESSION_EVIDENCE_DIR" \
GT_REAL_MOBILE_BROWSER="Chrome" \
GT_REAL_MOBILE_RESULT="pass" \
GT_REAL_MOBILE_SCOPE="terminal-session-controls" \
GT_REAL_MOBILE_DEVICE="iPhone test" \
GT_REAL_MOBILE_OS="iOS test" \
GT_REAL_MOBILE_MAC="Test Mac" \
GT_REAL_MOBILE_MACOS="macOS test" \
GT_REAL_MOBILE_SCREENSHOT="$SOURCE_ARTIFACT" \
GT_REAL_MOBILE_COMMIT="testcommit" \
GT_REAL_MOBILE_PASSED="Opened Terminal, sent a command and saw marker output, interrupted a long-running command, created Terminal 2, switched back to Default Terminal, renamed the active session, closed Terminal 2, and closed the default session." \
bash "$ROOT_DIR/scripts/record-real-mobile-qa.sh" >/tmp/glasstunnel-mobile-evidence-terminal-session-record.log

GT_REAL_MOBILE_EVIDENCE_DIR="$TERMINAL_SESSION_EVIDENCE_DIR" \
GT_REAL_MOBILE_REQUIRED_BROWSERS="Chrome" \
GT_REAL_MOBILE_REQUIRED_SCOPES="terminal-session-controls" \
GT_REAL_MOBILE_REQUIRED_COMMIT="testcommit" \
bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-terminal-session-check.log

EMPTY_ARTIFACT_EVIDENCE_DIR="$TMP_DIR/empty-artifact-evidence"
mkdir -p "$EMPTY_ARTIFACT_EVIDENCE_DIR/artifacts"
: > "$EMPTY_ARTIFACT_EVIDENCE_DIR/artifacts/empty.png"
cat > "$EMPTY_ARTIFACT_EVIDENCE_DIR/20260101-000000-chrome-terminal-session-controls-pass.md" <<EOF
# Real Mobile QA Evidence

- Date: 2026-01-01T00:00:00Z
- Scope: terminal-session-controls
- Result: pass
- Browser: Chrome
- Phone: iPhone test
- Phone OS: iOS test
- Mac: Test Mac
- macOS: macOS test
- Glasstunnel commit: testcommit
- URL: https://app.glasstunnel.io
- Test account: redacted test account
- Screenshot or recording: artifacts/empty.png

## Passed

Opened Terminal, sent a command and saw marker output, interrupted a long-running command, created Terminal 2, switched back to Default Terminal, renamed the active session, closed Terminal 2, and closed the default session.

## Failed

None.

## Notes

The checker should reject pass evidence whose referenced artifact exists but is empty.
EOF

if GT_REAL_MOBILE_EVIDENCE_DIR="$EMPTY_ARTIFACT_EVIDENCE_DIR" \
  GT_REAL_MOBILE_REQUIRED_BROWSERS="Chrome" \
  GT_REAL_MOBILE_REQUIRED_SCOPES="terminal-session-controls" \
  GT_REAL_MOBILE_REQUIRED_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-empty-artifact-check.log 2>&1; then
  echo "Expected checker to reject real-mobile pass evidence with an empty screenshot or recording artifact." >&2
  exit 1
fi

FIXTURE_REPO="$TMP_DIR/evidence-repo"
ANCESTOR_EVIDENCE_DIR="$TMP_DIR/ancestor-evidence"
mkdir -p "$FIXTURE_REPO/docs" "$ANCESTOR_EVIDENCE_DIR/artifacts"
git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name "Glasstunnel QA"
git -C "$FIXTURE_REPO" config user.email "qa@glasstunnel.test"
printf 'baseline\n' > "$FIXTURE_REPO/docs/baseline.md"
git -C "$FIXTURE_REPO" add docs/baseline.md
git -C "$FIXTURE_REPO" commit -qm "baseline"
EVIDENCE_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse --short HEAD)"

cp "$SOURCE_ARTIFACT" "$ANCESTOR_EVIDENCE_DIR/artifacts/ancestor.png"
cat > "$ANCESTOR_EVIDENCE_DIR/20260101-000000-safari-screen-sharing-pass.md" <<EOF
# Real Mobile QA Evidence

- Date: 2026-01-01T00:00:00Z
- Scope: screen-sharing
- Result: pass
- Browser: Safari
- Phone: iPhone test
- Phone OS: iOS test
- Mac: Test Mac
- macOS: macOS test
- Glasstunnel commit: $EVIDENCE_COMMIT
- URL: https://app.glasstunnel.io
- Test account: redacted test account
- Screenshot or recording: artifacts/ancestor.png

## Passed

Screen rendered on a physical phone, tap input worked, and stop cleared the stream.

## Failed

None.

## Notes

The checker should accept this after a docs-only descendant commit.
EOF

printf 'docs-only change\n' > "$FIXTURE_REPO/docs/release-note.md"
git -C "$FIXTURE_REPO" add docs/release-note.md
git -C "$FIXTURE_REPO" commit -qm "docs only"
DOCS_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse --short HEAD)"

if ! GT_REAL_MOBILE_REPO_DIR="$FIXTURE_REPO" \
  GT_REAL_MOBILE_EVIDENCE_DIR="$ANCESTOR_EVIDENCE_DIR" \
  GT_REAL_MOBILE_REQUIRED_BROWSERS="Safari" \
  GT_REAL_MOBILE_REQUIRED_SCOPES="screen-sharing" \
  GT_REAL_MOBILE_REQUIRED_COMMIT="$DOCS_COMMIT" \
  bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-ancestor-check.log 2>&1; then
  echo "Expected checker to accept ancestor real-phone evidence after docs-only changes." >&2
  cat /tmp/glasstunnel-mobile-evidence-ancestor-check.log >&2
  exit 1
fi

mkdir -p "$FIXTURE_REPO/apps/test"
printf 'product change\n' > "$FIXTURE_REPO/apps/test/source.txt"
git -C "$FIXTURE_REPO" add apps/test/source.txt
git -C "$FIXTURE_REPO" commit -qm "product change"
PRODUCT_COMMIT="$(git -C "$FIXTURE_REPO" rev-parse --short HEAD)"

if GT_REAL_MOBILE_REPO_DIR="$FIXTURE_REPO" \
  GT_REAL_MOBILE_EVIDENCE_DIR="$ANCESTOR_EVIDENCE_DIR" \
  GT_REAL_MOBILE_REQUIRED_BROWSERS="Safari" \
  GT_REAL_MOBILE_REQUIRED_SCOPES="screen-sharing" \
  GT_REAL_MOBILE_REQUIRED_COMMIT="$PRODUCT_COMMIT" \
  bash "$ROOT_DIR/scripts/check-real-mobile-evidence.sh" >/tmp/glasstunnel-mobile-evidence-product-change-check.log 2>&1; then
  echo "Expected checker to reject ancestor real-phone evidence after product changes." >&2
  exit 1
fi

echo "Mobile evidence recorder smoke passed."
