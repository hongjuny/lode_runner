#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch_path=${LODE_RUNNER_SCRATCH:-/tmp/lode-runner-swift-build}
app_path="$project_root/Build/LodeRunner.app"
product_root="$scratch_path/out/Products/Release"

cd "$project_root"
swift build --configuration release --scratch-path "$scratch_path"
mkdir -p "$project_root/Build"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$product_root/LodeRunnerMac" "$app_path/Contents/MacOS/LodeRunner"
for resource in levels sprites splash; do
  install -m 644 "$product_root/LodeRunnerPort_LodeRunnerCore.bundle/Contents/Resources/$resource.bin" \
    "$app_path/Contents/Resources/$resource.bin"
done
install -m 644 "$project_root/Assets/LodeRunner.icns" "$app_path/Contents/Resources/LodeRunner.icns"
install -m 644 "$project_root/Sources/LodeRunnerMac/Info.plist" "$app_path/Contents/Info.plist"
codesign --force --deep --sign - "$app_path"
printf '%s\n' "$app_path"
