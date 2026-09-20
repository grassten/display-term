#!/usr/bin/env bash
# Build, sign with the free Personal Team, and install to the connected (or same-Wi-Fi) iPhone.
# Run this at least every 7 days; the free provisioning profile expires after a week.
#   DEVICE=<udid> scripts/deploy.sh   # pick a specific device
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME=DisplayBrowser
BUNDLE_ID=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *//p' project.yml | head -1)
# Build outside the repo: this checkout may live under an iCloud-synced folder
# (Desktop & Documents), and the file provider stamps com.apple.FinderInfo on the
# .app, which makes codesign fail with "resource fork ... not allowed".
DERIVED="${DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/DisplayBrowser-deploy}"

[ -f Config/Local.xcconfig ] || { echo "Run scripts/bootstrap.sh first." >&2; exit 1; }
command -v xcodegen >/dev/null 2>&1 || { echo "brew install xcodegen" >&2; exit 1; }

xcodegen generate --quiet

if [ -z "${DEVICE:-}" ]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for dev in data.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    if hw.get("platform") == "iOS" and hw.get("udid"):
        print(hw["udid"]); break
PY
)
  rm -f "$JSON"
fi
[ -n "$DEVICE" ] || { echo "No paired iPhone found. Plug it in, trust this Mac, or set DEVICE=<udid>." >&2; exit 1; }
echo "Deploying $BUNDLE_ID to device $DEVICE"

mkdir -p build
LOG=build/xcodebuild.log
if ! xcodebuild \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" || true
  echo "Build failed. Full log: $LOG" >&2
  exit 1
fi

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "$SCHEME.app" | head -1)
[ -n "$APP" ] || { echo "Build produced no .app; see $LOG" >&2; exit 1; }

xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" || true
echo "Installed $(date). Profile expires in 7 days; re-run before $(date -v+7d '+%Y-%m-%d' 2>/dev/null || echo 'then')."
