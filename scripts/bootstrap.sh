#!/usr/bin/env bash
# One-time setup on the Mac mini.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
fi

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo "Created Config/Local.xcconfig. Edit it and set DEVELOPMENT_TEAM to your Personal Team ID."
  echo "Candidates from your keychain:"
  security find-identity -v -p codesigning 2>/dev/null | grep -o 'Apple Development: .*' || true
fi

xcodegen generate
echo
echo "Next: open DisplayBrowser.xcodeproj once, sign in to Xcode with your Apple ID (Settings > Accounts),"
echo "plug in the iPhone, enable Developer Mode (Settings > Privacy & Security), then run scripts/deploy.sh."
