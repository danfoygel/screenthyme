#!/bin/sh
# Captures the screen map's screenshots into <site dir>/shots with the ScreenTour UI test, in a Simulator on iOS 26.4
# or later, from a fresh install: Welcome, single-phone test mode, a replayed synthetic day for a test kid, then every
# screen it can reach. Only test data, never a real phone's: the map is published on a public site.
#
#   Tools/ScreenMap/capture.sh <simulator name or UDID> <site dir>
set -e
usage="usage: capture.sh <simulator name or UDID> <site dir>"
DEVICE=${1:?$usage}
SITE=${2:?$usage}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RAW=$(mktemp -d)
BUNDLE=com.danfoygel.screenthyme
cd "$ROOT"

UDID=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devices = json.load(sys.stdin)["devices"].values()
print(next(d["udid"] for ds in devices for d in ds if sys.argv[1] in (d["udid"], d["name"])))' "$DEVICE")
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl uninstall "$UDID" $BUNDLE 2>/dev/null || true
xcrun simctl privacy "$UDID" reset all $BUNDLE 2>/dev/null || true

xcodegen generate >/dev/null
xcodebuild build-for-testing -project ScreenThyme.xcodeproj -scheme ScreenThyme -destination "id=$UDID" \
  -derivedDataPath build -quiet
run() {
  TEST_RUNNER_SCREEN_TOUR_OUT="$RAW" xcodebuild test-without-building -project ScreenThyme.xcodeproj -scheme ScreenThyme \
    -destination "id=$UDID" -derivedDataPath build -only-testing:"ScreenTour/ScreenTour/$1" 2>&1 \
    | grep -E '^TOUR|TEST (SUCCEEDED|FAILED)' || true
}
run test1Parent
run test2Kid
# What a block page's "Ask for more time" leaves for the app, which opens the sheet if it's under a minute old.
GROUP=$(xcrun simctl get_app_container "$UDID" $BUNDLE group.com.danfoygel.screenthyme)
printf '{"at":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$GROUP/Library/ScreenThyme/ask.json"
run test3AskSheet
xcrun simctl status_bar "$UDID" clear

# 960 px tall JPEGs; the screens both maps show get both names.
mkdir -p "$SITE/shots"
rm -f "$SITE/shots"/*.jpg
for f in "$RAW"/*.png; do
  sips -Z 960 -s format jpeg -s formatOptions 72 "$f" --out "$SITE/shots/$(basename "$f" .png).jpg" >/dev/null
done
cd "$SITE/shots"
[ -f welcome.jpg ] && cp welcome.jpg k-welcome.jpg && mv welcome.jpg p-welcome.jpg
[ -f p-replay.jpg ] && cp p-replay.jpg k-replay.jpg
rm -rf "$RAW"
echo "$(ls | wc -l | tr -d ' ') screenshots in $SITE/shots"
