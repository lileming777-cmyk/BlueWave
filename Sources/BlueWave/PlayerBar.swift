import SwiftUI
import BlueWaveCore

struct PlayerBar: View {
    @EnvironmentObject var model: PlayerModel
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    var body: some View {
        HStack(spacing: 22) {
            HStack(spacing: 12) {
                Artwork(track: model.current, size: 52)
                VStack(alignment: .leading, spacing: 5) { Text(model.current?.title ?? "还没有正在播放的音乐").font(.callout.weight(.medium)).lineLimit(1); Text(model.transitioning ? "正在平滑过渡…" : model.current.map { "\($0.artist) · \($0.fileFormat)" } ?? "选一首音乐，开始聆听").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let track = model.current { Button { model.favorite(track.id) } label: { Image(systemName: track.favorite ? "heart.fill" : "heart").foregroundStyle(track.favorite ? .blue : .secondary) }.buttonStyle(.plain).help("收藏") }
            }.frame(minWidth: 180, maxWidth: 290, alignment: .leading)
            VStack(spacing: 9) {
                HStack(spacing: 22) {
                    Button { model.shuffle.toggle() } label: { Image(systemName: "shuffle").font(.system(size: 13)).foregroundStyle(model.shuffle ? Color.blue : Color.secondary) }.help("随机播放")
                    Button { model.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 17)) }.help("上一首")
                    Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).frame(width: 38, height: 38).background(.blue, in: Circle()) }.help(model.playing ? "暂停（空格）" : "播放（空格）").accessibilityLabel(model.playing ? "暂停" : "播放")
                    Button { model.advance() } label: { Image(systemName: "forward.end.fill").font(.system(size: 17)) }.help("下一首")
                    Button { model.repeatMode = (model.repeatMode + 1) % 3 } label: { Image(systemName: model.repeatMode == 2 ? "repeat.1" : "repeat").font(.system(size: 13)).foregroundStyle(model.repeatMode > 0 ? Color.blue : Color.secondary) }.help(["顺序播放", "列表循环", "单曲循环"][model.repeatMode])
                }.buttonStyle(.plain)
                HStack(spacing: 9) {
                    Text(timeLabel(scrubbing ? scrubPosition : model.position)).frame(width: 38, alignment: .trailing)
                    Slider(value: Binding(get: { scrubbing ? scrubPosition : min(model.position, model.current?.duration ?? 0) }, set: { scrubPosition = $0 }), in: 0...max(1, model.current?.duration ?? 1), onEditingChanged: { editing in
                        if editing { scrubPosition = model.position; scrubbing = true }
                        else { model.seek(scrubPosition); scrubbing = false }
                    }).controlSize(.mini).disabled(model.current == nil)
                    Text(timeLabel(model.current?.duration ?? 0)).frame(width: 38, alignment: .leading)
                }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1).controlSize(.mini).frame(width: 70).help("音量")
                panelButton("quote.bubble", "lyrics", "歌词")
                panelButton("list.bullet", "queue", "播放队列")
                panelButton("info.circle", "info", "音频信息")
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(.bar)
    }
    private func panelButton(_ image: String, _ panel: String, _ title: String) -> some View {
        Button { model.panel = model.panel == panel ? nil : panel } label: { Image(systemName: image).font(.system(size: 14)).foregroundStyle(model.panel == panel ? Color.blue : Color.secondary) }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}
