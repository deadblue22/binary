#!/usr/bin/env bash
# Deploys binaryd to another machine over SSH and installs it as a service.
#   server/scripts/deploy.sh [--now] <ssh-host> [remote-dir]
# The remote machine needs Node.js 20+ and a logged-in Claude Code
# (`claude` login or `claude setup-token`); npm installs the Agent SDK and its
# Claude Code binary for that machine's platform.
#
# The new version is built next to the running one (<dir>.next), so the
# server keeps working meanwhile. Then the deploy waits until no session there
# has a turn running, background tasks or queued messages (--now: don't wait),
# swaps the directories (the old one stays as <dir>.prev) and restarts.
set -euo pipefail
WHEN=--when-idle
if [ "${1:-}" = "--now" ]; then WHEN=; shift; fi
HOST=${1:?usage: deploy.sh [--now] <ssh-host> [remote-dir]}
DIR=${2:-binaryd}
cd "$(dirname "$0")/.."

rsync -az --delete --exclude node_modules --exclude dist --exclude bench \
  ./ "$HOST:$DIR.next/"
ssh "$HOST" "cd $DIR.next && npm ci --no-audit --no-fund && npm run build"
if [ -n "$WHEN" ]; then
  # The new CLI asks the running (old) server; it prints what it waits for.
  ssh "$HOST" "$DIR.next/bin/binaryd wait-idle"
fi
ssh "$HOST" "if [ -d $DIR ]; then rm -rf $DIR.prev && mv $DIR $DIR.prev; fi && mv $DIR.next $DIR && cd $DIR && ./bin/binaryd service restart && ./bin/binaryd token"
