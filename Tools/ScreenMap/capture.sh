#!/bin/sh
# Captures the screen map's screenshots into <site dir>/shots with the ScreenTour UI test, in a Simulator on iOS 26.4
# or later, from a fresh install: Welcome, single-phone test mode, a replayed synthetic day for a test kid, then every
# screen it can reach. Only test data, never a real phone's: the map is published on a public site.
#
#   Tools/ScreenMap/capture.sh <simulator name or UDID> <site dir> [test ...]
#
# Tests (ScreenTour.swift) name a part of the tour, such as test3ScreenTime: only those are captured, after test1Setup,
# and the other screenshots in <site dir>/shots stay.
set -e
usage="usage: capture.sh <simulator name or UDID> <site dir> [test ...]"
DEVICE=${1:?$usage}
SITE=${2:?$usage}
shift 2
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
# Installed first, for the App Group's path: the last test leaves a block page's request there.
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/ScreenThyme.app
GROUP=$(xcrun simctl get_app_container "$UDID" $BUNDLE group.com.danfoygel.screenthyme)
ONLY=""
for t in "$@"; do ONLY="$ONLY -only-testing:ScreenTour/ScreenTour/$t"; done
[ -n "$ONLY" ] && ONLY="-only-testing:ScreenTour/ScreenTour/test1Setup $ONLY"
# shellcheck disable=SC2086
TEST_RUNNER_SCREEN_TOUR_OUT="$RAW" TEST_RUNNER_SCREEN_TOUR_GROUP="$GROUP" xcodebuild test-without-building \
  -project ScreenThyme.xcodeproj -scheme ScreenThyme -destination "id=$UDID" -derivedDataPath build \
  ${ONLY:--only-testing:ScreenTour} 2>&1 | grep -E '^TOUR|^Test Case .*(passed|failed)|TEST (SUCCEEDED|FAILED)' || true
xcrun simctl status_bar "$UDID" clear

# 960 px tall JPEGs; the screens both maps show get both names.
mkdir -p "$SITE/shots"
[ $# -eq 0 ] && rm -f "$SITE/shots"/*.jpg
for f in "$RAW"/*.png; do
  sips -Z 960 -s format jpeg -s formatOptions 72 "$f" --out "$SITE/shots/$(basename "$f" .png).jpg" >/dev/null
done
cd "$SITE/shots"
[ -f welcome.jpg ] && cp welcome.jpg k-welcome.jpg && mv welcome.jpg p-welcome.jpg
[ -f p-replay.jpg ] && cp p-replay.jpg k-replay.jpg
rm -rf "$RAW"
echo "$(ls | wc -l | tr -d ' ') screenshots in $SITE/shots"
