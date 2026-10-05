#!/bin/sh
#
# Make a release: build Nscribe, sign it, put it in a disk image, and write the
# appcast that tells installed copies about it.
#
#   Scripts/release.sh
#
# The version is MARKETING_VERSION in the project followed by the build number, which
# is the commit count: 1.0.352. Raise MARKETING_VERSION by hand for something new. The
# release notes are Docs/Releases/<MARKETING_VERSION>.md, one file for every 1.0.x.
# The tree must be clean, because the build number has to name exactly what shipped.
#
# The app is signed with the Apple Development certificate the project already uses,
# so every release keeps one identity and macOS keeps each user's permissions across
# updates. The disk image is signed for Sparkle with the EdDSA key stored under the
# account "nscribe" in the login Keychain. It was made once with
# `generate_keys --account nscribe`, and its public half is SUPublicEDKey in
# Configuration/Info.plist. Losing it means updates can no longer be signed.
#
# Nothing is uploaded. The script ends by printing the command that creates the
# GitHub release as a draft.

set -e
cd "$(dirname "$0")/.."

marketing=$(xcodebuild -project Nscribe.xcodeproj -scheme Nscribe -configuration Release \
  -showBuildSettings 2>/dev/null | sed -n 's/^ *MARKETING_VERSION = //p' | head -1)
notes="Docs/Releases/$marketing.md"
if [ ! -f "$notes" ]; then
  echo "Write the release notes for $marketing in $notes first."
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit your changes first: the build number has to match a commit."
  exit 1
fi

build="$(mktemp -d)"
out="$build/release"
mkdir -p "$out"

echo "Building Nscribe $marketing… (the full log is in $build/build.log)"
if ! xcodebuild -project Nscribe.xcodeproj -scheme Nscribe -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$build" build > "$build/build.log" 2>&1; then
  grep -E "error:" "$build/build.log" | head -20
  echo "The build failed."
  exit 1
fi
app="$build/Build/Products/Release/Nscribe.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

identity=$(codesign -dv --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)

# Sparkle's helpers arrive signed without a certificate. Signed with the app's
# identity, as Sparkle's documentation asks, its installer can trust the update it
# installs and swap the app in one step; otherwise it moves the old app out and the
# new one in, with a moment where neither is there.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for helper in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
    --sign "$identity" "$sparkle/Versions/B/$helper"
done
codesign --force --options runtime --timestamp --sign "$identity" "$sparkle"

# Xcode signs every build as debuggable. That lets any process the user runs attach
# to Nscribe and act with its microphone and Accessibility permissions, so the
# released app is signed again without that one entitlement.
entitlements="$build/entitlements.plist"
codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$entitlements"
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

# The disk image: the app beside a shortcut to Applications.
staging="$build/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Nscribe.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Nscribe -srcfolder "$staging" -format UDZO -quiet "$out/Nscribe-$version.dmg"

# The appcast names this release alone, which is all Sparkle needs. The notes beside
# the image become the text of Sparkle's update window.
cp "$notes" "$out/Nscribe-$version.md"
"$build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" --account nscribe \
  --download-url-prefix "https://github.com/frozenemitt/nscribe/releases/download/v$version/" \
  --embed-release-notes -o "$out/appcast.xml" "$out"

echo
echo "Nscribe $version is ready in $out"
echo "Create the GitHub release as a draft with:"
echo
echo "  gh release create v$version --draft --title 'Nscribe $version' --notes-file $notes $out/Nscribe-$version.dmg $out/appcast.xml"
