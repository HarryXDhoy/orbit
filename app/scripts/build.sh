#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p dist
# Stage outside the project: folders synced by iCloud pick up Finder and File Provider attributes,
# which codesign rejects.
stage=$(mktemp -d "${TMPDIR:-/tmp}/orbit-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Orbit.app/Contents/MacOS" "$stage/Orbit.app/Contents/Resources"
cp -X .build/release/Orbit "$stage/Orbit.app/Contents/MacOS/Orbit"
cp -X Info.plist "$stage/Orbit.app/Contents/Info.plist"
cp -X Resources/AppIcon.icns "$stage/Orbit.app/Contents/Resources/AppIcon.icns"
# Sign with a stable identity so macOS keeps Screen Recording, Microphone and Accessibility grants across
# rebuilds (an ad-hoc signature changes every build, which silently invalidates them).
identity="${ORBIT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
xattr -cr "$stage/Orbit.app"
codesign --force --sign "${identity:--}" --identifier local.orbit.companion "$stage/Orbit.app"
printf 'Signed with %s\n' "${identity:-ad-hoc (permissions reset on every build)}"
# Replace the bundle after signing; never overwrite a running executable in place.
if [ -d dist/Orbit.app ]; then
    mv dist/Orbit.app "$stage/previous-Orbit.app"
fi
mv "$stage/Orbit.app" dist/Orbit.app
printf 'Built %s/dist/Orbit.app\n' "$PWD"
