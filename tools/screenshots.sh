#!/usr/bin/env bash
# Capturas de la app en el simulador de iPhone (modo claro y oscuro).
# Lo ejecuta .github/workflows/screenshots.yml; la app se prepara sola con -shieldDemo.
set -euo pipefail

APP="build/Debug-iphonesimulator/Shield.app"
BUNDLE="com.emilio.shield"
OUT="screenshots"
mkdir -p "$OUT"

DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
phones = [d for runtime, ds in devices.items() if "iOS" in runtime for d in ds if d["name"].startswith("iPhone")]
pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]]
print((pro or phones)[-1]["udid"])
')
echo "Simulador: $DEVICE"
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$DEVICE" "$APP"

# Primer arranque: WebKit compila las listas de filtros (tarda).
xcrun simctl launch "$DEVICE" "$BUNDLE" -shieldDemo start
sleep 120

shot() {
  local mode=$1 screen=$2 wait=$3
  xcrun simctl ui "$DEVICE" appearance "$mode"
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$DEVICE" "$BUNDLE" -shieldDemo "$screen"
  sleep "$wait"
  xcrun simctl io "$DEVICE" screenshot "$OUT/$mode-$screen.png"
  echo "  $mode-$screen"
}

for mode in light dark; do
  shot "$mode" start 5
  shot "$mode" page 14
  shot "$mode" suggest 12
  shot "$mode" shield 12
  shot "$mode" history 5
  shot "$mode" bookmarks 5
  shot "$mode" settings 5
  shot "$mode" tabs 40
done
