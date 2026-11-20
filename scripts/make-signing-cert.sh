#!/usr/bin/env bash
# Crée (une seule fois) un certificat de signature auto-signé dans le trousseau de session.
#
# Pourquoi : sans compte développeur Apple, la signature « ad hoc » change à chaque compilation,
# et macOS oublie alors les autorisations accordées (accès complet au disque…) à chaque mise à jour.
# Avec ce certificat, l'identité de L’Atelier reste la même d'une version à l'autre :
#   - les autorisations sont conservées ;
#   - la mise à jour intégrée vérifie que la nouvelle version est signée par ce même certificat.
#
# Il ne supprime PAS l'avertissement de Gatekeeper au premier lancement (seule la notarisation
# d'Apple le fait). Gardez une sauvegarde du .p12 produit : le perdre, c'est changer d'identité.
#
#   scripts/make-signing-cert.sh                 → « L’Atelier Self-Signed »
#   CERT_NAME="Mon nom" scripts/make-signing-cert.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${CERT_NAME:-L’Atelier Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OUT="${CERT_BACKUP_DIR:-$HOME/.latelier-signing}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ Le certificat « $NAME » existe déjà dans le trousseau."
    echo "  Pour signer : SIGN_IDENTITY=\"$NAME\" make dmg"
    exit 0
fi

OPENSSL="$(command -v openssl)"
mkdir -p "$OUT"
chmod 700 "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$("$(command -v openssl)" rand -hex 16)"

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
utf8 = yes
string_mask = utf8only
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# Le trousseau de macOS ne lit que l'ancien chiffrement PKCS#12.
LEGACY=""
"$OPENSSL" version | grep -q "^OpenSSL 3" && LEGACY="-legacy"
"$OPENSSL" pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$OUT/latelier-signing.p12" -passout "pass:$PASS"
printf '%s\n' "$PASS" > "$OUT/latelier-signing.password"
chmod 600 "$OUT/latelier-signing.p12" "$OUT/latelier-signing.password"

security import "$OUT/latelier-signing.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "✓ Certificat « $NAME » ajouté au trousseau de session."
echo "  Sauvegarde : $OUT/latelier-signing.p12 (mot de passe dans latelier-signing.password)."
echo "  Mettez-les à l'abri (gestionnaire de mots de passe) : sans eux, une nouvelle identité"
echo "  obligerait chaque utilisateur à réinstaller L’Atelier et à redonner ses autorisations."
echo
echo "  Pour signer : SIGN_IDENTITY=\"$NAME\" make dmg"
