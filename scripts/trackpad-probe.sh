#!/usr/bin/env bash
# Answers one question: does a pointing device reach this app when AssistiveTouch is OFF?
#
# Plug the trackpad into the Studio Display's USB-C port with the display connected to the
# phone, leave AssistiveTouch off, run this, and move the trackpad for a few seconds.
#
#   [Mouse] attached: ...      the device enumerated through GameController
#   [Mouse] delta #n ...       it is feeding us movement; this is the answer we want
#   [Probe] HOVER / INDIRECT   iOS is routing it as an iPad-style indirect pointer instead
#   (nothing at all)           iOS is not giving the device to the app without AssistiveTouch
#
# Ctrl-C to stop. DEVICE=<udid> to pick a phone.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=com.grassten.displaybrowser
DEVICE=${DEVICE:-$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["hardwareProperties"]["udid"] for x in d["result"]["devices"] if x["hardwareProperties"].get("platform")=="iOS" and x.get("connectionProperties",{}).get("tunnelState")!="unavailable"))')}

LOG=${LOG:-build/trackpad-probe.log}
mkdir -p "$(dirname "$LOG")"

echo "Watching $BUNDLE_ID on $DEVICE. Move the trackpad. Log: $LOG"
xcrun devicectl device process launch --console --terminate-existing --device "$DEVICE" "$BUNDLE_ID" 2>&1 |
  tee "$LOG" |
  grep --line-buffered -E "\[Mouse\]|\[Pointer\]|\[Probe\]|\[Display\]|\[Scene\]"
