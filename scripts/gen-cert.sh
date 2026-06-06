#!/usr/bin/env bash
# Mint a self-signed "Sprout Dev" code-signing cert in the login keychain and
# regenerate the pinned leaf-cert hash in SigningConstants.swift.
#
# Re-run only when regenerating the cert. Do NOT commit the regenerated hash —
# it is local to this machine; the placeholder in git is what belongs there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${SPROUT_SIGN_IDENTITY:-Sprout Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CONST="$ROOT/Sources/SproutEngine/Loopback/SigningConstants.swift"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "==> generating self-signed cert: $NAME"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf"

# `-legacy`: OpenSSL 3 defaults to a SHA-256/AES PKCS12 MAC that macOS's
# `security import` can't verify; the legacy SHA1/3DES MAC is what the Security
# framework reads. A non-empty passphrase is also required — `security import`
# rejects an empty-password PKCS12 with "MAC verification failed". The pass is a
# throwaway: the .p12 is in a temp dir, imported once, then deleted on exit.
P12_PASS="sprout-dev"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$P12_PASS"

echo "==> importing into login keychain (codesign-accessible)"
# Drop any prior "Sprout Dev" identity first, else two matching identities make
# `codesign -s "Sprout Dev"` ambiguous and abort.
security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

# Leaf SHA-256 over the DER cert — the form the requirement H"..." literal wants.
HASH="$(openssl x509 -in "$TMP/cert.pem" -outform DER \
    | shasum -a 256 | awk '{print $1}' | tr 'a-f' 'A-F')"
echo "==> leaf cert SHA-256: $HASH"

echo "==> rewriting $CONST"
# Replace the 64-hex placeholder/previous value on the leafCertSHA256Hex line.
/usr/bin/sed -i '' -E \
    "s/\"[0-9A-Fa-f]{64}\"/\"$HASH\"/" \
    "$CONST"

echo "==> done. Verify with: git diff $CONST"
echo "    (do not commit the regenerated hash)"
