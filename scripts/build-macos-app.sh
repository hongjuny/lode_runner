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
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>LodeRunner</string>
  <key>CFBundleIdentifier</key><string>org.loderunner.reveng.port</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Lode Runner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_path"
printf '%s\n' "$app_path"
