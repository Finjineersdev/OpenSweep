#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# README media: plays the Debug app's demo against the made-up 2 TB Mac in
# scripts/demo/engine.py, snapshots every screen and records the window.
# Usage: scripts/demo/record.sh <out-folder> [dark|light] [--no-video]
# Needs a Debug build (build/dd) and, for the video, Screen Recording
# permission for your terminal. Nothing outside a temp HOME is touched.
set -eu
OUT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); LOOK=${2:-dark}; VIDEO=${3:-}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEMO_HOME=$(mktemp -d)
rm -rf "$OUT"; mkdir -p "$OUT"

# Started through open: launched straight from a shell, the app gets no window.
open -n -F "$ROOT/build/dd/Build/Products/Debug/OpenSweep.app" --env HOME="$DEMO_HOME" \
  --env OPENSWEEP_BIN="$ROOT/scripts/demo/engine.py" --env OPENSWEEP_DEMO="$OUT" \
  --env OPENSWEEP_QA_APPEARANCE="$LOOK" \
  --args -otherDrives NO -onboarded YES -accessBannerDismissed YES -scanOnOpen NO -autoClean off

while [ ! -f "$OUT/window.json" ]; do sleep 0.2; done
if [ "$VIDEO" != "--no-video" ]; then
  # ffmpeg rather than screencapture -v: it can leave the pointer out.
  CROP=$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1])); s=w["scale"]; print("%d:%d:%d:%d" % (w["w"]*s, w["h"]*s, w["x"]*s, w["y"]*s))' "$OUT/window.json")
  SCREEN=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p')
  ffmpeg -v error -y -f avfoundation -capture_cursor 0 -framerate 60 -i "$SCREEN:none" \
    -vf "crop=$CROP" -c:v libx264 -preset ultrafast -crf 12 -pix_fmt yuv420p "$OUT/demo.mp4" </dev/null & REC=$!
  sleep 1.5
fi
touch "$OUT/go"
while [ ! -f "$OUT/timeline.json" ]; do sleep 0.5; done; sleep 1
if [ "$VIDEO" != "--no-video" ]; then kill -INT $REC; wait $REC || true; fi
rm -rf "$DEMO_HOME"
ls "$OUT"
