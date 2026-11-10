#!/usr/bin/env bash
# Updates this checkout from its upstream and rebuilds what changed.
#   make update   (or scripts/update.sh)
# Pulls fast-forward only, so local commits or conflicting edits stop it
# before anything is rebuilt. Only what was built here before is rebuilt:
# - dist/Binary.app (macOS), when client/ changed; relaunched if it was
#   running from there.
# - binaryd, when server/ changed; its service is restarted once that
#   interrupts nothing, if the service runs this checkout. When dependencies
#   changed, it waits for that before `npm install`, which replaces files the
#   running server uses.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
APP="$ROOT/dist/Binary.app"
BIN="$ROOT/server/bin/binaryd"
# The path binaryd's service file runs (node resolves symlinks, as pwd -P does).
MAIN="$ROOT/server/dist/src/main.js"

OLD=$(git rev-parse HEAD)
git pull --ff-only
NEW=$(git rev-parse HEAD)
if [ "$OLD" = "$NEW" ]; then
  echo "already up to date at $(git rev-parse --short HEAD) (make all rebuilds anyway)"
  exit 0
fi
git log --oneline "$OLD..$NEW"
# A second run would find nothing to pull, so say how to finish.
trap 'echo "update stopped after pulling; fix the error above, then run make all" >&2' ERR

changed() { ! git diff --quiet "$OLD" "$NEW" -- "$@"; }

# Whether binaryd's launchd / systemd service runs this checkout's server.
service_here() {
  local f
  case "$(uname)" in
    Darwin) f="$HOME/Library/LaunchAgents/dev.binary.binaryd.plist" ;;
    Linux) f="$HOME/.config/systemd/user/binaryd.service" ;;
    *) return 1 ;;
  esac
  [ -f "$f" ] && grep -qF "$MAIN" "$f"
}

RELAUNCH=0
if [ "$(uname)" = Darwin ] && [ -d "$APP" ] && changed client; then
  # Checked before the build, which replaces the bundle.
  if pgrep -f "^$APP/Contents/MacOS/Binary" >/dev/null; then RELAUNCH=1; fi
  make app
fi

if [ -f "$MAIN" ] && changed server; then
  WHEN=--when-idle
  if changed server/package.json server/package-lock.json; then
    "$BIN" wait-idle
    (cd server && npm install --no-audit --no-fund && npm run build)
    WHEN=
  else
    (cd server && npm run build)
  fi
  if service_here; then
    "$BIN" service restart $WHEN
  else
    echo "binaryd rebuilt; restart it to run the new version (no service runs this checkout)"
  fi
fi

if [ "$RELAUNCH" = 1 ]; then
  # A normal quit, so the app saves its caches and drafts first.
  osascript -e "tell application \"$APP\" to quit"
  for _ in $(seq 60); do
    pgrep -f "^$APP/Contents/MacOS/Binary" >/dev/null || break
    sleep 0.5
  done
  open "$APP"
fi
echo "updated to $(git rev-parse --short HEAD)"
