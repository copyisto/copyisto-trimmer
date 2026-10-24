#!/bin/bash
# Makes the repository secrets that sign, notarise and publish releases, with Apple's web pages only:
# no Xcode, no Apple account on this Mac, nothing in the keychain. Keys are made here, signed by Apple,
# and go straight to GitHub without being printed. RELEASING.md walks through it.
#
#   scripts/signing.sh request EMAIL           a private key and a signing request for developer.apple.com
#   scripts/signing.sh certificate FILE.cer    MACOS_CERTIFICATE and MACOS_CERTIFICATE_PASSWORD from Apple's certificate
#   scripts/signing.sh notary FILE.p8 ISSUER   NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER_ID from an App Store Connect API key
#   scripts/signing.sh tap                     HOMEBREW_TAP_KEY, a deploy key that lets a release update copyisto/homebrew-tap
#
# SIGNING_DIR  where the private key waits between request and certificate (default ~/copyisto-signing)
set -euo pipefail
repo=copyisto/copyisto-trimmer
tap=copyisto/homebrew-tap
dir="${SIGNING_DIR:-$HOME/copyisto-signing}"
# LibreSSL, which writes a .p12 that the keychain on the CI runner can import; Homebrew's OpenSSL 3 needs -legacy for that.
openssl=/usr/bin/openssl

fail() { echo "$*" >&2; exit 1; }

case "${1:-}" in
request)
  email="${2:?usage: scripts/signing.sh request EMAIL}"
  [[ -e "$dir/developer-id.key" ]] && fail "$dir/developer-id.key already exists; upload $dir/developer-id.csr, or remove the folder to start over."
  mkdir -p "$dir" && chmod 700 "$dir"
  (umask 077 && "$openssl" genrsa -out "$dir/developer-id.key" 2048 2>/dev/null)
  "$openssl" req -new -key "$dir/developer-id.key" -out "$dir/developer-id.csr" -subj "/emailAddress=$email/CN=Copyisto Trimmer"
  echo "Upload $dir/developer-id.csr at developer.apple.com, then run: scripts/signing.sh certificate ~/Downloads/developerID_application.cer"
  open -R "$dir/developer-id.csr"
  ;;
certificate)
  cer="${2:?usage: scripts/signing.sh certificate FILE.cer}"
  [[ -f "$dir/developer-id.key" ]] || fail "No private key in $dir; run scripts/signing.sh request first."
  "$openssl" x509 -inform DER -in "$cer" -out "$dir/developer-id.pem"
  [[ "$("$openssl" x509 -noout -modulus -in "$dir/developer-id.pem")" == "$("$openssl" rsa -noout -modulus -in "$dir/developer-id.key" 2>/dev/null)" ]] \
    || fail "$cer was not made from the request in $dir."
  subject="$("$openssl" x509 -noout -subject -in "$dir/developer-id.pem")"
  [[ "$subject" == *"Developer ID Application"* ]] || fail "$cer is not a Developer ID Application certificate: $subject"
  # Apple's intermediate goes into the .p12 too, or codesign on the runner may not find a chain to Apple's root.
  if "$openssl" x509 -noout -issuer -in "$dir/developer-id.pem" | grep -q "OU=G2"; then ca=DeveloperIDG2CA; else ca=DeveloperIDCA; fi
  curl -fsSL "https://www.apple.com/certificateauthority/$ca.cer" | "$openssl" x509 -inform DER -out "$dir/intermediate.pem"
  password="$("$openssl" rand -hex 24)"
  (umask 077 && P12_PASSWORD="$password" "$openssl" pkcs12 -export -name "Developer ID Application" \
    -inkey "$dir/developer-id.key" -in "$dir/developer-id.pem" -certfile "$dir/intermediate.pem" \
    -out "$dir/developer-id.p12" -passout env:P12_PASSWORD)
  base64 -i "$dir/developer-id.p12" | gh secret set MACOS_CERTIFICATE -R "$repo"
  printf '%s' "$password" | gh secret set MACOS_CERTIFICATE_PASSWORD -R "$repo"
  echo "Set MACOS_CERTIFICATE and MACOS_CERTIFICATE_PASSWORD for $subject"
  echo "It expires $("$openssl" x509 -noout -enddate -in "$dir/developer-id.pem" | cut -d = -f 2)."
  echo "Keep $dir/developer-id.key safe (a password manager), or make a new certificate when you need it again; then delete $dir."
  ;;
notary)
  p8="${2:?usage: scripts/signing.sh notary FILE.p8 ISSUER}"
  issuer="${3:?usage: scripts/signing.sh notary FILE.p8 ISSUER}"
  id="$(basename "$p8" .p8)"
  id="${id#AuthKey_}"
  # Asks Apple, so a wrong issuer or a key without access fails here rather than in the first release.
  xcrun notarytool history --key "$p8" --key-id "$id" --issuer "$issuer" >/dev/null \
    || fail "Apple refused the key $id with issuer $issuer."
  base64 -i "$p8" | gh secret set NOTARY_KEY -R "$repo"
  gh secret set NOTARY_KEY_ID -R "$repo" --body "$id"
  gh secret set NOTARY_ISSUER_ID -R "$repo" --body "$issuer"
  echo "Set NOTARY_KEY, NOTARY_KEY_ID ($id) and NOTARY_ISSUER_ID."
  echo "Apple lets you download $p8 once: keep it in a password manager, then delete it."
  ;;
tap)
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C "$repo releases" -f "$work/key"
  gh repo deploy-key add "$work/key.pub" -R "$tap" --allow-write --title "$repo releases"
  gh secret set HOMEBREW_TAP_KEY -R "$repo" < "$work/key"
  echo "Set HOMEBREW_TAP_KEY; its public half is a deploy key of $tap."
  ;;
*)
  sed -n '6,9p' "$0" | sed 's/^# *//'
  exit 1
  ;;
esac
