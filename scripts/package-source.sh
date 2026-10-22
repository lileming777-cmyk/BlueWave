#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_dir=dist/BlueWave-1.0.4-source
rm -rf dist/BlueWave-1.0.4-source
mkdir -p "$source_dir" "$source_dir/third-party/ffmpeg"
cp Package.swift Info.plist LICENSE THIRD_PARTY.md README.md "$source_dir/"
ditto Sources "$source_dir/Sources"
ditto Tests "$source_dir/Tests"
ditto scripts "$source_dir/scripts"
ditto windows "$source_dir/windows"
# Exclude generated/private caches from the corresponding source archive.
rm -rf "$source_dir/windows/resources/Tools" "$source_dir/windows/resources/Licenses" "$source_dir/windows/build" "$source_dir/windows/dist"
find "$source_dir/windows" -type d -name __pycache__ -prune -exec rm -rf {} +
ditto .github "$source_dir/.github"
if [ -d docs ]; then ditto docs "$source_dir/docs"; fi
cp Downloads/ffmpeg-9.0.2.tar.xz Vendor/ffmpeg-config.h Vendor/ffmpeg-config.mak Vendor/BUILD.txt Vendor/SHA256SUMS Vendor/COPYING.LGPLv2.1 "$source_dir/third-party/ffmpeg/"
python3 scripts/sanitize-build-records.py "$source_dir/third-party/ffmpeg/ffmpeg-config.h" "$source_dir/third-party/ffmpeg/ffmpeg-config.mak" "$source_dir/third-party/ffmpeg/BUILD.txt"
cp .gitignore "$source_dir/.gitignore"
ditto -c -k --keepParent "$source_dir" dist/BlueWave-1.0.4-source.zip

python3 scripts/verify-public-source.py dist/BlueWave-1.0.4-source.zip
