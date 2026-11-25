#!/usr/bin/env bash
set -euo pipefail

# One-time setup: creates a long-lived self-signed code signing certificate.
#
# macOS TCC (Accessibility, Screen Recording, ...) binds permissions to the bundle id
# plus the signing certificate. Signing every build with this same certificate keeps
# permissions across updates; ad-hoc signatures change on every build and reset them.
#
# Outputs (in $OUT_DIR, git-ignored — back them up, losing the cert resets permissions):
#   cert.p12      certificate + private key
#   password.txt  p12 password
# Also imports the identity into the login keychain so scripts/install.sh can use it.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_NAME="${CERT_NAME:-TeamsWake Code Signing}"
DAYS="${DAYS:-3650}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/.signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
# LibreSSL produces a p12 that `security import` accepts (OpenSSL 3 would need -legacy).
OPENSSL=/usr/bin/openssl

if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$CERT_NAME\""; then
    echo "❌ Identity \"$CERT_NAME\" already exists in $KEYCHAIN." >&2
    echo "   Reuse it instead of creating a new one (a new cert resets users' permissions)." >&2
    echo "   Export it via Keychain Access → My Certificates → Export (.p12) if needed." >&2
    exit 1
fi

if [ -e "$OUT_DIR/cert.p12" ]; then
    echo "❌ $OUT_DIR/cert.p12 already exists; refusing to overwrite." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
    -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

PASSWORD="$("$OPENSSL" rand -hex 24)"
"$OPENSSL" pkcs12 -export -name "$CERT_NAME" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$OUT_DIR/cert.p12" \
    -passout "pass:$PASSWORD" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
printf '%s' "$PASSWORD" > "$OUT_DIR/password.txt"
chmod 600 "$OUT_DIR/cert.p12" "$OUT_DIR/password.txt"

security import "$OUT_DIR/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "=========================================="
echo "  ✅ Created \"$CERT_NAME\" (valid $DAYS days)"
echo "     Imported into $KEYCHAIN"
echo "     Saved to $OUT_DIR (back it up somewhere safe)"
echo ""
echo "  Add GitHub Actions secrets for release signing:"
echo "    gh secret set MACOS_CERT_P12 < <(base64 -i \"$OUT_DIR/cert.p12\")"
echo "    gh secret set MACOS_CERT_PASSWORD < \"$OUT_DIR/password.txt\""
echo "=========================================="
