import SwiftUI
import BlueWaveCore

struct DetailPanel: View {
    @EnvironmentObject var model: PlayerModel
    let mode: String
    @State private var dragged: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(mode == "queue" ? "播放队列" : mode == "lyrics" ? "歌词" : "音频信息").font(.headline); Spacer(); Button { model.panel = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }.padding(20)
            Divider()
            if mode == "queue" { queue }
            else if mode == "lyrics" { lyrics }
            else { information }
        }.frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    private var queue: some View {
        List {
            ForEach(model.queue, id: \.self) { id in
                if let track = model.tracks.first(where: { $0.id == id }) {
                    HStack { Artwork(track: track, size: 34); VStack(alignment: .leading, spacing: 4) { Text(track.title).lineLimit(1).foregroundStyle(id == model.currentID ? Color.blue : Color.primary); Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if id == model.currentID { Image(systemName: "waveform").foregroundStyle(.blue) } }
                        .padding(.vertical, 5).contentShape(Rectangle()).onTapGesture(count: 2) { model.play(track) }
                        .contextMenu { Button("播放") { model.play(track) }; Button("移出队列") { model.removeQueue([id]) }.disabled(id == model.currentID) }
                        .onDrag { dragged = id; return NSItemProvider(object: id.uuidString as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { _ in guard let dragged, let from = model.queue.firstIndex(of: dragged), let to = model.queue.firstIndex(of: id) else { return false }; model.moveQueue(IndexSet(integer: from), from < to ? to + 1 : to); self.dragged = nil; return true }
                }
            }.onMove { model.moveQueue($0, $1) }.onDelete { offsets in model.removeQueue(Set(offsets.compactMap { model.queue.indices.contains($0) ? model.queue[$0] : nil })) }
            if model.queue.isEmpty { Text("播放歌曲后，队列会出现在这里").font(.callout).foregroundStyle(.secondary) }
        }.listStyle(.plain).scrollContentBackground(.hidden)
    }
    private var lyrics: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !model.lyricsSource.isEmpty {
                        Label(model.lyricsSource, systemImage: "doc.text").font(.caption).foregroundStyle(.blue)
                        Button("导出歌词…") { model.exportLyrics() }.font(.caption)
                    }
                    if model.lyrics.isEmpty && model.plainLyrics.isEmpty {
                        Image(systemName: "quote.bubble").font(.largeTitle).foregroundStyle(.blue.opacity(0.5)); Text("暂无可用歌词").font(.headline)
                        Text("自动读取同名 LRC 和内嵌歌词。可将歌词文件放在歌曲旁，使用相同文件名和 .lrc 扩展名。").font(.callout).foregroundStyle(.secondary)
                    }
                    if !model.plainLyrics.isEmpty { Text(model.plainLyrics).font(.system(size: 18, weight: .medium)).lineSpacing(12).textSelection(.enabled) }
                    ForEach(model.lyrics) { line in
                        Button { model.seek(line.time) } label: { Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: 19, weight: .semibold)).foregroundStyle(model.lyrics.activeIndex(at: model.position) == line.id ? Color.blue : Color.secondary.opacity(0.6)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).id(line.id)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.onChange(of: model.lyrics.activeIndex(at: model.position)) { _, index in if let index { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) } } }
        }
    }
    private var information: some View {
        ScrollView {
            if let track = model.current {
                VStack(alignment: .leading, spacing: 20) {
                    Artwork(track: track, size: 230, onlinePreview: true)
                    if model.artworkURL(for: track) == nil {
                        Text(model.coverStatus[track.id] ?? "暂无封面").font(.caption).foregroundStyle(.secondary)
                        Button("重新匹配封面") { model.retryCover(track) }
                    }
                    if let status = model.artworkSourceStatus(for: track) {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if let source = model.artworkAttribution(for: track) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("匹配：\(source.matchedArtist) · \(source.matchedTitle)")
                            if !source.matchedAlbum.isEmpty { Text(source.matchedAlbum) }
                            Link(source.provider == .deezer ? "封面来源：Deezer" : "封面来源：MusicBrainz / CAA", destination: source.sourceURL)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Text(track.title).font(.title3.weight(.semibold))
                    Text("\(track.artist)\n\(track.album)").font(.callout).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("文件格式", value: track.fileFormat)
                    LabeledContent("编码", value: track.codec.uppercased())
                    LabeledContent("采样率", value: "\(track.sampleRate) Hz")
                    LabeledContent("位深", value: track.bitDepth > 0 ? "\(track.bitDepth) bit" : "未提供")
                    LabeledContent("声道", value: "\(track.channels)")
                    LabeledContent("时长", value: timeLabel(track.duration))
                    LabeledContent("信息来源", value: track.metadataSource ?? "文件标签")
                    LabeledContent("软件输出", value: String(format: "%g kHz PCM", model.audio.effectiveSampleRate / 1000))
                    LabeledContent("处理精度", value: "\(model.audio.effectivePrecision) bit\(model.audio.effectivePrecision == 32 ? " 浮点" : " 量化")")
                    Divider()
                    Text("输出至系统音频设备。DSD 会转换为 PCM，其他音源按原采样率输出，最高 192 kHz。系统混音器可能再次转换采样率。").font(.caption).foregroundStyle(.secondary)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
                }.font(.callout).padding(24)
            } else { Text("选择并播放歌曲后查看音频信息").foregroundStyle(.secondary).padding(24) }
        }
    }
}
