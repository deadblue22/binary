#!/usr/bin/env bash
# Builds the iOS app (client/iOS) with XcodeGen + xcodebuild.
#   scripts/build-ios.sh                    # simulator build, no signing
#   scripts/build-ios.sh --device [udid]    # build for a connected iPhone, install and launch it
#
# Device builds sign with a team Xcode knows: sign in under Xcode → Settings →
# Accounts first (a free Personal Team works; its builds run for 7 days, then
# install again). On the iPhone, turn on Developer Mode, and the first time,
# trust the developer under Settings → General → VPN & Device Management.
#   BINARY_TEAM=<team id>        signing team (default: the first team Xcode has)
#   BINARY_IOS_BUNDLE_ID=<id>    bundle ID (default: dev.binary.ios.<team id>;
#                                a bundle ID can belong to only one team)
set -euo pipefail
cd "$(dirname "$0")/../iOS"
command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }
xcodegen generate --quiet
BUILD=${BUILD_DIR:-$PWD/build}

if [[ "${1:-}" != "--device" ]]; then
  xcodebuild -quiet -project Binary.xcodeproj -scheme Binary -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$BUILD" build
  echo "built $BUILD/Build/Products/Debug-iphonesimulator/Binary.app"
  exit 0
fi

# The phone: given, or the first paired iPhone / iPad.
UDID=${2:-}
if [[ -z "$UDID" ]]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  UDID=$(/usr/bin/python3 - "$JSON" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "iOS" and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(hw.get("udid", ""))
        break
EOF
)
  rm -f "$JSON"
fi
[[ -n "$UDID" ]] || { echo "no paired iPhone found (connect it, or pass its UDID)" >&2; exit 1; }

TEAM=${BINARY_TEAM:-$(defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
p = plistlib.loads(sys.stdin.buffer.read())
for teams in p.get("IDEProvisioningTeamByIdentifier", {}).values():
    for t in teams:
        print(t["teamID"]); sys.exit()
for t in p.get("IDEProvisioningTeams", {}).values():
    for x in t:
        print(x["teamID"]); sys.exit()
' || true)}
[[ -n "$TEAM" ]] || { echo "no signing team: sign in to Xcode (Settings → Accounts) or set BINARY_TEAM" >&2; exit 1; }
LOWER_TEAM=$(echo "$TEAM" | tr '[:upper:]' '[:lower:]')
BUNDLE_ID=${BINARY_IOS_BUNDLE_ID:-dev.binary.ios.$LOWER_TEAM}

xcodebuild -quiet -project Binary.xcodeproj -scheme Binary -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$BUILD" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build
APP="$BUILD/Build/Products/Debug-iphoneos/Binary.app"
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" \
  || echo "installed; if it didn't open, trust the developer on the phone: Settings → General → VPN & Device Management"
