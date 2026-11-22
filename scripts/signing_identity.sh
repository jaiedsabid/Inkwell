#!/bin/bash
# The fixed identity every Inkwell build is signed with, so macOS sees each update as the same app.
#
#   scripts/signing_identity.sh create          make the identity in your login keychain (once)
#   scripts/signing_identity.sh show            say whether it exists, and print its fingerprint
#   scripts/signing_identity.sh export FILE     save it (with its private key) to FILE.p12, for a backup and for CI
#
# Why: an ad-hoc signature ("codesign --sign -") is different for every build, so macOS treats each build as a new app and forgets what you allowed it (Accessibility access, the API key in the Keychain). A certificate that never changes gives every build the same identity. It is self-signed, so it
# does not make Gatekeeper's warning go away (that needs Apple's notarization); it only keeps those permissions across builds and updates.
#
# Keep the exported .p12 and its password somewhere safe, such as a password manager. If the key is lost, the next release has a new
# identity and every user has to allow those again, once.
set -euo pipefail

NAME="Inkwell Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

fingerprint() { security find-identity -p codesigning 2>/dev/null | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}'; }

case "${1:-}" in
  show)
    if [ -n "$(fingerprint)" ]; then echo "$NAME: $(fingerprint)"; else echo "No \"$NAME\" identity in your keychain. Run: scripts/signing_identity.sh create"; exit 1; fi
    ;;
  create)
    if [ -n "$(fingerprint)" ]; then echo "\"$NAME\" already exists: $(fingerprint)"; exit 0; fi
    DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
    cat > "$DIR/cs.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -days 7300 -config "$DIR/cs.cnf" 2>/dev/null
    PASS="$(uuidgen)"
    openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout "pass:$PASS" -legacy 2>/dev/null \
      || openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -passout "pass:$PASS"
    security import "$DIR/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
    echo "Created \"$NAME\": $(fingerprint)"
    echo "The first build may ask to let codesign use the key: choose Always Allow."
    echo "Now back it up:  scripts/signing_identity.sh export ~/Desktop/inkwell-signing"
    ;;
  export)
    OUT="${2:?usage: signing_identity.sh export FILE (without .p12)}"
    [ -n "$(fingerprint)" ] || { echo "No \"$NAME\" identity to export. Run create first." >&2; exit 1; }
    # Set EXPORT_PASSWORD to skip the question (for example when a script runs this).
    PW="${EXPORT_PASSWORD:-}"
    if [ -z "$PW" ]; then read -r -s -p "Choose a password for the backup file: " PW; echo; fi
    DIR="$(mktemp -d)"; chmod 700 "$DIR"; trap 'rm -rf "$DIR"' EXIT
    # macOS can only export every identity in a keychain at once. Take out just this one, so the backup never holds anything else of yours.
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$DIR/cert.pem"
    security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PW" -o "$DIR/all.p12" >/dev/null
    openssl pkcs12 -legacy -in "$DIR/all.p12" -passin "pass:$PW" -nocerts -nodes -out "$DIR/keys.pem" 2>/dev/null \
      || openssl pkcs12 -in "$DIR/all.p12" -passin "pass:$PW" -nocerts -nodes -out "$DIR/keys.pem"
    WANT="$(openssl x509 -in "$DIR/cert.pem" -pubkey -noout | openssl sha256)"
    awk -v d="$DIR" '/-----BEGIN [A-Z ]*PRIVATE KEY-----/{n++; f=sprintf("%s/key%d.pem", d, n)} f{print > f} /-----END [A-Z ]*PRIVATE KEY-----/{f=""}' "$DIR/keys.pem"
    KEY=""
    for k in "$DIR"/key[0-9]*.pem; do
      [ -e "$k" ] || continue
      if [ "$(openssl pkey -in "$k" -pubout 2>/dev/null | openssl sha256)" = "$WANT" ]; then KEY="$k"; break; fi
    done
    [ -n "$KEY" ] || { echo "Could not find the private key for \"$NAME\" in your keychain." >&2; exit 1; }
    openssl pkcs12 -export -inkey "$KEY" -in "$DIR/cert.pem" -name "$NAME" -out "$OUT.p12" -passout "pass:$PW" -legacy 2>/dev/null \
      || openssl pkcs12 -export -inkey "$KEY" -in "$DIR/cert.pem" -name "$NAME" -out "$OUT.p12" -passout "pass:$PW"
    chmod 600 "$OUT.p12"
    echo "Saved $OUT.p12 with only the \"$NAME\" identity. Store it and its password in your password manager."
    echo "For CI, add two repository secrets:"
    echo "  SIGNING_P12_BASE64    = the output of: base64 -i $OUT.p12 | pbcopy"
    echo "  SIGNING_P12_PASSWORD  = the password you just chose"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 2
    ;;
esac
