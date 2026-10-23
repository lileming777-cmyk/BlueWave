# BlueWave Mac 1.0.6

修复关闭主窗口后无法再次显示播放器，以及退出后无法恢复上次歌曲和播放进度的问题。重开默认暂停，点击播放继续；Cmd-1 可以显示播放器。

曲库与播放列表无需重新导入。Mac 1.0.5 及更早版本没有完整的播放位置恢复逻辑，建议升级。Windows 仍为已发布的 1.0.4，本次未修改 Windows。

验证：78 项回归通过，1 项可选测试跳过；通过真实退出重开、关闭主窗后退出、恢复位置继续播放及安装包完整性验证。

支持 MP3、AAC/M4A、Ogg/Vorbis、Opus、WMA、FLAC、ALAC、APE、WAV、AIFF、WavPack、TTA、AU、CAF、DSF、DFF。DSF/DFF 通过 DSD 转 PCM 播放；OMA、AA3/ATRAC 已编译解码器，待对应样本验证。加密/DRM 文件不在已验证范围。

发现 bug 请发邮件至 [lileming777@gmail.com](mailto:lileming777@gmail.com)，注明版本、系统、音乐格式、复现步骤和错误提示，也可使用 [GitHub Issues](https://github.com/lileming777-cmyk/BlueWave/issues)。
