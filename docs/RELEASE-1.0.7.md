# Mac 1.0.7

- 通话、蓝牙模式或系统输出配置变化使音频引擎停止后，保留歌曲、队列和进度，输出可用时自动重建播放；原先暂停保持暂停。恢复等待时点暂停、停止、拖动进度或换歌，会取消旧恢复任务。
- 顺序播放的子列表自然播完后，转入全部曲目，从曲库开头继续，略过与上一首相同的首项。全曲库播完仍停止；列表循环、单曲循环与随机行为不变。
- 输出暂时不可用时最多自动重试30次（约30秒）；持续不可用会提示并保留进度，设备恢复后可点击播放续播。

Mac 版本 1.0.7/build8。Windows 本次没有更新，请继续使用 [Windows 1.0.4](https://github.com/lileming777-cmyk/BlueWave/releases/tag/v1.0.4)。

实现依据：Apple的AVAudioEngineConfigurationChange文档说明硬件通道数/采样率变化会停止并反初始化引擎：
https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange

测试采用真实静音AVAudioEngine停止及同名配置通知，覆盖中断、暂停、取消、渐变、重试失败和自然结束。真实手机/FaceTime来电以及蓝牙硬件路由变化仍需用户现场验证；不声称已做真实通话验收。
