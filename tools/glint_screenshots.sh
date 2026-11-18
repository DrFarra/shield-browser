#!/usr/bin/env bash
# Capturas de Glint en el simulador. La app se prepara sola con -glintDemo <pantalla>.
set -euo pipefail

APP="simbuild/Debug-iphonesimulator/Glint.app"
BUNDLE="com.emilio.glint"
OUT="screenshots"
mkdir -p "$OUT"

DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
phones = [d for runtime, ds in devices.items() if "iOS" in runtime for d in ds if d["name"].startswith("iPhone")]
pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]]
print((pro or phones)[-1]["udid"])
')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$DEVICE" "$APP"

shot() {
  local screen=$1 wait=$2
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$DEVICE" "$BUNDLE" -glintDemo "$screen"
  sleep "$wait"
  xcrun simctl io "$DEVICE" screenshot "$OUT/$screen.png"
  echo "  $screen"
}

shot home 12
shot browse 8
shot search 8
shot history 8
shot channel 10
shot player 18
shot chatstyles 16
shot paused 16
shot mini 20
shot vod 24
shot clip 14
shot resume 22
shot quality 32
shot scrub 24
shot muted 24
shot mutedbar 24
