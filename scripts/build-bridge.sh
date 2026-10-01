#!/usr/bin/env bash
# Builds the embedded Syncthing bridge (go/stbridge) into
# Frameworks/Stbridge.xcframework with gomobile. Skips the build when the
# framework is newer than every Go source unless --force is given.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Frameworks/Stbridge.xcframework
export PATH="$PATH:$(go env GOPATH)/bin"

if [[ "${1:-}" != "--force" && -d "$OUT" ]] && [[ -z "$(find go -newer "$OUT/Info.plist" \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) | head -1)" ]]; then
  echo "Stbridge.xcframework is up to date"
  exit 0
fi

command -v gomobile >/dev/null || go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init
ST_VERSION=$(cd go && go list -m -f '{{.Version}}' github.com/syncthing/syncthing)
rm -rf "$OUT"
(cd go && gomobile bind -target ios,iossimulator -iosversion 17.0 -tags noassets \
  -ldflags "-s -w -X supersynch/bridge/stbridge.Version=v2.1.5 -X github.com/syncthing/syncthing/lib/build.Version=v2.1.5" \
  -o "../$OUT" ./stbridge)
echo "Built $OUT (syncthing v2.1.5, module $ST_VERSION)"
