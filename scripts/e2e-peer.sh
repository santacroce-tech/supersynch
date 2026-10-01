#!/usr/bin/env bash
# Starts a throwaway Syncthing ("the Mac") for the bridge's end-to-end test:
#   sync listener tcp://127.0.0.1:22001, REST API http://127.0.0.1:8386
# Usage: scripts/e2e-peer.sh [path-to-syncthing]   (default: syncthing on PATH)
# Then:  cd go && PEER_URL=http://127.0.0.1:8386 PEER_API_KEY=e2e-key go test -tags noassets ./stbridge/
set -euo pipefail
BIN="${1:-$(command -v syncthing)}"
HOME_DIR="$(mktemp -d)/peer"
KEY=e2e-key
"$BIN" generate --home="$HOME_DIR" >/dev/null
"$BIN" serve --home="$HOME_DIR" --no-browser --no-upgrade \
  --gui-address=http://127.0.0.1:8386 --gui-apikey="$KEY" >"$HOME_DIR.log" 2>&1 &
PID=$!
for _ in $(seq 1 30); do curl -sf http://127.0.0.1:8386/rest/noauth/health >/dev/null && break; sleep 1; done
curl -sf -X PATCH -H "X-API-Key: $KEY" http://127.0.0.1:8386/rest/config/options -d '{
  "listenAddresses": ["tcp://127.0.0.1:22001"], "globalAnnounceEnabled": false,
  "localAnnounceEnabled": false, "relaysEnabled": false, "natEnabled": false}'
echo "peer running: pid $PID, log $HOME_DIR.log"
