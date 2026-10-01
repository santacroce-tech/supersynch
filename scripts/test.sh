#!/usr/bin/env bash
# Regenerate the Xcode project and run the test suite headlessly.
# Usage: scripts/test.sh [simulator name]   (default: "iPhone 15")
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-bridge.sh
DEVICE="${1:-iPhone 15}"
xcodegen generate --quiet
set -o pipefail
xcodebuild -scheme SuperSynch \
  -destination "platform=iOS Simulator,name=${DEVICE}" \
  -derivedDataPath build/DerivedData \
  test 2>&1 | grep -E "error:|warning: .*\.swift|Test Case .* failed|Executed [0-9]+ test|\*\* (BUILD|TEST)" || true
exit "${PIPESTATUS[0]}"
