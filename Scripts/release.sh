#!/bin/sh
#
# Make a release: build Indite, sign it, put it in a disk image, and write the
# appcast that tells installed copies about it.
#
#   Scripts/release.sh
#
# The version is MARKETING_VERSION in the project followed by the build number, which
# is the commit count: 1.0.352. Raise MARKETING_VERSION by hand for something new.
# The tree must be clean, because the build number has to name exactly what shipped.
#
# Two sets of notes. Docs/Releases/whats-new.md is what changed in this release: it
# goes into the appcast, where Software Update and What's New show it to people
# updating. Rewrite it for every release. Docs/Releases/<MARKETING_VERSION>.md says
# what Indite is and how to install it, for someone arriving at the GitHub release;
# the release page shows it after what's new.
#
# The app is signed with the Apple Development certificate the project already uses,
# so every release keeps one identity and macOS keeps each user's permissions across
# updates. The disk image is signed for Sparkle with the EdDSA key stored under the
# account "indite" in the login Keychain, and its public half is SUPublicEDKey in
# Configuration/Info.plist. Losing it means updates can no longer be signed. The key
# was made under the account "nscribe", the app's first name; the first release after
# the rename files a copy under "indite" and leaves the original where it is.
#
# Nothing is uploaded. The script ends by printing the command that creates the
# GitHub release as a draft.

set -e
cd "$(dirname "$0")/.."

marketing=$(xcodebuild -project Indite.xcodeproj -scheme Indite -configuration Release \
  -showBuildSettings 2>/dev/null | sed -n 's/^ *MARKETING_VERSION = //p' | head -1)
whats_new="Docs/Releases/whats-new.md"
about="Docs/Releases/$marketing.md"
for file in "$whats_new" "$about"; do
  if [ ! -f "$file" ]; then
    echo "Write $file first."
    exit 1
  fi
done
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit your changes first: the build number has to match a commit."
  exit 1
fi

build="$(mktemp -d)"
out="$build/release"
mkdir -p "$out"

echo "Building Indite $marketing… (the full log is in $build/build.log)"
if ! xcodebuild -project Indite.xcodeproj -scheme Indite -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$build" build > "$build/build.log" 2>&1; then
  grep -E "error:" "$build/build.log" | head -20
  echo "The build failed."
  exit 1
fi
app="$build/Build/Products/Release/Indite.app"
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
# to Indite and act with its microphone and Accessibility permissions, so the
# released app is signed again without that one entitlement.
entitlements="$build/entitlements.plist"
codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$entitlements"
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

# The disk image: the app beside a shortcut to Applications. Its name carries no
# version, so releases/latest/download/Indite.dmg, the README's download link,
# always fetches the newest one.
staging="$build/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Indite.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Indite -srcfolder "$staging" -format UDZO -quiet "$out/Indite.dmg"

# The update key, under the account "indite", copied there from "nscribe" the first
# time. Signing stops unless its public half is the one the app checks updates against.
sparkle_bin="$build/SourcePackages/artifacts/sparkle/Sparkle/bin"
if ! "$sparkle_bin/generate_keys" --account indite -p > /dev/null 2>&1 \
    && "$sparkle_bin/generate_keys" --account nscribe -p > /dev/null 2>&1; then
  # generate_keys will not export over an existing file, so it gets a fresh name in a
  # folder only this user can read.
  carry="$(mktemp -d)"
  chmod 700 "$carry"
  "$sparkle_bin/generate_keys" --account nscribe -x "$carry/key"
  "$sparkle_bin/generate_keys" --account indite -f "$carry/key"
  rm -P "$carry/key" 2>/dev/null || rm -f "$carry/key"
  rmdir "$carry"
fi
expected=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Configuration/Info.plist)
if [ "$("$sparkle_bin/generate_keys" --account indite -p 2>/dev/null)" != "$expected" ]; then
  echo "The key under the Keychain account \"indite\" is not the one SUPublicEDKey names."
  exit 1
fi

# The appcast names this release alone, which is all Sparkle needs. The notes beside
# the image become the text of the Software Update and What's New windows.
cp "$whats_new" "$out/Indite.md"
"$sparkle_bin/generate_appcast" --account indite \
  --download-url-prefix "https://github.com/frozenemitt/indite/releases/download/v$version/" \
  --embed-release-notes -o "$out/appcast.xml" "$out"

echo
echo "Indite $version is ready in $out"
echo "Create the GitHub release as a draft with:"
echo
# The GitHub page: what changed, then what Indite is and how to install it.
{
  printf '## What’s new\n\n'
  cat "$whats_new"
  printf '\n## About Indite\n\n'
  cat "$about"
} > "$out/release-notes.md"

echo "  gh release create v$version --draft --title 'Indite $version' --notes-file $out/release-notes.md $out/Indite.dmg $out/appcast.xml"
