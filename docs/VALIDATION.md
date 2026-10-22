# BlueWave validation

Mac: Apple Silicon, macOS 14 or newer. Windows: Windows 10/11 x64; native build and frozen-program checks are required before publishing an EXE.

## Audio

The format matrix covers WAV, AIFF, FLAC, ALAC, MP3, AAC/M4A, Ogg/Vorbis, Opus, WMA, WavPack, TTA, AU, CAF, DSF and DFF. Additional local APE and DTS fixtures were decoded successfully. ATRAC/OMA/AA3 decoders are compiled but corresponding samples have not been verified. DRM-protected files are not validated.

Version 1.0.3 fixed consumed PCM Data retention. A 120-second synthetic 192 kHz playback check with normalization and four one-second main-thread stalls completed with zero reported underruns and timestamp gaps. Debug mixer capture measured at most one internal zero frame. The optimized no-capture check also completed and reached a stable memory plateau. These digital tests do not establish acoustic Bluetooth or speaker quality.

## Version 1.0.4

Mac short suite: 76 tests; the opt-in fresh-cache online cover test was also run successfully. Release tests: 75 passed, 1 online test skipped by default, zero failures. Windows source: 80 Qt offscreen tests passed on macOS; this alone does not establish Windows native execution.

Coverage includes exact full artist/title queries, wrong-singer rejection, album ranking, independent provider budgets, retry throttling, HTTPS redirect restrictions, image validation, cancellation and cache reload. Offscreen SwiftUI checks verify downloaded pixels, different song-title fallback cards and album artwork without overwriting a song's own cache. Unknown albums and different singers do not share artwork. Own cached images are readable with online lookup disabled.

Mac can discover an unplayed sibling track's embedded artwork offline. Windows currently shares existing artwork/cache/directory images; a sibling's embedded artwork becomes available after that track has been loaded.

Publishing checks verify application and installer signatures, expanded installer payload hashes, source archive integrity, private-path exclusions, decoder tools and release SHA256 checksums. Downloaded cover images, personal music, local libraries and development logs are excluded from releases. Source code and decoder notices are included.
