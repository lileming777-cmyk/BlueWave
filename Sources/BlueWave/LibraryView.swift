import SwiftUI
import UniformTypeIdentifiers
import BlueWaveCore

struct LibraryView: View {
    @EnvironmentObject var model: PlayerModel
    @State private var selection = Set<UUID>()
    @State private var showPlaylistEditor = false
    @State private var editingPlaylist: UUID?
    @State private var playlistName = ""
    @State private var gridView = false
    @State private var draggedTrack: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 214)
                Divider()
                VStack(spacing: 0) {
                    header
                    if model.importing { importBanner }
                    if model.visibleTracks.isEmpty { emptyState }
                    else if model.section == "albums" && model.albumFilter == nil { collectionGrid(artist: false) }
                    else if model.section == "artists" && model.artistFilter == nil { collectionGrid(artist: true) }
                    else if gridView { songGrid }
                    else { songList }
                    footer
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let panel = model.panel { Divider(); DetailPanel(mode: panel).frame(width: 290) }
            }
            Divider()
            PlayerBar()
        }
        .frame(minWidth: 900, minHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            DropLoader.load(providers) { urls in if !urls.isEmpty { model.importURLs(urls) } }
            return !providers.isEmpty
        }
        .sheet(isPresented: $showPlaylistEditor) { playlistEditor }
        .alert("提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
        .onChange(of: model.section) { _, _ in selection = [] }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Artwork(size: 34)
                VStack(alignment: .leading, spacing: 2) { Text("BlueWave").font(.system(size: 18, weight: .bold)); Text("蓝调音乐").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text("音乐资料库").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 5)
                    navigation("歌曲", "music.note", "songs")
                    navigation("专辑", "square.stack", "albums")
                    navigation("艺人", "person.crop.circle", "artists")
                    navigation("我的收藏", "heart", "favorites")
                    navigation("最近播放", "clock.arrow.circlepath", "recent")
                    HStack {
                        Text("播放列表").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { editingPlaylist = nil; playlistName = ""; showPlaylistEditor = true } label: { Image(systemName: "plus").font(.caption.weight(.semibold)) }.buttonStyle(.plain).help("创建播放列表").accessibilityLabel("创建播放列表")
                    }.padding(.horizontal, 14).padding(.top, 25).padding(.bottom, 7)
                    ForEach(model.playlists) { playlist in
                        navigation(playlist.name, "music.note.list", playlist.id.uuidString)
                            .contextMenu {
                                Button("重命名…") { editingPlaylist = playlist.id; playlistName = playlist.name; showPlaylistEditor = true }
                                Button("播放") { if let first = playlist.trackIDs.compactMap({ id in model.tracks.first { $0.id == id } }).first { model.queue = playlist.trackIDs; model.play(first) } }
                                Divider()
                                Button("删除播放列表", role: .destructive) { model.deletePlaylist(playlist.id) }
                            }
                    }
                    if model.playlists.isEmpty { Text("创建列表，收集喜欢的旋律").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 8) }
                    Text("设备").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 24).padding(.bottom, 5)
                    Button { model.importWalkman() } label: { Label("WALKMAN", systemImage: "ipod").frame(maxWidth: .infinity, alignment: .leading).padding(10) }.buttonStyle(.plain).foregroundStyle(.secondary).help("导入已连接播放器的音乐")
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 12)
            SettingsLink { Label("设置", systemImage: "gearshape").font(.callout).foregroundStyle(.secondary) }.buttonStyle(.plain).padding(23)
        }.frame(maxHeight: .infinity).background(.ultraThinMaterial)
    }
    private func navigation(_ title: String, _ icon: String, _ key: String) -> some View {
        Button { model.navigate(key) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if key == "songs" { Text("\(model.tracks.count)").font(.caption).opacity(0.65) }
            }.padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(model.section == key ? Color.blue : Color.primary.opacity(0.8))
            .background(model.section == key ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if model.albumFilter != nil || model.artistFilter != nil { Button { model.albumFilter = nil; model.artistFilter = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.system(size: 30, weight: .bold))
                    Text(model.tracks.isEmpty ? "让每一种好声音，都有归处。" : "你的音乐，随心聆听。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.pickFiles() } label: { Label("导入音乐", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.importing)
                Menu {
                    Button(model.selectedPlaylistID == nil ? "清空资料库并重新导入…" : "清空当前列表并重新导入…") { model.clearAndReimport() }
                        .disabled(model.importing)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22).help("资料库管理")
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索歌曲、艺人或专辑", text: $model.search).textFieldStyle(.plain); if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) } }
                    .padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 330)
                Spacer()
                Button { if let first = model.visibleTracks.first { model.play(first, within: model.visibleTracks) } } label: { Label("播放全部", systemImage: "play.fill") }.disabled(model.visibleTracks.isEmpty)
                Menu {
                    Picker("排序", selection: $model.sort) { Text("默认顺序").tag("default"); Text("歌曲名称").tag("title"); Text("艺人").tag("artist"); Text("最近添加").tag("added") }
                } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).frame(width: 24).help("排序")
                Button { gridView.toggle() } label: { Image(systemName: gridView ? "list.bullet" : "square.grid.2x2") }.buttonStyle(.plain).help("切换列表与封面视图")
            }
        }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
    }
    private var importBanner: some View {
        HStack { ProgressView().controlSize(.small); Text(model.importProgress).font(.caption).lineLimit(1); Spacer(); Button("取消") { model.cancelImport() } }.padding(.horizontal, 28).padding(.vertical, 10).background(.blue.opacity(0.06))
    }
    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: model.search.isEmpty ? "waveform.circle" : "magnifyingglass").font(.system(size: 66, weight: .ultraLight)).foregroundStyle(.blue.opacity(0.75))
            Text(model.search.isEmpty ? (model.selectedPlaylistID != nil ? "为这个列表添一点音乐" : "从一首喜欢的音乐开始") : "没有找到匹配的音乐").font(.title2.weight(.semibold))
            Text(model.search.isEmpty ? "拖入音乐文件或文件夹，也可以从 WALKMAN 导入。\nMP3、FLAC、DSF、DFF 等多种格式，随心播放。" : "试试其他歌曲名称、艺人或专辑。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            if model.search.isEmpty { Button("导入音乐…") { model.pickFiles() }.buttonStyle(.borderedProminent).controlSize(.large) }
            Spacer(); Spacer().frame(height: 15)
        }.frame(maxWidth: .infinity)
    }
    private var songList: some View {
        VStack(spacing: 0) {
            HStack { Text("歌曲").frame(maxWidth: .infinity, alignment: .leading); Text("专辑").frame(width: 140, alignment: .leading); Text("格式").frame(width: 65); Text("时长").frame(width: 45) }
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 76).padding(.trailing, 28).padding(.vertical, 10)
            Divider().padding(.horizontal, 28)
            List(selection: $selection) {
                ForEach(model.visibleTracks) { track in
                    songRow(track).tag(track.id)
                        .contextMenu { trackMenu(track) }
                        .onTapGesture(count: 2) { model.play(track, within: model.visibleTracks) }
                        .onDrag { draggedTrack = track.id; return NSItemProvider(object: track.id.uuidString as NSString) }
                        .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                            guard let draggedTrack, let id = model.selectedPlaylistID, model.search.isEmpty, model.sort == "default", let list = model.playlists.first(where: { $0.id == id }), let from = list.trackIDs.firstIndex(of: draggedTrack), let to = list.trackIDs.firstIndex(of: track.id) else { return false }
                            model.movePlaylist(IndexSet(integer: from), from < to ? to + 1 : to); self.draggedTrack = nil; return true
                        }
                }.onMove { model.movePlaylist($0, $1) }.moveDisabled(model.selectedPlaylistID == nil || !model.search.isEmpty || model.sort != "default")
            }.listStyle(.inset).scrollContentBackground(.hidden)
        }
    }
    private func songRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) { Artwork(track: track, size: 40); if model.currentID == track.id { Image(systemName: model.playing ? "waveform" : "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).padding(4).background(.blue, in: Circle()).offset(x: 4, y: 3) } }
            VStack(alignment: .leading, spacing: 4) { Text(track.title).font(.system(size: 13, weight: .medium)).foregroundStyle(model.currentID == track.id ? Color.blue : Color.primary).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
            Button { model.favorite(track.id) } label: { Image(systemName: track.favorite ? "heart.fill" : "heart").foregroundStyle(track.favorite ? Color.blue : Color.secondary.opacity(0.5)) }.buttonStyle(.plain).help(track.favorite ? "取消收藏" : "收藏")
            Text(track.album).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 140, alignment: .leading)
            Text(track.fileFormat).font(.system(size: 9, weight: .semibold)).foregroundStyle(track.isHighRes ? Color.blue : Color.secondary).padding(.horizontal, 5).padding(.vertical, 3).background((track.isHighRes ? Color.blue : Color.gray).opacity(0.08), in: RoundedRectangle(cornerRadius: 4)).frame(width: 65)
            Text(timeLabel(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
    @ViewBuilder private func trackMenu(_ track: Track) -> some View {
        let ids = selection.contains(track.id) ? model.visibleTracks.filter { selection.contains($0.id) }.map(\.id) : [track.id]
        Button("播放") { model.play(track, within: model.visibleTracks) }
        Button("下一首播放") { model.playNext(track) }
        Button(track.favorite ? "取消收藏" : "收藏") { model.favorite(track.id) }
        Menu("添加到播放列表") {
            if model.playlists.isEmpty { Button("先在侧边栏创建播放列表") {}.disabled(true) }
            ForEach(model.playlists) { list in Button(list.name) { model.add(ids, to: list.id) } }
        }
        if let list = model.selectedPlaylistID { Button("从此播放列表移除", role: .destructive) { model.removeFromPlaylist(ids, list) } }
        Divider()
        Button("显示文件位置") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }
        Button("音频信息") { if model.currentID == track.id { model.panel = "info" } else { model.error = "\(track.title)\n\(track.artist) · \(track.album)\n\(track.quality)\n\(track.channels) 声道 · \(timeLabel(track.duration))\n\(track.path)" } }
        Button("从资料库移除（保留文件）", role: .destructive) { model.removeFromLibrary(Set(ids)) }
    }
    private var songGrid: some View {
        ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210))], alignment: .leading, spacing: 26) {
            ForEach(model.visibleTracks) { track in
                VStack(alignment: .leading, spacing: 8) { Artwork(track: track, size: 146, onlinePreview: true); Text(track.title).font(.callout.weight(.medium)).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    .contentShape(Rectangle()).onTapGesture(count: 2) { model.play(track, within: model.visibleTracks) }.contextMenu { trackMenu(track) }
            }
        }.padding(28) }
    }
    private func collectionGrid(artist: Bool) -> some View {
        let groups = Dictionary(grouping: model.visibleTracks, by: { artist ? $0.artist : $0.albumIdentity })
        return ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210))], alignment: .leading, spacing: 26) {
            ForEach(groups.keys.sorted(), id: \.self) { key in
                Button { if artist { model.artistFilter = key } else { model.albumFilter = key } } label: {
                    VStack(alignment: .leading, spacing: 8) { Artwork(track: groups[key]?.first, size: 146, onlinePreview: true); Text(artist ? key : groups[key]?.first?.album ?? "未知专辑").font(.callout.weight(.medium)).lineLimit(1); Text("\(groups[key]?.count ?? 0) 首歌曲").font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
        }.padding(28) }
    }
    private var footer: some View {
        HStack {
            Text("\(model.visibleTracks.count) 首歌曲 · \(timeLabel(model.visibleTracks.reduce(0) { $0 + $1.duration }))")
            Spacer()
            if model.selectedPlaylistID != nil { Text("拖动歌曲调整顺序 · 右键管理歌曲") }
            else { Text("本地播放 · 多格式解码") }
        }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 28).padding(.vertical, 12)
    }
    private var playlistEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(editingPlaylist == nil ? "创建播放列表" : "重命名播放列表", systemImage: "music.note.list").font(.title2.weight(.semibold))
            TextField("播放列表名称", text: $playlistName).textFieldStyle(.roundedBorder).onSubmit { savePlaylist() }
            HStack { Spacer(); Button("取消", role: .cancel) { showPlaylistEditor = false }; Button(editingPlaylist == nil ? "创建" : "保存") { savePlaylist() }.buttonStyle(.borderedProminent).disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 360)
    }
    private func savePlaylist() {
        guard !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let editingPlaylist { model.renamePlaylist(editingPlaylist, playlistName) } else { model.createPlaylist(playlistName) }
        showPlaylistEditor = false
    }
}
