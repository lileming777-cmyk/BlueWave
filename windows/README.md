# BlueWave 蓝调音乐 · Windows 1.0.4

Windows 10/11 x64 本地音乐播放器。1.0.4 已移除自动听写，封面改为歌手与完整歌名联合匹配，加入同专辑回退与歌名卡；当前为更新后的本地源码，Windows EXE 需要在 Windows 原生环境重新构建，旧版 EXE 不包含此修改。解压完整 Windows ZIP，双击文件夹内的 `BlueWave.exe`；保留同级 `_internal` 文件夹，无需安装 Python 或 FFmpeg；本地音频播放无需联网。此应用尚未进行 Windows 代码签名，下载后可能出现 SmartScreen 提示。

- 导入音乐文件、整个文件夹，或拖放多个文件/文件夹；重复路径不会重复入库。双击歌曲播放。搜索匹配曲名、艺人、专辑；专辑/艺人视图可选择分组，收藏和最近播放在侧边栏。
- 点击「新建播放列表」；右键歌曲添加、移除、收藏、加入队列。右键列表重命名、删除。在完整、未搜索的播放列表中拖动行排序，或右键上移/下移。详情中的队列提供排序、移除和双击播放。
- 空格播放/暂停，Ctrl+O 导入，Ctrl+←/→ 切歌，Ctrl+L 收藏当前歌曲。可拖动进度、调音量、随机或循环播放。停止、切歌、跳转会取消旧解码任务。
- 「详情 / 歌词」读取同名 `.lrc` 和内嵌歌词，可导出歌词，双击带时间轴的歌词可跳转。没有本地歌词时明确提示无歌词；不进行语音识别，不再读取旧版自动听写缓存。
- 封面优先取内嵌图片，然后取同名或 cover/folder/front/封面图片；都没有时，默认仅为当前播放歌曲自动查找在线封面，可在设置关闭。仅发送曲名、艺人、专辑名，不上传音乐、文件路径或缓存，不扫描整库。缺失专辑标签时使用目录名称，并在详情中显示推断来源；在线封面不会修改歌曲标签，不读取 CUE。
- 设置中可独立启用音量统一（单遍 loudnorm，−18 LUFS、真峰值 −1.5 dB、LRA 11）和平滑过渡（1–8 秒）；默认关闭。过渡使用两个共享输出流，单曲循环时关闭。
- 采样率可跟随音源或选择 44.1/48/88.2/96/176.4/192 kHz；16/24 bit 软件量化或 32 bit 浮点。设置在下次播放或跳转时生效。最终设备格式由 Windows 和音频硬件决定，不支持独占输出或位完美保证。
- 标题栏「••• → 清空并重新导入」先选择来源、确认，再在新音频读取成功后替换当前列表或整个曲库记录。清空前备份曲库。取消选择/导入、全部读取失败都会保留现有记录；音乐原文件始终保留。

支持常见 FFmpeg 音频格式，包括 MP3、AAC/M4A、WAV/AIFF、FLAC/ALAC、Ogg/Opus、WMA、WavPack、TTA、AU/CAF、APE，以及 DSF/DFF 转 PCM。支持能力取决于随包 FFmpeg；不支持加密文件、原生 DSD/DoP、设备固件功能、Windows 媒体键集成或缩略封面网格。普通音源软件采样率上限 192 kHz，DSD 默认 176.4 kHz。设备不支持所选输出采样率时会显示错误，可改为 44.1/48 kHz 重试。

曲库位于 `%LOCALAPPDATA%\BlueWave\library.json`；`Covers`、`Backups` 分别保存封面和备份。旧版 `Transcripts` 自动听写缓存文件保留在磁盘，但不再读取或显示。歌曲只记录原始路径，外置磁盘断开时保留记录。损坏曲库会提示并保留原件，应用不会静默覆盖。Windows 和 Mac 的曲库各自独立；并非自动同步。

文件没有标题/艺人标签时，按文件名作保守推断：`Artist - Song` 或 `01 Artist - Song` 以歌手在前；`01 趁早 -孙露` 这种仅连字符前有空格的形式按曲名在前。只移除开头曲序数字，不会把标准歌手在前的格式反转。内嵌标题和艺人标签优先。旧曲库中艺人未知的歌曲在当前播放封面加载前会仅重新探测该文件，并保存更新后的资料库元数据，保留歌曲 ID、收藏与播放列表引用；不批量扫描整个曲库，也不写入音乐原文件。

## 在线封面匹配与缓存

先查询 Deezer 的公开歌曲元数据（`https://api.deezer.com/search`，仅传歌手与歌名、最多 10 条），必须同时精确匹配 `artist.name` 和完整 `title`，不会用 `title_short` 放行 Live/翻唱等不同标题。同名但歌手不同、同歌手但歌名不同都拒绝。多条联合匹配结果优先取专辑名称一致者，仅下载返回专辑的 `cover_big` 或 `cover_medium`；不会请求试听音频、音频流或用户音乐。

