#!/bin/sh
#
# Build Inscribe from source and put it in /Applications.
#
#   Scripts/install.sh
#
# No Apple Developer Program membership is needed. The app is signed ad hoc, which
# macOS accepts for an app built on the Mac it runs on. To sign with your own Apple
# Development certificate instead, pass your team ID:
#
#   TEAM=ABCDE12345 Scripts/install.sh
#
# The first build downloads the FluidAudio package and takes a few minutes.

set -e
cd "$(dirname "$0")/.."

if [ -n "$TEAM" ]; then
  set -- DEVELOPMENT_TEAM="$TEAM" "DEVELOPMENT_TEAM[sdk=macosx*]=$TEAM" CODE_SIGN_STYLE=Automatic "CODE_SIGN_IDENTITY=Apple Development"
else
  set -- CODE_SIGN_IDENTITY=- "CODE_SIGN_IDENTITY[sdk=macosx*]=-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= "DEVELOPMENT_TEAM[sdk=macosx*]="
fi

build="$(mktemp -d)"
log="$build/build.log"
echo "Building Inscribe… (the full log is in $log)"
if ! xcodebuild -project Inscribe.xcodeproj -scheme Inscribe -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$build" "$@" build > "$log" 2>&1; then
  grep -E "error:" "$log" | head -20
  echo "The build failed. The full log is in $log"
  exit 1
fi

app="$build/Build/Products/Release/Inscribe.app"
osascript -e 'tell application "Inscribe" to quit' > /dev/null 2>&1 || true
rm -rf /Applications/Inscribe.app
ditto "$app" /Applications/Inscribe.app
touch /Applications/Inscribe.app
open -a /Applications/Inscribe.app

echo "Inscribe is in /Applications and running. Look for the ribbon in the menu bar."
