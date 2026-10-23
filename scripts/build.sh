#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/bluewave-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
if [ ! -x Vendor/ffmpeg ] || [ ! -f Vendor/COPYING.LGPLv2.1 ]; then bash scripts/build-decoders.sh; fi
swift build -c release --disable-sandbox --cache-path "${TMPDIR:-/tmp}/bluewave-spm-cache"
binary_dir=$(swift build -c release --show-bin-path --disable-sandbox --cache-path "${TMPDIR:-/tmp}/bluewave-spm-cache")
app="dist/BlueWave-1.0.6/BlueWave.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Tools" "$app/Contents/Resources/Licenses" dist/AppIcon.iconset
cp "$binary_dir/BlueWave" "$app/Contents/MacOS/BlueWave"
cp Info.plist "$app/Contents/Info.plist"
cp Vendor/ffmpeg Vendor/ffprobe "$app/Contents/Resources/Tools/"
cp LICENSE THIRD_PARTY.md Vendor/COPYING.LGPLv2.1 Vendor/BUILD.txt Vendor/SHA256SUMS "$app/Contents/Resources/Licenses/"
python3 scripts/sanitize-build-records.py "$app/Contents/Resources/Licenses/BUILD.txt"
swift scripts/build-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app/Contents/Resources/Tools/ffmpeg"
codesign --force --sign - "$app/Contents/Resources/Tools/ffprobe"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
pkgbuild --component "$app" --install-location /Applications --identifier io.bluewave.player --version 1.0.6 dist/BlueWave-1.0.6-arm64.pkg
ditto -c -k --sequesterRsrc --keepParent "$app" dist/BlueWave-1.0.6-arm64.zip
bash scripts/package-source.sh
printf 'Built %s\n' "$PWD/$app"
