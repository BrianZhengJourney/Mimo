#!/bin/bash
# One-time, user-authorized setup for a stable local Mimo development identity.
# The private key is non-exportable after import and is limited to codesign.
set -euo pipefail

IDENTITY="Mimo Local Development"
KEYCHAIN="$(security default-keychain -d user | tr -d '"' | xargs)"
case "$KEYCHAIN" in
  /Users/*.keychain|/Users/*.keychain-db) ;;
  *) echo "Could not resolve a safe user keychain path: $KEYCHAIN" >&2; exit 1 ;;
esac

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -Fq "\"$IDENTITY\""; then
  echo "$IDENTITY is already available."
  exit 0
fi

MIMO_SIGNING_TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/mimo-signing.XXXXXX")"
cleanup() {
  case "${MIMO_SIGNING_TMP:-}" in
    "${TMPDIR:-/private/tmp}"/mimo-signing.*)
      /bin/rm -f "$MIMO_SIGNING_TMP/cert.pem" \
        "$MIMO_SIGNING_TMP/key.pem" "$MIMO_SIGNING_TMP/identity.p12"
      /bin/rmdir "$MIMO_SIGNING_TMP" 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT

CERT="$MIMO_SIGNING_TMP/cert.pem"
KEY="$MIMO_SIGNING_TMP/key.pem"
P12="$MIMO_SIGNING_TMP/identity.p12"

# Recover safely from a prior run that imported the identity before its trust
# setting completed. Never delete or replace an existing certificate here.
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$CERT"
else
  MIMO_SIGNING_PASSWORD="$(/usr/bin/openssl rand -hex 32)"
  /usr/bin/openssl req -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
    -subj "/CN=$IDENTITY/O=Mimo Local Development" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$KEY" -out "$CERT"
  /usr/bin/openssl pkcs12 -export -inkey "$KEY" -in "$CERT" -out "$P12" \
    -passout "pass:$MIMO_SIGNING_PASSWORD"
  security import "$P12" -k "$KEYCHAIN" -f pkcs12 \
    -P "$MIMO_SIGNING_PASSWORD" -x \
    -T /usr/bin/codesign -T /usr/bin/security
fi

# User-domain trust, constrained to the code-signing policy. This does not add
# a system/admin trust root and does not grant network or account access.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT"

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
      | grep -Fq "\"$IDENTITY\""; then
  echo "The certificate exists but is not a valid code-signing identity." >&2
  echo "No existing Keychain item was deleted or replaced." >&2
  exit 1
fi

echo "Stable signing identity ready: $IDENTITY"
