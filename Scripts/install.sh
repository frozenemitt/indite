#!/bin/sh
#
# Build Indite from source and put it in /Applications.
#
#   Scripts/install.sh
#
# No Apple Developer Program membership is needed. The app is signed ad hoc, which
# macOS accepts for an app built on the Mac it runs on. To sign with your own Apple
# Development certificate instead, pass your team ID:
#
#   TEAM=ABCDE12345 Scripts/install.sh
#
# The first build downloads the FluidAudio and Sparkle packages and takes a few minutes.

set -e
cd "$(dirname "$0")/.."

build="$(mktemp -d)"
log="$build/build.log"
signing="$build/Signing.xcconfig"

# The project signs with its author's team. These settings replace that for this
# build only, through an xcconfig: a setting with an SDK condition cannot be given on
# the command line.
if [ -n "$TEAM" ]; then
  cat > "$signing" <<SETTINGS
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development
DEVELOPMENT_TEAM = $TEAM
DEVELOPMENT_TEAM[sdk=macosx*] = $TEAM
SETTINGS
else
  # Without a certificate the app has no team, and the hardened runtime then refuses
  # to load the Sparkle framework inside it: dyld stops the app at launch with
  # "different Team IDs". The hardened runtime only matters for Apple's notarization,
  # which an app built here never goes through.
  cat > "$signing" <<SETTINGS
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
CODE_SIGN_IDENTITY[sdk=macosx*] = -
DEVELOPMENT_TEAM =
DEVELOPMENT_TEAM[sdk=macosx*] =
ENABLE_HARDENED_RUNTIME = NO
SETTINGS
fi

echo "Building Indite… (the full log is in $log)"
if ! xcodebuild -project Indite.xcodeproj -scheme Indite -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$build" -xcconfig "$signing" build > "$log" 2>&1; then
  grep -E "error:" "$log" | head -20
  echo "The build failed. The full log is in $log"
  exit 1
fi

app="$build/Build/Products/Release/Indite.app"
# Quit by identity rather than by name, so a copy still called Nscribe quits too.
osascript -e 'tell application id "com.nscribe.app.macos" to quit' > /dev/null 2>&1 || true
# A copy under the app's first name would be a second Indite with the same identity.
rm -rf /Applications/Nscribe.app /Applications/Indite.app
ditto "$app" /Applications/Indite.app
touch /Applications/Indite.app
open -a /Applications/Indite.app

echo "Indite is in /Applications and running. Look for its N in the menu bar."
