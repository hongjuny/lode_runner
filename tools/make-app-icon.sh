#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_png="$project_root/Assets/LodeRunnerIcon.png"
icon_work=$(mktemp -d "${TMPDIR:-/tmp}/lode-runner-icon.XXXXXX")
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/LodeRunner.iconset"
mkdir "$iconset"

for points in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=
    if [ "$scale" -eq 2 ]; then suffix=@2x; fi
    pixels=$((points * scale))
    sips -s format png -z "$pixels" "$pixels" "$source_png" \
      --out "$iconset/icon_${points}x${points}${suffix}.png" >/dev/null
  done
done

iconutil -c icns "$iconset" -o "$project_root/Assets/LodeRunner.icns"