Deezer 无匹配或暂不可用时，使用 [MusicBrainz 元数据搜索](https://musicbrainz.org/doc/MusicBrainz_API/Search) 的 recording 查询；同样要求歌手和完整歌名标准化后精确匹配，评分至少 90。只从该录音关联的 Official 或 Pseudo-Release 发行版中取 [Cover Art Archive](https://musicbrainz.org/doc/Cover_Art_Archive/API) 封面，专辑一致者优先；不再仅凭歌手与专辑相同就取图。若发行版另有艺人信息，也必须对应。

比较时统一 Unicode、大小写、标点与空白；未知艺人、无法保守确认的联合艺人保留无图结果。同名艺人的身份与版本仍可能歧义，不能保证每首歌曲都能取得图片。当前歌曲自身封面优先：内嵌/本地目录图，然后自身精确在线匹配。仍无图时，只在资料库内相同已知艺人、相同已知专辑的曲目中读取已解析封面、已有磁盘缓存或目录图片；不会为这些兄弟曲目联网，未知专辑不会混合共享。借用专辑图不会写入当前歌曲自身封面缓存，之后仍能尝试自身匹配。再无图则在蓝底卡片直接显示歌名；仅未选择歌曲时显示音乐符号。

只有当前播放歌曲触发在线请求，不扫描整库；切歌或停止后取消回填，正在进行的连接可能等待 10 秒超时。元数据 503/429 最多延时 1.2 秒重试一次，图片不重试；所有提供方元数据请求（含重试）共享全应用至少 1 秒间隔。图片单次最大 8 MiB，校验 PNG/JPEG/WebP 能解码并限制尺寸。Deezer 图片与其重定向仅允许 HTTPS 的 `cdn-images.dzcdn.net`、`e-cdns-images.dzcdn.net`；CAA 图片仅允许 HTTPS 的 `coverartarchive.org`、`archive.org` 及子域，元数据重定向不能跨提供方。

成功图片与来源记录保存在 `Covers/Online`，记录包含 provider、匹配的歌手/歌名/专辑、图片来源和官网歌曲链接；悬停封面可查看。命中缓存不联网，旧版本缓存保留兼容（旧记录没有新版本的完整匹配证明）。下载不会改变歌曲原标签；关闭自动下载后仍可使用已有本地/同专辑图片，缓存文件保留。

API 可访问并不授予图片版权或再发行许可；下载的专辑封面仅保存在用户本机，不随应用源码或发布包打包。请遵守图片权利人的使用条件。

## 从源码运行和打包

推荐 Windows x64 CPython 3.12。依赖固定在 `requirements.txt`。在 `windows` 目录执行：

```powershell
py -3.12 -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe -m unittest discover -s tests -v
.venv\Scripts\python.exe bluewave.py
```

先将 `ffmpeg.exe`、`ffprobe.exe` 放在 `resources\Tools`，不再需要语音识别引擎或模型。工具路径可通过 `BLUEWAVE_TOOLS` 覆盖；源码在 Mac 开发时也会回退使用上级 `Vendor`。测试资料库可用环境变量 `BLUEWAVE_DATA_DIRECTORY` 隔离。

```powershell
.venv\Scripts\python.exe -m PyInstaller --noconfirm --clean --onedir --windowed --name BlueWave --add-data "resources;resources" bluewave.py
$p = Start-Process -FilePath .\dist\BlueWave\BlueWave.exe -ArgumentList '--smoke-test' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw 'BlueWave smoke test failed' }
```

需要分发整个 `dist\BlueWave` 文件夹，连同项目和第三方许可证、工具来源与对应上游源码说明。PyInstaller 包会将资源放在 `_internal\resources\Tools`，应用通过 `sys._MEIPASS` 定位。不能从 macOS 交叉打包 Windows 应用，应在 Windows 构建。

`--smoke-test` 使用临时曲库生成真实 WAV、验证 ffprobe 探测和 FFmpeg 立体声 float32 解码，并在 offscreen 模式启动/关闭 Qt 窗口；不需要语音识别工具、模型或音频设备，不写入个人资料库。单元测试使用真实 PCM 消费端测试流式解码、结束和取消；GUI 测试运行真正的 Qt 事件循环，覆盖导入/搜索/列表/取消/失败保留，以及本地歌词、导出、忽略旧听写缓存、无歌词不启动后台识别和在线封面的当前曲目/取消/开关。在线封面测试使用虚构元数据和内存 HTTP fixture，不请求私人歌曲；覆盖歌手不匹配拒绝、缓存、节流、尺寸限制及断网占位。后台测试不等于真实扬声器试听；Windows 实机音频、设备切换、跨曲过渡和长时间播放仍需人工验收。

应用源码 MIT；Qt/PySide6 LGPLv3，PortAudio MIT，FFmpeg 许可证取决于构建（分发包应使用 LGPL 构建），其他依赖按随包许可证。完整第三方声明见项目 `THIRD_PARTY.md`。
