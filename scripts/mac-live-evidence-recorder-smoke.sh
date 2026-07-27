#!/usr/bin/env bash
# Verify that Mac live evidence recording stores artifacts and rejects weak records.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

is_mac_live_invalidating_path() {
  case "$1" in
    apps/host-macos/*|\
packages/protocol/*|\
scripts/build-app.sh|\
scripts/dev-app.sh|\
scripts/lab/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_mac_live_invalidating_changes() {
  local base="$1"
  local head="$2"
  local path

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if is_mac_live_invalidating_path "$path"; then
      return 0
    fi
  done < <(git -C "$ROOT_DIR" diff --name-only "$base..$head")

  return 1
}

EVIDENCE_DIR="$TMP_DIR/evidence"
SOURCE_ARTIFACT="$TMP_DIR/source run.log"
printf 'fake mac log bytes\n' > "$SOURCE_ARTIFACT"

GT_MAC_LIVE_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_MAC_LIVE_SCOPE="permission-onboarding" \
GT_MAC_LIVE_RESULT="pass" \
GT_MAC_LIVE_MAC="Test Mac" \
GT_MAC_LIVE_MACOS="macOS test" \
GT_MAC_LIVE_APP_VERSION="0.1.0-test" \
GT_MAC_LIVE_BUNDLE_ID="io.glasstunnel.host" \
GT_MAC_LIVE_INSTALL_PATH="/Applications/Glasstunnel.app" \
GT_MAC_LIVE_ARTIFACT="$SOURCE_ARTIFACT" \
GT_MAC_LIVE_COMMIT="testcommit" \
GT_MAC_LIVE_PRIVACY_REVIEW="pass" \
GT_MAC_LIVE_PASSED="Fresh permission state reflected correctly, missing permissions blocked continue, granted permissions enabled auth." \
bash "$ROOT_DIR/scripts/record-mac-live-evidence.sh" >/tmp/glasstunnel-mac-live-evidence-recorder-smoke.log

record_count="$(find "$EVIDENCE_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')"
if [[ "$record_count" != "1" ]]; then
  echo "Expected one Mac live evidence record, found $record_count." >&2
  exit 1
fi

record_file="$(find "$EVIDENCE_DIR" -maxdepth 1 -name '*.md' -type f | head -n1)"
artifact_line="$(grep -m1 -E '^- Artifact: ' "$record_file")"
artifact_path="${artifact_line#- Artifact: }"

case "$artifact_path" in
  artifacts/*.txt) ;;
  *)
    echo "Expected ignored log extension to be stored as a tracked relative .txt artifact, got: $artifact_path" >&2
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

if GT_MAC_LIVE_EVIDENCE_DIR="$TMP_DIR/placeholder-record" \
  GT_MAC_LIVE_SCOPE="auth-relaunch" \
  GT_MAC_LIVE_RESULT="pass" \
  GT_MAC_LIVE_MAC="Test Mac" \
  GT_MAC_LIVE_MACOS="macOS test" \
  GT_MAC_LIVE_APP_VERSION="0.1.0-test" \
  GT_MAC_LIVE_BUNDLE_ID="io.glasstunnel.host" \
  GT_MAC_LIVE_INSTALL_PATH="/Applications/Glasstunnel.app" \
  GT_MAC_LIVE_ARTIFACT="$SOURCE_ARTIFACT" \
  GT_MAC_LIVE_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/record-mac-live-evidence.sh" >/tmp/glasstunnel-mac-live-evidence-placeholder-record.log 2>&1; then
  echo "Expected recorder to reject pass evidence without GT_MAC_LIVE_PASSED." >&2
  exit 1
fi

PLACEHOLDER_EVIDENCE_DIR="$TMP_DIR/placeholder-evidence"
mkdir -p "$PLACEHOLDER_EVIDENCE_DIR/artifacts"
cp "$SOURCE_ARTIFACT" "$PLACEHOLDER_EVIDENCE_DIR/artifacts/placeholder.png"
cat > "$PLACEHOLDER_EVIDENCE_DIR/20260101-000000-auth-relaunch-pass.md" <<'EOF'
# Mac Live QA Evidence

- Date: 2026-01-01T00:00:00Z
- Scope: auth-relaunch
- Result: pass
- Mac: Test Mac
- macOS: macOS test
- Glasstunnel commit: testcommit
- App version: 0.1.0-test
- Bundle ID: io.glasstunnel.host
- Install path: /Applications/Glasstunnel.app
- Test account: redacted test account
- Artifact: artifacts/placeholder.png

## Passed

Not recorded.

## Failed

None.

## Notes

This must not satisfy live Mac evidence.
EOF

if GT_MAC_LIVE_EVIDENCE_DIR="$PLACEHOLDER_EVIDENCE_DIR" \
  GT_MAC_LIVE_REQUIRED_SCOPES="auth-relaunch" \
  GT_MAC_LIVE_REQUIRED_COMMIT="testcommit" \
  bash "$ROOT_DIR/scripts/check-mac-live-evidence.sh" >/tmp/glasstunnel-mac-live-evidence-placeholder-check.log 2>&1; then
  echo "Expected checker to reject pass evidence without a real Passed checklist." >&2
  exit 1
fi

if GT_MAC_LIVE_EVIDENCE_DIR="$EVIDENCE_DIR" \
  GT_MAC_LIVE_REQUIRED_SCOPES="permission-onboarding" \
  GT_MAC_LIVE_REQUIRED_COMMIT="othercommit" \
  bash "$ROOT_DIR/scripts/check-mac-live-evidence.sh" >/tmp/glasstunnel-mac-live-evidence-stale-commit-check.log 2>&1; then
  echo "Expected checker to reject pass evidence from a different commit." >&2
  exit 1
fi

GT_MAC_LIVE_EVIDENCE_DIR="$EVIDENCE_DIR" \
GT_MAC_LIVE_REQUIRED_SCOPES="permission-onboarding" \
GT_MAC_LIVE_REQUIRED_COMMIT="testcommit" \
bash "$ROOT_DIR/scripts/check-mac-live-evidence.sh" >/tmp/glasstunnel-mac-live-evidence-check-smoke.log

if PARENT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD~1 2>/dev/null)"; then
  CURRENT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  ANCESTOR_EVIDENCE_DIR="$TMP_DIR/ancestor-evidence"
  mkdir -p "$ANCESTOR_EVIDENCE_DIR/artifacts"
  cp "$SOURCE_ARTIFACT" "$ANCESTOR_EVIDENCE_DIR/artifacts/ancestor.png"
  cat > "$ANCESTOR_EVIDENCE_DIR/20260101-000000-auth-relaunch-pass.md" <<EOF
# Mac Live QA Evidence

- Date: 2026-01-01T00:00:00Z
- Scope: auth-relaunch
- Result: pass
- Mac: Test Mac
- macOS: macOS test
- Glasstunnel commit: $PARENT_COMMIT
- App version: 0.1.0-test
- Bundle ID: io.glasstunnel.host
- Install path: /Applications/Glasstunnel.app
- Test account: redacted test account
- Artifact: artifacts/ancestor.png
- Privacy review: pass

## Passed

Verified relaunch persistence on the parent code commit.

## Failed

None.

## Notes

The checker should accept this when only non-product files changed since the parent commit.
EOF

  if has_mac_live_invalidating_changes "$PARENT_COMMIT" "$CURRENT_COMMIT"; then
    echo "Skipping ancestor non-product acceptance check because HEAD~1..HEAD contains Mac-live invalidating changes."
  else
    if ! GT_MAC_LIVE_EVIDENCE_DIR="$ANCESTOR_EVIDENCE_DIR" \
      GT_MAC_LIVE_REQUIRED_SCOPES="auth-relaunch" \
      GT_MAC_LIVE_REQUIRED_COMMIT="$CURRENT_COMMIT" \
      bash "$ROOT_DIR/scripts/check-mac-live-evidence.sh" >/tmp/glasstunnel-mac-live-evidence-ancestor-check.log 2>&1; then
      echo "Expected checker to accept ancestor evidence when only non-product files changed." >&2
      cat /tmp/glasstunnel-mac-live-evidence-ancestor-check.log >&2
      exit 1
    fi
  fi
fi

if git -C "$ROOT_DIR" rev-parse --verify --quiet c9b06e5 >/dev/null; then
  CURRENT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  SURFACE_EVIDENCE_DIR="$TMP_DIR/surface-evidence"
  mkdir -p "$SURFACE_EVIDENCE_DIR/artifacts"
  cp "$SOURCE_ARTIFACT" "$SURFACE_EVIDENCE_DIR/artifacts/surface.png"
  cat > "$SURFACE_EVIDENCE_DIR/20260101-000000-permission-onboarding-pass.md" <<'EOF'
# Mac Live QA Evidence

- Date: 2026-01-01T00:00:00Z
- Scope: permission-onboarding
- Result: pass
- Mac: Test Mac
- macOS: macOS test
- Glasstunnel commit: c9b06e5
- App version: 0.1.0-test
- Bundle ID: io.glasstunnel.host
- Install path: /Applications/Glasstunnel.app
- Test account: redacted test account
- Artifact: artifacts/surface.png
- Privacy review: pass

## Passed

Verified permission onboarding on the Mac app code commit.

## Failed

None.

## Notes

The checker should accept this when later commits changed only mobile, docs,
evidence, or non-Mac release checker surfaces.
EOF

  if has_mac_live_invalidating_changes "c9b06e5" "$CURRENT_COMMIT"; then
    echo "Skipping historical non-Mac surface acceptance check because c9b06e5..HEAD contains Mac-live invalidating changes."
  else
    if ! GT_MAC_LIVE_EVIDENCE_DIR="$SURFACE_EVIDENCE_DIR" \
      GT_MAC_LIVE_REQUIRED_SCOPES="permission-onboarding" \
      GT_MAC_LIVE_REQUIRED_COMMIT="$CURRENT_COMMIT" \
      bash "$ROOT_DIR/scripts/check-mac-live-evidence.sh" >/tmp/glasstunnel-mac-live-evidence-surface-check.log 2>&1; then
      echo "Expected checker to accept Mac evidence across non-Mac surface changes." >&2
      cat /tmp/glasstunnel-mac-live-evidence-surface-check.log >&2
      exit 1
    fi
  fi
fi

echo "Mac live evidence recorder smoke passed."
