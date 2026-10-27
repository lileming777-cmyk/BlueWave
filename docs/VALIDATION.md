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


## Publication acceptance (2026-10-23)

Fresh Mac verification: 76 short tests passed including the opt-in live cover download; all three additional digital/audio soak tests passed, including 120 seconds of normalized high-rate playback with zero underruns and timestamp gaps. Windows source offscreen: 80 passed on macOS.

[Windows native build](https://github.com/lileming777-cmyk/BlueWave/actions/runs/39819512038) at application source commit `3a479ee4883a9fa92e91ec034e9bddda921a3320` succeeded: 79 tests passed, 1 optional local captured-response test skipped. Equivalent deterministic joint-query fixtures ran. Source and frozen EXE smoke checks succeeded, including FFprobe, real float32 decode and a Qt window. The Inno Setup installer and portable ZIP were produced. This does not constitute listening tests on arbitrary Windows audio hardware.

The public Git tree starts from a reviewed clean snapshot. Personal paths, music/library files, cover caches, firmware research and private development records are excluded. Build record machine prefixes are replaced while retaining decoder options. Release files carry SHA256 checksums.


## Mac 1.0.7（2026-10-27）

新增音频配置中断恢复、顺序子列表结束后转全曲库。13项新增测试，包含静音真实引擎停止及配置通知、暂停、用户取消、渐变、暂时失败重试和耗尽后的手动恢复、自然EOF切队列。Debug95项/Release92项各1个可选live网络测试跳过，0失败。120秒高采样率连续性：underrun0、timestamp gap0、内部最长零1帧，RSS峰值较初始增加约3.16MiB。

安装包签名、展开payload、目标路径及源码包检查通过；正式安装版保留既有曲库、队列和播放进度，已验证继续播放。真实手机/FaceTime来电与蓝牙硬件路由切换尚未现场验证。输出不可用时最多约30秒自动重试，之后保留进度提示手动续播。
