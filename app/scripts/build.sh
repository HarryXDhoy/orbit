#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.orbit-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Orbit.app/Contents/MacOS" "$stage/Orbit.app/Contents/Resources"
cp -X .build/release/Orbit "$stage/Orbit.app/Contents/MacOS/Orbit"
cp -X Info.plist "$stage/Orbit.app/Contents/Info.plist"
cp -X Resources/AppIcon.icns "$stage/Orbit.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.orbit.companion "$stage/Orbit.app"
# Replace the bundle after signing; never overwrite a running executable in place.
if [ -d dist/Orbit.app ]; then
    mv dist/Orbit.app "$stage/previous-Orbit.app"
fi
mv "$stage/Orbit.app" dist/Orbit.app
printf 'Built %s/dist/Orbit.app\n' "$PWD"
