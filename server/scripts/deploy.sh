#!/usr/bin/env bash
# Deploys binaryd to another machine over SSH and installs it as a service.
#   server/scripts/deploy.sh <ssh-host> [remote-dir]
# The remote machine needs Node.js 20+ and a logged-in Claude Code
# (`claude` login or `claude setup-token`); npm installs the Agent SDK and its
# Claude Code binary for that machine's platform.
set -euo pipefail
HOST=${1:?usage: deploy.sh <ssh-host> [remote-dir]}
DIR=${2:-binaryd}
cd "$(dirname "$0")/.."

rsync -az --delete --exclude node_modules --exclude dist --exclude bench \
  ./ "$HOST:$DIR/"
# Stop a previous install first: npm ci replaces node_modules under it.
ssh "$HOST" "cd $DIR && (./bin/binaryd service uninstall >/dev/null 2>&1 || true) && npm ci --no-audit --no-fund && npm run build && ./bin/binaryd service install && ./bin/binaryd token"
