#!/usr/bin/env bash
# Simulator helpers for .github/workflows/simulator-screens.yml.
#
#   sim.sh boot "<device type name>"       create and boot that device on the newest iOS runtime
#   sim.sh walk <slug> <ipad true|false>   run the flows at the default and largest text size
#
# Only the screenshots the flows take on purpose (and Maestro's failure
# screenshots) are kept, in screens/. Maestro's own debug output stays in
# maestro-debug/, which is never uploaded: it can contain the text a flow typed.
set -euo pipefail

cmd="$1"; shift

if [ "$cmd" = boot ]; then
  name="$1"
  type_id=$(xcrun simctl list devicetypes -j | python3 -c "
import json, sys
name = sys.argv[1]
for t in json.load(sys.stdin)['devicetypes']:
    if t['name'] == name:
        print(t['identifier']); break
" "$name")
  runtime_id=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
rs = [r for r in json.load(sys.stdin)['runtimes'] if r['platform'] == 'iOS' and r['isAvailable']]
rs.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
print(rs[-1]['identifier'])
")
  if [ -z "$type_id" ]; then echo "No device type named '$name' on this runner" >&2; exit 1; fi
  echo "Device type $type_id, runtime $runtime_id"
  udid=$(xcrun simctl create "Test $name" "$type_id" "$runtime_id")
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  # The status bar Apple uses in its own screenshots.
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
  xcrun simctl ui "$udid" appearance light || true
  exit 0
fi

# Copies the deliberate and failure screenshots out of a Maestro output folder.
collect() {
  local debug="$1" out="$2"
  mkdir -p "$out"
  find "$debug" -path '*/takeScreenshot/*.png' -exec cp {} "$out/" \; 2>/dev/null || true
  mkdir -p "$out/failures"
  find "$debug" -path '*/screenshots/*.png' -exec cp {} "$out/failures/" \; 2>/dev/null || true
  rmdir "$out/failures" 2>/dev/null || true
}

run_flow() {
  local flow="$1" out="$2" debug="$3"
  maestro test "$flows/$flow" \
    -e APP_ID="$APP_ID" -e REVIEW_EMAIL="$REVIEW_EMAIL" -e REVIEW_PASSWORD="$REVIEW_PASSWORD" \
    --test-output-dir "$debug" || status=1
  collect "$debug" "$out"
}

if [ "$cmd" = walk ]; then
  slug="$1"; ipad="$2"
  root="$PWD"
  flows="$root/maestro"
  status=0
  for size in large accessibility-extra-extra-extra-large; do
    label=$([ "$size" = large ] && echo default || echo ax5)
    xcrun simctl ui booted content_size "$size" || echo "content_size $size not supported here"
    run_flow main.yaml "$root/screens/$slug/$label" "$root/maestro-debug/$slug/$label"
    if [ "$ipad" = true ]; then
      out="$root/screens/$slug/$label-landscape"
      run_flow landscape.yaml "$out" "$root/maestro-debug/$slug/$label-landscape"
      # The simulator saves landscape screenshots sideways: turn them upright.
      for f in "$out"/*.png; do [ -e "$f" ] && sips -r 90 "$f" >/dev/null; done
    fi
  done
  exit $status
fi

echo "Unknown command $cmd" >&2
exit 2
