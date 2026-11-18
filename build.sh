#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=13.0

release=false
test_build=false
for option in "$@"; do
    case "$option" in
        --release) release=true ;;
        --test) test_build=true ;;
        *) printf 'Usage: %s [--release] [--test]\n' "$0" >&2; exit 2 ;;
    esac
done

app="build/Speaker Sync.app"
executable="$app/Contents/MacOS/SpeakerSync"
track="build/Speaker Sync Calibration.wav"
mkdir -p "$app/Contents/MacOS" build/tests

if "$release"; then
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
            -module-cache-path "build/module-cache/$arch" Sources/*.swift -o "build/SpeakerSync-$arch"
    done
    lipo -create build/SpeakerSync-arm64 build/SpeakerSync-x86_64 -output "$executable"
else
    swiftc -O -module-cache-path build/module-cache Sources/*.swift -o "$executable"
fi

cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
"$executable" --write-track "$track"

if "$release"; then
    stage="$(mktemp -d "$PWD/build/package.XXXXXXXX")"
    trap 'rm -r "$stage"' EXIT
    payload="$stage/Speaker Sync Meter"
    mkdir -p "$payload" build/release
    ditto --norsrc "$app" "$payload/Speaker Sync.app"
    cp "$track" serve-track.py "$payload/"
    ditto -c -k --norsrc --keepParent "$payload" "$stage/Speaker-Sync-Meter-macOS-universal.zip"
    mv "$stage/Speaker-Sync-Meter-macOS-universal.zip" build/release/
fi

if "$test_build"; then
    swiftc -O -module-cache-path build/module-cache Sources/Calibration.swift Tests/CalibrationChecks.swift -o build/tests/calibration-checks
    build/tests/calibration-checks
fi
