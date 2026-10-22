#!/usr/bin/env bash
# Simulator helpers for .github/workflows/simulator-screens.yml.
#
#   sim.sh boot "<device type name>"       create and boot that device on the newest iOS runtime
#   sim.sh walk <slug> <ipad true|false>   run the flows (onboarding, main, iPad landscape)
#                                          at the default and largest text size
#
# Only the screenshots the flows take on purpose (and Maestro's failure
# screenshots) are kept, in screens/. Maestro's own debug output stays in
# maestro-debug/, which is never uploaded: it can contain the text a flow typed.
set -euo pipefail

# The Intel runners start the XCTest driver slowly.
export MAESTRO_DRIVER_STARTUP_TIMEOUT=180000

cmd="$1"; shift

# Boots the simulator and sets the status bar Apple uses in its own screenshots.
start_sim() {
  local udid="$1"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
  xcrun simctl ui "$udid" appearance light || true
}

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
  echo "$udid" > .sim-udid
  start_sim "$udid"
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
  # A flow that wedges is stopped after 15 minutes, so the other flows and
  # the encrypted upload still happen (run 2: the XCTest driver timed out on
  # the iPad Pro 13 and Maestro hung until the job was cancelled).
  # A submission run (RETRY=1) tries a failed flow once more on a restarted
  # simulator: run 8 lost every iPad onboarding screen to one driver start.
  local tries=1 attempt code
  [ "${RETRY:-0}" = 1 ] && tries=2
  for attempt in $(seq 1 "$tries"); do
    code=0
    perl -e 'alarm shift; exec @ARGV' 900 maestro test "$flows/$flow" \
      -e APP_ID="$APP_ID" -e REVIEW_EMAIL="$REVIEW_EMAIL" -e REVIEW_PASSWORD="$REVIEW_PASSWORD" \
      -e DEVICE="$slug" --test-output-dir "$debug" || code=$?
    collect "$debug" "$out"
    [ "$code" -eq 0 ] && break
    # 142 is the alarm. Once the XCTest driver wedges it never starts again on
    # that simulator (run 5: every later flow on macos-26 failed with "iOS
    # driver not ready"), so the simulator is restarted before going on.
    if [ "$code" -eq 142 ] || [ "$attempt" -lt "$tries" ]; then
      echo "Flow $flow failed (exit $code, attempt $attempt): restarting the simulator"
      pkill -f maestro-driver || true
      pkill -f xcodebuild || true
      local udid; udid=$(cat "$root/.sim-udid")
      xcrun simctl shutdown "$udid" || true
      start_sim "$udid"
      xcrun simctl ui booted content_size "$size" || true
    fi
  done
  [ "$code" -eq 0 ] || status=1
}

if [ "$cmd" = walk ]; then
  slug="$1"; ipad="$2"
  root="$PWD"
  flows="$root/maestro"
  status=0
  # SIZES and LANDSCAPE narrow a run to the App Store screenshots.
  for size in ${SIZES:-large accessibility-extra-extra-extra-large}; do
    label=$([ "$size" = large ] && echo default || echo ax5)
    xcrun simctl ui booted content_size "$size" || echo "content_size $size not supported here"
    run_flow onboarding.yaml "$root/screens/$slug/$label-onboarding" "$root/maestro-debug/$slug/$label-onboarding"
    run_flow main.yaml "$root/screens/$slug/$label" "$root/maestro-debug/$slug/$label"
    if [ "$ipad" = true ] && [ "${LANDSCAPE:-true}" = true ]; then
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
