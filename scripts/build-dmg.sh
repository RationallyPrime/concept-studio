#!/bin/bash
# Builds the shareable disk image from a release build: scripts/build-app.sh release first (signed
# with Developer ID and notarized), then
#
#   CONCEPTSTUDIO_SIGNING_IDENTITY='Developer ID Application: Name (TEAMID)' \
#     CONCEPTSTUDIO_NOTARY_PROFILE=<profile> scripts/build-dmg.sh
#
# The image holds the app and a link to /Applications, with the app's icon as its volume icon. It
# is signed with the same identity, notarized and stapled, so it opens without warnings offline.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
signing_identity="${CONCEPTSTUDIO_SIGNING_IDENTITY:?set CONCEPTSTUDIO_SIGNING_IDENTITY to a Developer ID Application identity}"
notary_profile="${CONCEPTSTUDIO_NOTARY_PROFILE:?set CONCEPTSTUDIO_NOTARY_PROFILE to a notarytool keychain profile}"
app="$repo_dir/app/dist/ConceptStudio.app"

# Only a notarized Developer ID build goes into a shareable image.
signature="$(codesign -dvv "$app" 2>&1)"
grep -Fq "Authority=Developer ID Application" <<< "$signature" \
    || { echo "$app is not a Developer ID build; run scripts/build-app.sh release first." >&2; exit 2; }
xcrun stapler validate "$app" > /dev/null \
    || { echo "$app has no notarization ticket; run the release build with CONCEPTSTUDIO_NOTARY_PROFILE." >&2; exit 2; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$repo_dir/app/dist/ConceptStudio-$version-$(date -u +%Y%m%d).dmg"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/ConceptStudio.app"
ln -s /Applications "$stage/Applications"
cp "$app/Contents/Resources/ConceptStudio.icns" "$stage/.VolumeIcon.icns"

# A writable image first, so the volume can be marked as having a custom icon, then compressed.
rw="$stage.rw.dmg"
rm -f "$rw" "$dmg"
hdiutil create -quiet -volname ConceptStudio -srcfolder "$stage" -fs HFS+ -format UDRW "$rw"
mount="$(hdiutil attach -nobrowse -noverify -noautoopen "$rw" | awk -F'\t' '/\/Volumes\//{print $NF}')"
SetFile -a C "$mount"
hdiutil detach -quiet "$mount"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
rm -f "$rw"

codesign --force --sign "$signing_identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "$dmg"
