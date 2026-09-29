#!/bin/zsh
# Signs local builds with your Apple Development certificate, so the Keychain
# keeps "Always Allow" for Spotline's API keys across rebuilds.
# Writes Config/Local.xcconfig (not committed); run `xcodegen generate` afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

identity=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
if [[ -z "$identity" ]]; then
  echo "No Apple Development certificate found. In Xcode, open Settings > Accounts, add your Apple ID," >&2
  echo "select your team, click Manage Certificates, and add an Apple Development certificate." >&2
  exit 1
fi
team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')

cat > Config/Local.xcconfig <<CONFIG
// Written by scripts/setup-local-signing.sh. Not committed.
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = $team
CONFIG
echo "Local builds will be signed by \"$identity\" (team $team). Run \`xcodegen generate\` now."
