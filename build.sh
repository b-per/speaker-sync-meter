#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=13.0
app="build/Speaker Sync.app"
mkdir -p "$app/Contents/MacOS" build/tests
swiftc -O -module-cache-path build/module-cache Sources/*.swift -o "$app/Contents/MacOS/SpeakerSync"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
"$app/Contents/MacOS/SpeakerSync" --write-track "build/Speaker Sync Calibration.wav"

if [[ "${1:-}" == "--test" ]]; then
    swiftc -O -module-cache-path build/module-cache Sources/Calibration.swift Tests/CalibrationChecks.swift -o build/tests/calibration-checks
    build/tests/calibration-checks
fi
