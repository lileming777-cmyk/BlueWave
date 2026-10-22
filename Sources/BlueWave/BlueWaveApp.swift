import SwiftUI
import AppKit
import BlueWaveCore

@main struct BlueWaveApp: App {
    @StateObject private var model: PlayerModel = {
        // Optional separate data profile for development; never overwrites the main library.
        if let folder = ProcessInfo.processInfo.environment["BLUEWAVE_DATA_DIRECTORY"] {
            return PlayerModel(storeURL: URL(fileURLWithPath: folder).appendingPathComponent("library.json"), enableMediaCommands: false)
        }
        return PlayerModel()
    }()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("BlueWave · 蓝调音乐") {
            LibraryView().environmentObject(model)
                .tint(.blue)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onOpenURL { url in model.enqueueImportURLs([url]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.audio.stop(); model.persist() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入音乐…") { model.pickFiles() }.keyboardShortcut("o")
                Button("导入 WALKMAN 音乐") { model.importWalkman() }
            }
            CommandMenu("播放") {
                Button(model.playing ? "暂停" : "播放") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("下一首") { model.advance() }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("上一首") { model.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("停止") { model.stop() }.keyboardShortcut(".")
                Divider()
                Toggle("随机播放", isOn: $model.shuffle)
                Button("切换循环模式") { model.repeatMode = (model.repeatMode + 1) % 3 }
                Button("收藏当前歌曲") { if let id = model.currentID { model.favorite(id) } }.keyboardShortcut("l")
            }
        }
        Settings { PreferencesView().environmentObject(model).tint(.blue) }
    }
}

struct PreferencesView: View {
    @EnvironmentObject var model: PlayerModel
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.pickerStyle(.segmented)
            }
            Section("音频播放") {
                Picker("输出采样率", selection: $model.outputRate) {
                    Text("跟随音源（最高 192 kHz）").tag(0)
                    ForEach([44100, 48000, 88200, 96000, 176400, 192000], id: \.self) { rate in Text(String(format: "%g kHz", Double(rate) / 1000)).tag(rate) }
                }
                Picker("软件输出精度", selection: $model.outputPrecision) { Text("16 bit").tag(16); Text("24 bit").tag(24); Text("32 bit 浮点").tag(32) }
                Text("下一次播放或跳转进度时生效。16/24 bit 在软件中量化后送入系统浮点混音；硬件最终格式以系统声音设置和设备为准。提高采样率不会补回音源缺失的信息。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("音量统一", isOn: $model.normalizeVolume)
                Text("自动调整歌曲响度，目标 −18 LUFS，峰值限制 −1.5 dB。开关从下一次播放开始生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("歌曲平滑过渡", isOn: $model.crossfadeEnabled)
                if model.crossfadeEnabled {
                    HStack { Text("过渡时长"); Slider(value: $model.crossfadeDuration, in: 1...8, step: 1); Text("\(Int(model.crossfadeDuration)) 秒").monospacedDigit().frame(width: 40) }
                    Text("自动播放下一首时淡入淡出；单曲循环时不启用。可随时暂停或跳过。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("使用当前系统音频输出设备。DSF / DFF 转换为 PCM 播放，最高输出 192 kHz；DSD 使用 176.4 kHz。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开系统声音设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
            }
            Section("歌词") {
                Text("自动读取同名 LRC 和内嵌歌词；缺失时显示暂无歌词，可自行提供 LRC。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("封面") {
                Toggle("缺少本地封面时自动下载", isOn: $model.autoDownloadCovers)
                Text("优先读取内嵌和本地图片；为当前播放歌曲和可见封面卡片以歌手＋歌名联合搜索并核对匹配，下载后缓存；无匹配时显示歌名。不会上传音乐或文件路径。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("封面来自 Deezer、MusicBrainz / Cover Art Archive，图片版权属于相关权利人。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本地资料库") {
                LabeledContent("歌曲", value: "\(model.tracks.count) 首")
                LabeledContent("播放列表", value: "\(model.playlists.count) 个")
                Button("在 Finder 中显示曲库位置") { NSWorkspace.shared.open(model.dataDirectory) }
                Text("移除歌曲只改变资料库记录，不会删除音乐原文件。数据保存在本机，不上传音乐。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("关于 BlueWave") {
                Text("蓝调音乐 1.0.4 · Apple Silicon · macOS 14 或更新版本")
                Text("Swift 原生应用 · FFmpeg 9.0.2 解码\n应用源码采用 MIT 许可证；独立 FFmpeg 工具采用 LGPL 2.1 或更新版本。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("查看许可证") { if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses") { NSWorkspace.shared.open(url) } }
            }
        }.formStyle(.grouped).frame(width: 560, height: 700)
    }
}

struct Artwork: View {
    @EnvironmentObject var model: PlayerModel
    var track: Track?
    var size: CGFloat = 44
    var onlinePreview = false
    @State private var previewOwner = UUID()
    var body: some View {
        Group {
            if let track, let url = model.artworkURL(for: track), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.1, green: 0.46, blue: 0.98), Color(red: 0.13, green: 0.23, blue: 0.59)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let title = track?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                        Text(title).font(.system(size: max(9, size * 0.15), weight: .semibold))
                            .multilineTextAlignment(.center).lineLimit(size < 60 ? 2 : 3)
                            .minimumScaleFactor(0.55).foregroundStyle(.white)
                            .padding(size * 0.12)
                    } else {
                        Image(systemName: "waveform").font(.system(size: size * 0.38, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                    }
                }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: max(5, size * 0.12)))
             .help(track.flatMap { model.artworkSourceStatus(for: $0) ?? model.coverStatus[$0.id] } ?? "优先读取内嵌或本地封面")
            .task(id: track?.id) { if let track { model.requestCover(track, preview: onlinePreview, owner: previewOwner) } }
            .onDisappear { if onlinePreview { model.releaseCoverPreview(owner: previewOwner) } }
    }
}
