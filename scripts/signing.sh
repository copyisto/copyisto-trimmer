#!/bin/bash
# Makes the repository secrets that sign, notarise and publish releases, with Apple's web pages only:
# no Xcode, no Apple account on this Mac. Keys are made here, signed by Apple,
# and go straight to GitHub without being printed. RELEASING.md walks through it.
#
#   scripts/signing.sh p12 FILE.p12            MACOS_CERTIFICATE and MACOS_CERTIFICATE_PASSWORD from a Developer ID exported from Keychain Access
#   scripts/signing.sh request EMAIL           or, with no Developer ID in the keychain, a private key and a signing request for developer.apple.com
#   scripts/signing.sh certificate FILE.cer    and then the same two secrets from Apple's certificate
#   scripts/signing.sh notary FILE.p8 ISSUER   NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER_ID from an App Store Connect API key
#   scripts/signing.sh apple-id EMAIL TEAM     or NOTARY_APPLE_ID, NOTARY_PASSWORD and NOTARY_TEAM_ID from an app-specific password
#   scripts/signing.sh tap                     HOMEBREW_TAP_KEY, a deploy key that lets a release update copyisto/homebrew-tap
#
# SIGNING_DIR  where the private key waits between request and certificate (default ~/copyisto-signing)
# REPO, TAP    the app's and the tap's repositories (default copyisto/copyisto-trimmer, copyisto/homebrew-tap)
set -euo pipefail
repo="${REPO:-copyisto/copyisto-trimmer}"
tap="${TAP:-copyisto/homebrew-tap}"
dir="${SIGNING_DIR:-$HOME/copyisto-signing}"
# LibreSSL, which writes a .p12 that the keychain on the CI runner can import; Homebrew's OpenSSL 3 needs -legacy for that.
openssl=/usr/bin/openssl

fail() { echo "$*" >&2; exit 1; }

case "${1:-}" in
p12)
  p12="${2:?usage: scripts/signing.sh p12 FILE.p12}"
  read -rsp "Password of $p12: " password
  echo
  # Checked here, so a wrong password fails now rather than in the first release.
  subject="$(P12_PASSWORD="$password" "$openssl" pkcs12 -in "$p12" -passin env:P12_PASSWORD -nokeys 2>/dev/null \
    | "$openssl" x509 -noout -subject -enddate 2>/dev/null)" || fail "Cannot read $p12 with that password."
  [[ "$subject" == *"Developer ID Application"* ]] || fail "$p12 holds no Developer ID Application certificate: $subject"
  P12_PASSWORD="$password" "$openssl" pkcs12 -in "$p12" -passin env:P12_PASSWORD -nocerts -nodes 2>/dev/null | grep -q "PRIVATE KEY" \
    || fail "$p12 has no private key: export it from My Certificates, not Certificates."
  base64 -i "$p12" | gh secret set MACOS_CERTIFICATE -R "$repo"
  printf '%s' "$password" | gh secret set MACOS_CERTIFICATE_PASSWORD -R "$repo"
  echo "Set MACOS_CERTIFICATE and MACOS_CERTIFICATE_PASSWORD for"
  echo "$subject"
  echo "Keep $p12 in a password manager, then delete it."
  ;;
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
  password="$("$openssl" rand -hex 24)"
  (umask 077 && P12_PASSWORD="$password" "$openssl" pkcs12 -export -name "Developer ID Application" \
    -inkey "$dir/developer-id.key" -in "$dir/developer-id.pem" \
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
apple-id)
  apple_id="${2:?usage: scripts/signing.sh apple-id EMAIL TEAM}"
  team="${3:?usage: scripts/signing.sh apple-id EMAIL TEAM}"
  read -rsp "App-specific password of $apple_id: " password
  echo
  # Asks Apple, so a wrong password or team fails here rather than in the first release.
  xcrun notarytool history --apple-id "$apple_id" --password "$password" --team-id "$team" >/dev/null \
    || fail "Apple refused $apple_id for team $team."
  gh secret set NOTARY_APPLE_ID -R "$repo" --body "$apple_id"
  printf '%s' "$password" | gh secret set NOTARY_PASSWORD -R "$repo"
  gh secret set NOTARY_TEAM_ID -R "$repo" --body "$team"
  echo "Set NOTARY_APPLE_ID, NOTARY_PASSWORD and NOTARY_TEAM_ID ($team)."
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
  sed -n '6,11p' "$0" | sed 's/^# *//'
  exit 1
  ;;
esac
