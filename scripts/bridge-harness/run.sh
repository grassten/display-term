#!/usr/bin/env bash
# Exercises Sources/Resources/bridge.js in a headless macOS WKWebView: two local origins
# (so one iframe is cross-origin), shadow DOM, selection, <select>, clipboard, scrolling.
# Same WebKit engine as the phone; run it after touching bridge.js.
set -euo pipefail
cd "$(dirname "$0")"
python3 -m http.server 8801 --bind 127.0.0.1 --directory fixtures >/dev/null 2>&1 & P1=$!
python3 -m http.server 8802 --bind 127.0.0.1 --directory fixtures >/dev/null 2>&1 & P2=$!
trap 'kill $P1 $P2 2>/dev/null || true' EXIT
OUT=$(mktemp -d)
swiftc -O harness.swift -o "$OUT/harness"
sleep 0.5
"$OUT/harness" ../../Sources/Resources/bridge.js
