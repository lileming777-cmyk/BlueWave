# Third-party components

BlueWave application code is MIT licensed. It invokes FFmpeg and ffprobe as separate executables through pipes; it does not statically link FFmpeg libraries into the Swift application.

The distributed executables are built locally from the unmodified official **FFmpeg 9.0.2** release with `scripts/build-decoders.sh` (Mac) or the Windows build workflow. This build disables autodetection, network support, GPL components, and external codec libraries; zlib is explicitly enabled for PNG cover decoding and encoding. Mac uses the system zlib; Windows links the MSYS2 UCRT64 zlib package. The effective FFmpeg license is **LGPL 2.1 or later**, as reported by the built tools. The exact official source archive, configuration, hashes, license and build script accompany the release in the corresponding source package. No downloaded third-party GPL binary is shipped.

- Upstream: https://ffmpeg.org/
- Exact source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
- License: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
- Source notices: the included FFmpeg archive contains its own copyright and license notices.

Users may rebuild and replace `BlueWave.app/Contents/Resources/Tools/ffmpeg` and `ffprobe` with compatible versions. After replacement, reapply a local ad-hoc signature using `codesign --force --deep --sign - BlueWave.app`.

The Sony installation package, Walkman firmware, device identifiers, and personal music used for local research/testing are **not** part of the open-source distribution. BlueWave includes no Sony decoder binary, firmware, branding, music, or artwork. Icons are drawn by `scripts/build-icon.swift`; interface symbols come from the macOS system.

## Optional online cover artwork

BlueWave queries the MusicBrainz metadata API and downloads cover images via the Cover Art Archive HTTPS API when enabled and local artwork is absent. No audio or paths are uploaded. The API's availability does not grant copyright permission to redistribute artwork; downloaded images and private caches are excluded from application and source distributions. Source metadata URLs are saved with the cache. Service documentation: https://musicbrainz.org/doc/MusicBrainz_API and https://musicbrainz.org/doc/Cover_Art_Archive/API .

## Windows application

The Windows UI uses PySide6 / Qt 6.8.3 (LGPLv3), with shared Qt libraries included in the unpacked application. Source and license information: https://code.qt.io/cgit/pyside/pyside-setup.git/ and https://www.qt.io/licensing/open-source-lgpl-obligations . Users can modify the MIT application source and rebuild it against compatible Qt libraries. NumPy 2.0.2 uses BSD-3-Clause plus its bundled dependency notices; sounddevice 0.5.1 and PortAudio use MIT. PyInstaller 6.12.0 is a build tool with a bootloader exception allowing distribution of the frozen application. Python and runtime dependencies retain their upstream notices, collected into the Windows package's resources/Licenses folder. Exact Python dependencies are pinned in windows/requirements.txt; the Windows corresponding-source archive includes the build workflow, application source and FFmpeg source archive.

zlib source and permissive license: https://zlib.net/ . No changes are made to its source. This software is independent of Sony and does not implement DRM removal.


## Deezer cover lookup (1.0.4)

The application queries the public Deezer data API for artist/title metadata and downloads matching album artwork from returned Deezer CDN URLs. It does not request audio or previews. Matched metadata and a link to the official track page are available in the application. Artwork remains the property of its respective rights holders; cached images are not included in this repository's source or binary distributions. API availability and usage remain subject to [Deezer developer guidelines](https://developers.deezer.com/guidelines) and [terms](https://developers.deezer.com/termsofuse).
