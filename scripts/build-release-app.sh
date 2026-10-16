#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
release_root="$project_root/Build/Release"
product_root="$release_root/Products"
built_app="$product_root/LodeRunner.app"
staging_root="$release_root/Staging"
staged_app="$staging_root/LodeRunner.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$project_root/Sources/LodeRunnerMac/Info.plist")
archive_name="LodeRunner-$version-macOS.zip"

build_app() {
  cd "$project_root"
  xcodebuild -quiet -project LodeRunner.xcodeproj -scheme LodeRunner \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$release_root/DerivedData" build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "CONFIGURATION_BUILD_DIR=$product_root"
  lipo -verify_arch arm64 "$built_app/Contents/MacOS/LodeRunner"
  lipo -verify_arch x86_64 "$built_app/Contents/MacOS/LodeRunner"
  test -f "$built_app/Contents/Resources/LodeRunner.icns"
  for resource in levels sprites splash; do
    test -f "$built_app/Contents/Resources/$resource.bin"
  done
  printf 'Universal release build: %s\n' "$built_app"
}

finish_release() {
  notary_result="$staging_root/notary-result.plist"
  if [ ! -d "$staged_app" ] || [ ! -f "$staging_root/LodeRunner-notary.zip" ] ||
     [ ! -f "$notary_result" ]; then
    printf 'Missing staged app or accepted notarization result; run the full release first.\n' >&2
    exit 1
  fi
  status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$notary_result")
  if [ "$status" != Accepted ]; then
    printf 'Notarization status: %s. See %s\n' "$status" "$notary_result" >&2
    exit 1
  fi

  codesign --verify --deep --strict --verbose=2 "$staged_app"
  xcrun stapler staple "$staged_app"
  xcrun stapler validate "$staged_app"
  codesign --verify --deep --strict --verbose=2 "$staged_app"
  spctl --assess --type execute --verbose=4 "$staged_app"

  archive="$release_root/$archive_name"
  ditto -c -k --keepParent "$staged_app" "$archive"
  cd "$release_root"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
  printf 'Notarized release archive: %s\n' "$archive"
  printf 'SHA-256 checksum: %s.sha256\n' "$archive"
}

if [ "${1:-}" = "--build-only" ]; then
  build_app
  exit 0
fi
if [ "${1:-}" = "--finish" ]; then
  finish_release
  exit 0
fi
if [ "$#" -ne 0 ]; then
  printf 'Usage: sh scripts/build-release-app.sh [--build-only|--finish]\n' >&2
  exit 2
fi

identity=${DEVELOPER_ID_APPLICATION:-}
profile=${NOTARY_PROFILE:-}
case "$identity" in
  "Developer ID Application:"*) ;;
  *) printf 'Set DEVELOPER_ID_APPLICATION to your Developer ID Application certificate name.\n' >&2; exit 2 ;;
esac
if [ -z "$profile" ]; then
  printf 'Set NOTARY_PROFILE to a notarytool keychain profile name.\n' >&2
  exit 2
fi

build_app
mkdir -p "$staging_root"
rm -rf "$staged_app"
ditto "$built_app" "$staged_app"
codesign --force --options runtime --timestamp --sign "$identity" "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

notary_archive="$staging_root/LodeRunner-notary.zip"
ditto -c -k --keepParent "$staged_app" "$notary_archive"
notary_result="$staging_root/notary-result.plist"
xcrun notarytool submit "$notary_archive" --keychain-profile "$profile" \
  --wait --timeout 1h --output-format plist > "$notary_result"
finish_release
