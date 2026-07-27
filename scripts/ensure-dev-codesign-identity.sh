#!/usr/bin/env bash
# Create or reuse a stable local code-signing identity for development builds.
#
# This is only for local debug bundles. It avoids ad-hoc signatures, whose
# CDHash changes on each rebuild and can make macOS TCC permissions look
# granted in System Settings while the current binary is still treated as new.
set -euo pipefail

IDENTITY_NAME="${GLASSTUNNEL_DEV_CODESIGN_IDENTITY:-Glasstunnel Local Development}"
KEYCHAIN="${GLASSTUNNEL_DEV_CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/glasstunnel-dev-signing.keychain-db}"
PASSWORD_DIR="$HOME/Library/Application Support/Glasstunnel"
PASSWORD_FILE="$PASSWORD_DIR/dev-signing-keychain-password"

log() {
  printf '%s\n' "$*" >&2
}

ensure_password() {
  mkdir -p "$PASSWORD_DIR"
  chmod 700 "$PASSWORD_DIR" 2>/dev/null || true
  if [[ ! -f "$PASSWORD_FILE" ]]; then
    umask 077
    uuidgen > "$PASSWORD_FILE"
  fi
  cat "$PASSWORD_FILE"
}

identity_in_keychain() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -F '"' -v s="$IDENTITY_NAME" 'index($0, s) { print $2; exit }'
}

add_keychain_to_search_list() {
  local found="0"
  local keychain
  local -a keychains=()

  while IFS= read -r keychain; do
    keychain="${keychain#"${keychain%%[![:space:]]*}"}"
    keychain="${keychain%\"}"
    keychain="${keychain#\"}"
    [[ -z "$keychain" ]] && continue
    keychains+=("$keychain")
    [[ "$keychain" == "$KEYCHAIN" ]] && found="1"
  done < <(security list-keychains -d user)

  if [[ "$found" != "1" ]]; then
    security list-keychains -d user -s "$KEYCHAIN" "${keychains[@]}"
  fi
}

create_identity() {
  local password="$1"
  local tmpdir
  tmpdir="$(mktemp -d -t glasstunnel-codesign)"
  trap 'rm -rf "$tmpdir"' RETURN

  cat > "$tmpdir/openssl.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = code_signing
prompt = no

[ dn ]
CN = $IDENTITY_NAME
O = Glasstunnel
C = US

[ code_signing ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CONF

  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmpdir/key.pem" \
    -out "$tmpdir/cert.pem" \
    -config "$tmpdir/openssl.conf" >/dev/null 2>&1

  local p12_password
  p12_password="$(uuidgen)"
  openssl pkcs12 -export \
    -inkey "$tmpdir/key.pem" \
    -in "$tmpdir/cert.pem" \
    -name "$IDENTITY_NAME" \
    -out "$tmpdir/identity.p12" \
    -passout "pass:$p12_password" >/dev/null 2>&1

  security import "$tmpdir/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$p12_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$password" \
    "$KEYCHAIN" >/dev/null
}

PASSWORD="$(ensure_password)"

if [[ ! -f "$KEYCHAIN" ]]; then
  log "==> Creating local development signing keychain"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi

if ! security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" 2>/dev/null; then
  log "==> Recreating local development signing keychain with a fresh saved password"
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
  rm -f "$PASSWORD_FILE"
  PASSWORD="$(ensure_password)"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
security set-keychain-settings -lut 21600 "$KEYCHAIN"
add_keychain_to_search_list

IDENTITY="$(identity_in_keychain)"
if [[ -z "$IDENTITY" ]]; then
  log "==> Creating local development code-signing identity"
  create_identity "$PASSWORD"
  IDENTITY="$(identity_in_keychain)"
  if [[ -z "$IDENTITY" ]]; then
    for _ in {1..10}; do
      sleep 0.5
      IDENTITY="$(identity_in_keychain)"
      [[ -n "$IDENTITY" ]] && break
    done
  fi
else
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$PASSWORD" \
    "$KEYCHAIN" >/dev/null
fi

if [[ -z "$IDENTITY" ]]; then
  log "error: could not create local development code-signing identity"
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || rm -f "$KEYCHAIN"
  rm -f "$PASSWORD_FILE"
  exit 1
fi

printf '%s\n' "$IDENTITY"
