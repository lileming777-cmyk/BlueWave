import SwiftUI
import AppKit
import MediaPlayer
import BlueWaveCore

@MainActor final class PlayerModel: ObservableObject {
    @Published var tracks: [Track] = [] { didSet { rebuildArtworkAlbumIndex() } }
    @Published var playlists: [Playlist] = []
    @Published var section = "songs"
    @Published var search = ""
    @Published var sort = "default"
    @Published var currentID: UUID?
    @Published var queue: [UUID] = []
    @Published var playing = false
    @Published var position = 0.0
    @Published var volume = 0.7 { didSet { if !transitioning { audio.volume = Float(volume) }; if savesPreferences { UserDefaults.standard.set(volume, forKey: "volume") } } }
    @Published var shuffle = false
    @Published var repeatMode = 0
    @Published var panel: String? = nil
    @Published var error: String?
    @Published var importing = false
    @Published var importProgress = ""
    @Published var lyrics: [LyricLine] = []
    @Published var plainLyrics = ""
    @Published var lyricsSource = ""
    @Published var normalizeVolume = false { didSet { if savesPreferences { UserDefaults.standard.set(normalizeVolume, forKey: "normalizeVolume") } } }
    @Published var crossfadeEnabled = false { didSet { if savesPreferences { UserDefaults.standard.set(crossfadeEnabled, forKey: "crossfadeEnabled") } } }
    @Published var crossfadeDuration = 3.0 { didSet { if savesPreferences { UserDefaults.standard.set(crossfadeDuration, forKey: "crossfadeDuration") } } }
    @Published var transitioning = false
    @Published var outputRate = 0 { didSet { if savesPreferences { UserDefaults.standard.set(outputRate, forKey: "outputRate") } } }
    @Published var outputPrecision = 32 { didSet { if savesPreferences { UserDefaults.standard.set(outputPrecision, forKey: "outputPrecision") } } }
    @Published var covers: [UUID: URL] = [:]
    @Published var autoDownloadCovers = true {
        didSet {
            if savesPreferences { UserDefaults.standard.set(autoDownloadCovers, forKey: "autoDownloadCovers") }
            if !autoDownloadCovers {
                cancelOnlineCover(includingPreviews: true)
                for track in tracks where localCoversFinished.contains(track.id) && (currentID == track.id || coverPreviews.contains(track.id)) { requestAlbumArtwork(for: track) }
            }
            else {
                if let current { coverAttempts[current.id] = nil; requestCover(current) }
                for id in coverPreviews { if let track = tracks.first(where: { $0.id == id }) { coverAttempts[id] = nil; requestCover(track, preview: true) } }
            }
        }
    }
    @Published var albumFilter: String?
    @Published var artistFilter: String?
    @Published var importFailures: [String] = []
    let store: LibraryStore
    let tools: MediaTools
    var audio = AudioPlayback()
    let dataDirectory: URL
    private var importTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var fadingAudio: AudioPlayback?
    private var failedFadeID: UUID?
    private let savesPreferences: Bool
    private var pendingImportURLs: [URL] = []
    private var pendingImportTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastSessionSave = Date.distantPast
    private struct PlaybackSession: Codable {
        var currentID: UUID?
        var position: Double
        var queue: [UUID]
    }
    private var sessionURL: URL { dataDirectory.appendingPathComponent("playback-session.json") }
    private var coverRequests = Set<UUID>()
    private var localCoversFinished = Set<UUID>()
    private var onlineCoverTasks: [UUID: Task<Void, Never>] = [:]
    private var onlineCoverTokens: [UUID: UUID] = [:]
    private var coverPreviewOwners: [UUID: UUID] = [:]
    private var coverPreviews: Set<UUID> { Set(coverPreviewOwners.values) }
    @Published var coverAttributions: [UUID: CoverArtAttribution] = [:]
    @Published var coverStatus: [UUID: String] = [:]
    private var coverAttempts: [UUID: Date] = [:]
    private var artworkAlbumIndex: [String: [Track]] = [:]
    @Published private var albumCoverSources: [String: (id: UUID, url: URL)] = [:]
    private var albumCoverScanned: [String: Set<UUID>] = [:]
    private var albumCoverPending = Set<String>()
    private var albumCoverQueue: [(key: String, candidates: [Track])] = []
    private var albumCoverTask: Task<Void, Never>?
    private let coverFetcher: (Track, URL) async -> URL?
    private var mediaTargets: [(MPRemoteCommand, Any)] = []
    var current: Track? { tracks.first { $0.id == currentID } }
    var selectedPlaylistID: UUID? { UUID(uuidString: section) }
    var title: String {
        if let albumFilter { return tracks.first(where: { $0.albumIdentity == albumFilter })?.album ?? "专辑" }
        if let artistFilter { return artistFilter }
        return ["songs":"歌曲", "albums":"专辑", "artists":"艺人", "favorites":"我的收藏", "recent":"最近播放"][section] ?? playlists.first(where: { $0.id == selectedPlaylistID })?.name ?? "音乐资料库"
    }
    var visibleTracks: [Track] {
        var result = tracks
        if section == "favorites" { result = result.filter(\.favorite) }
        if section == "recent" { result = result.filter { $0.playedAt != nil }.sorted { ($0.playedAt ?? .distantPast) > ($1.playedAt ?? .distantPast) } }
        if let id = selectedPlaylistID, let list = playlists.first(where: { $0.id == id }) {
            let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            result = list.trackIDs.compactMap { byID[$0] }
        }
        if let albumFilter { result = result.filter { $0.albumIdentity == albumFilter } }
        if let artistFilter { result = result.filter { $0.artist == artistFilter } }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { result = result.filter { "\($0.title) \($0.artist) \($0.album) \($0.fileFormat)".localizedCaseInsensitiveContains(query) } }
        switch sort {
        case "title": result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "artist": result.sort { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case "added": result.sort { $0.addedAt > $1.addedAt }
        default: break
        }
        return result
    }
    init(storeURL: URL? = nil, toolsDirectory: URL? = nil, enableMediaCommands: Bool = true, coverFetcher: ((Track, URL) async -> URL?)? = nil) {
        let coverClient = CoverArtClient()
        self.coverFetcher = coverFetcher ?? { track, directory in await coverClient.fetch(for: track, cacheDirectory: directory) }
        savesPreferences = enableMediaCommands
        dataDirectory = storeURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("BlueWave", isDirectory: true)
        store = LibraryStore(url: storeURL ?? dataDirectory.appendingPathComponent("library.json"))
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tools")
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor")
        tools = MediaTools(directory: toolsDirectory ?? bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("ffmpeg").path) ? $0 : nil } ?? dev)
        refresh(); error = store.loadError
        if UserDefaults.standard.object(forKey: "volume") != nil { volume = UserDefaults.standard.double(forKey: "volume") }
        if enableMediaCommands {
            if UserDefaults.standard.object(forKey: "autoDownloadCovers") != nil { autoDownloadCovers = UserDefaults.standard.bool(forKey: "autoDownloadCovers") }
            normalizeVolume = UserDefaults.standard.bool(forKey: "normalizeVolume")
            crossfadeEnabled = UserDefaults.standard.bool(forKey: "crossfadeEnabled")
            outputRate = UserDefaults.standard.integer(forKey: "outputRate")
            let storedPrecision = UserDefaults.standard.integer(forKey: "outputPrecision"); outputPrecision = [16, 24, 32].contains(storedPrecision) ? storedPrecision : 32
            if UserDefaults.standard.object(forKey: "crossfadeDuration") != nil { crossfadeDuration = max(1, min(8, UserDefaults.standard.double(forKey: "crossfadeDuration"))) }
        }
        if !enableMediaCommands { autoDownloadCovers = false }
        audio.volume = Float(volume)
        audio.onFinish = { [weak self] in self?.advance(automatic: true) }
        audio.onError = { [weak self] message in self?.cancelOnlineCover(); self?.playing = false; self?.error = message; self?.updateNowPlaying() }
        restoreSession()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.playing else { return }; self.position = min(self.current?.duration ?? .greatestFiniteMagnitude, self.audio.position); self.checkCrossfade(); self.updateNowPlaying()
            if Date().timeIntervalSince(self.lastSessionSave) >= 5 { self.saveSession() }
        } }
        if enableMediaCommands { installMediaCommands() }
    }
    func refresh() { tracks = store.tracks; playlists = store.playlists }
    func persist() { do { try store.save(); refresh(); saveSession() } catch { self.error = "保存曲库失败：\(error.localizedDescription)"; refresh() } }
    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(PlaybackSession.self, from: data),
              let track = tracks.first(where: { $0.id == session.currentID }) else { return }
        currentID = track.id
        position = session.position.isFinite ? max(0, min(session.position, max(0, track.duration))) : 0
        let valid = Set(tracks.map(\.id)); var seen = Set<UUID>()
        queue = session.queue.filter { valid.contains($0) && seen.insert($0).inserted }
        if !queue.contains(track.id) { queue.insert(track.id, at: 0) }
        loadLyrics(track); requestCover(track); updateNowPlaying()
    }
    private func saveSession() {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let session = PlaybackSession(currentID: currentID, position: position.isFinite ? max(0, position) : 0, queue: queue)
            try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
            lastSessionSave = Date()
        } catch { self.error = "保存播放位置失败：\(error.localizedDescription)" }
    }
    func prepareForTermination() {
        if playing && audio.hasSession { position = audio.position }
        saveSession()
        cancelTransition(); audio.stop(); persist()
    }
    func navigate(_ value: String) { section = value; albumFilter = nil; artistFilter = nil; search = "" }
    func pickFiles() {
        let dialog = NSOpenPanel(); dialog.title = "导入音乐"; dialog.prompt = "导入"
        dialog.canChooseDirectories = true; dialog.canChooseFiles = true; dialog.allowsMultipleSelection = true
        if dialog.runModal() == .OK { importURLs(dialog.urls) }
    }
    func enqueueImportURLs(_ urls: [URL]) {
        pendingImportURLs += urls; pendingImportTask?.cancel()
        pendingImportTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self else { return }; let urls = self.pendingImportURLs; self.pendingImportURLs = []; self.importURLs(urls)
        }
    }
    func clearAndReimport() {
        guard !importing else { error = "请先等待当前导入结束或取消导入"; return }
        let dialog = NSOpenPanel(); dialog.title = selectedPlaylistID == nil ? "清空资料库并重新导入（保留原文件）" : "清空当前播放列表并重新导入"
        dialog.prompt = "清空并导入"; dialog.canChooseDirectories = true; dialog.canChooseFiles = true; dialog.allowsMultipleSelection = true
        guard dialog.runModal() == .OK else { return }
        do {
            try store.save()
            let backup = dataDirectory.appendingPathComponent("Backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: store.url, to: backup.appendingPathComponent("library-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"))
        } catch { self.error = "原资料库未能备份，未执行清空：\(error.localizedDescription)"; return }
        if let playlist = selectedPlaylistID { store.clearPlaylist(playlist) }
        else { stop(); currentID = nil; queue = []; store.clearLibrary(); navigate("songs") }
        search = ""; albumFilter = nil; artistFilter = nil; persist(); importURLs(dialog.urls)
    }
    func importWalkman() {
        let locations = ["/Volumes/WALKMAN/MUSIC", "/Volumes/Untitled/MUSIC"].map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if locations.isEmpty { error = "没有找到已连接的 WALKMAN 音乐目录，请使用「导入音乐」选择设备中的文件夹" } else { importURLs(locations) }
    }
    func importURLs(_ urls: [URL]) {
        guard !importing else { error = "正在导入音乐，请等待完成或先取消当前导入"; return }
        let destination = selectedPlaylistID; importing = true; importProgress = "正在查找音频文件…"; importFailures = []
        let tools = self.tools
        importTask = Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) {
                var seen = Set<String>(); var result: [URL] = []
                for url in urls {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                    if isDirectory.boolValue {
                        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                        while let file = enumerator?.nextObject() as? URL {
                            if MusicFiles.isAudio(file), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, seen.insert(file.standardizedFileURL.path).inserted { result.append(file) }
                        }
                    } else if MusicFiles.isAudio(url), seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
                }
                return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }.value
            guard let self else { return }
            var imported: [UUID] = []; var batch: [Track] = []; let existing = Dictionary(uniqueKeysWithValues: self.tracks.map { ($0.path, $0.id) })
            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                self.importProgress = "\(index + 1) / \(files.count) · \(file.lastPathComponent)"
                if let known = existing[file.standardizedFileURL.path] { imported.append(known); continue }
                let result = await Task.detached(priority: .utility) { Result { try tools.probe(url: file) } }.value
                if Task.isCancelled { break }
                switch result {
                case .success(let track): batch.append(track); imported.append(track.id)
                case .failure(let error): self.importFailures.append("\(file.lastPathComponent)：\(error.localizedDescription)")
                }
                if batch.count >= 20 { self.store.add(batch); self.persist(); batch = [] }
            }
            self.store.add(batch)
            if let destination { self.store.addTracks(imported, to: destination) }
            self.persist(); self.importing = false; self.importProgress = ""
            if files.isEmpty { self.error = "所选位置中没有找到支持的音频文件" }
            else if !self.importFailures.isEmpty { self.error = "已完成导入，\(self.importFailures.count) 个文件无法读取。\n" + self.importFailures.prefix(3).joined(separator: "\n") }
        }
    }
    func cancelImport() { importTask?.cancel(); importProgress = "正在取消，等待当前文件读取结束…" }
    func createPlaylist(_ name: String) { let id = store.createPlaylist(name: name); persist(); navigate(id.uuidString) }
    func renamePlaylist(_ id: UUID, _ name: String) { store.renamePlaylist(id, name: name); persist() }
    func deletePlaylist(_ id: UUID) { store.deletePlaylist(id); if selectedPlaylistID == id { navigate("songs") }; persist() }
    func add(_ ids: [UUID], to playlist: UUID) { store.addTracks(ids, to: playlist); persist() }
    func removeFromPlaylist(_ ids: [UUID], _ playlist: UUID) { store.removeTracks(ids, from: playlist); persist() }
    func movePlaylist(_ offsets: IndexSet, _ destination: Int) { guard let id = selectedPlaylistID, search.isEmpty, sort == "default" else { return }; store.moveTracks(in: id, from: offsets, to: destination); persist() }
    func favorite(_ id: UUID) { store.toggleFavorite(id); persist() }
    func removeFromLibrary(_ ids: Set<UUID>) {
        if let currentID, ids.contains(currentID) { stop(); self.currentID = nil }
        queue.removeAll { ids.contains($0) }; store.remove(ids); persist()
    }
    func play(_ track: Track, within context: [Track]? = nil) {
        cancelTransition(); cancelOnlineCover(); lyrics = []; plainLyrics = ""; lyricsSource = ""; failedFadeID = nil
        if let context { queue = context.map(\.id) }
        if !queue.contains(track.id) { queue.append(track.id) }
        currentID = track.id; position = 0
        do {
            try audio.play(track: track, offset: 0, tools: tools, normalize: normalizeVolume, outputRate: outputRate, precision: outputPrecision); playing = true
            store.markPlayed(track.id); persist(); loadLyrics(track); requestCover(track); updateNowPlaying()
        } catch { playing = false; self.error = error.localizedDescription; updateNowPlaying() }
    }
    func togglePlay() {
        if current == nil { if let track = visibleTracks.first { play(track, within: visibleTracks) }; return }
        if playing { audio.pause(); fadingAudio?.pause(); playing = false }
        else if !audio.hasSession, let track = current, position > 0, position < track.duration {
            do {
                try audio.play(track: track, offset: position, tools: tools, normalize: normalizeVolume, outputRate: outputRate, precision: outputPrecision)
                playing = true; store.markPlayed(track.id); persist(); requestCover(track)
            } catch { playing = false; self.error = error.localizedDescription }
        }
        else if !audio.hasSession || position >= (current?.duration ?? 0) { if let current { play(current) } }
        else { audio.resume(); fadingAudio?.resume(); playing = true; if let current { requestCover(current) } }
        saveSession(); updateNowPlaying()
    }
    func stop() { cancelTransition(); cancelOnlineCover(); audio.stop(); position = 0; playing = false; saveSession(); updateNowPlaying() }
    func seek(_ seconds: Double) {
        guard let track = current else { return }
        cancelTransition(); failedFadeID = nil
        let wasPlaying = playing; let target = max(0, min(track.duration > 0 ? track.duration : seconds, seconds))
        do { try audio.play(track: track, offset: target, tools: tools, normalize: normalizeVolume, outputRate: outputRate, precision: outputPrecision); position = target; if !wasPlaying { audio.pause() }; saveSession(); updateNowPlaying() }
        catch { cancelOnlineCover(); playing = false; self.error = error.localizedDescription }
    }
    func advance(automatic: Bool = false) {
        guard !queue.isEmpty else { stop(); return }
        if automatic && repeatMode == 2, let current { play(current); return }
        let currentIndex = queue.firstIndex(where: { $0 == currentID }) ?? -1
        let index: Int
        if shuffle && queue.count > 1 { index = queue.indices.filter { $0 != currentIndex }.randomElement() ?? 0 }
        else if currentIndex + 1 < queue.count { index = currentIndex + 1 }
        else if repeatMode == 1 { index = 0 }
        else { cancelTransition(); cancelOnlineCover(); audio.stop(); playing = false; position = current?.duration ?? 0; updateNowPlaying(); return }
        if let track = tracks.first(where: { $0.id == queue[index] }) { play(track) }
    }
    func previous() {
        if position > 3 { seek(0); return }
        guard !queue.isEmpty else { return }
        let index = max(0, (queue.firstIndex(where: { $0 == currentID }) ?? 0) - 1)
        if let track = tracks.first(where: { $0.id == queue[index] }) { play(track) }
    }
    func playNext(_ track: Track) {
        queue.removeAll { $0 == track.id && $0 != currentID }
        let insertion = queue.firstIndex(where: { $0 == currentID }).map { $0 + 1 } ?? queue.count
        if !queue.contains(track.id) { queue.insert(track.id, at: insertion) }
    }
    func moveQueue(_ offsets: IndexSet, _ destination: Int) { queue = LibraryStore.moving(queue, from: offsets, to: destination) }
    func removeQueue(_ ids: Set<UUID>) { queue.removeAll { ids.contains($0) && $0 != currentID } }
    func loadLyrics(_ track: Track) {
        if track.lyricsChecked != true {
            let tools = self.tools
            Task { [weak self] in
                let updated = await Task.detached(priority: .utility) { try? tools.probe(url: track.url) }.value
                guard let self, self.currentID == track.id else { return }
                if let updated { self.store.updateMetadata(updated, for: track.id); self.persist(); if let refreshed = self.current { self.loadLyrics(refreshed) } }
                else { self.lyrics = []; self.plainLyrics = ""; self.lyricsSource = "" }
            }
            return
        }
        let url = track.url.deletingPathExtension().appendingPathExtension("lrc")
        let data = try? Data(contentsOf: url)
        let sidecar = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .utf16) }
        let result = ResolvedLyrics.resolve(sidecarText: sidecar, embedded: track.embeddedLyrics)
        lyrics = result.lines; plainLyrics = result.plainText; lyricsSource = result.source
    }
    func exportLyrics() {
        guard let track = current else { return }
        let text = !lyrics.isEmpty ? lyrics.map { String(format: "[%02d:%05.2f]%@", Int($0.time) / 60, $0.time.truncatingRemainder(dividingBy: 60), $0.text) }.joined(separator: "\n") : plainLyrics
        guard !text.isEmpty else { return }
        let dialog = NSSavePanel(); dialog.nameFieldStringValue = track.url.deletingPathExtension().lastPathComponent + ".lrc"
        if dialog.runModal() == .OK, let url = dialog.url { do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription } }
    }
    func cancelTransition() {
        fadeTask?.cancel(); fadeTask = nil; fadingAudio?.stop(); fadingAudio = nil; transitioning = false; audio.volume = Float(volume)
    }
    func checkCrossfade() {
        guard crossfadeEnabled, playing, !transitioning, repeatMode != 2, let track = current, failedFadeID != track.id,
              track.duration > crossfadeDuration + 0.4, position >= track.duration - crossfadeDuration,
              let currentIndex = queue.firstIndex(of: track.id) else { return }
        let nextID: UUID?
        if shuffle { nextID = queue.filter { $0 != track.id }.randomElement() }
        else if currentIndex + 1 < queue.count { nextID = queue[currentIndex + 1] }
        else { nextID = repeatMode == 1 && queue.count > 1 ? queue.first : nil }
        guard let nextID, let next = tracks.first(where: { $0.id == nextID }) else { return }
        let incoming = AudioPlayback(); incoming.volume = 0
        do { try incoming.play(track: next, offset: 0, tools: tools, normalize: normalizeVolume, outputRate: outputRate, precision: outputPrecision) }
        catch { failedFadeID = track.id; return }
        cancelOnlineCover()
        let outgoing = audio; outgoing.onFinish = nil; outgoing.onError = nil
        fadingAudio = outgoing; audio = incoming; currentID = next.id; position = 0; transitioning = true
        incoming.onFinish = { [weak self] in self?.advance(automatic: true) }
        incoming.onError = { [weak self] message in self?.cancelTransition(); self?.cancelOnlineCover(); self?.playing = false; self?.error = message }
        store.markPlayed(next.id); persist(); loadLyrics(next); requestCover(next)
        let duration = max(0.1, min(crossfadeDuration, track.duration - outgoing.position))
        fadeTask = Task { [weak self] in
            var elapsed = 0.0
            while elapsed < duration {
                guard let self, !Task.isCancelled else { return }
                if self.playing { elapsed += 0.05; let gains = TransitionGains.at(progress: elapsed / duration, volume: self.volume); outgoing.volume = gains.outgoing; incoming.volume = gains.incoming }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            outgoing.stop(); self.fadingAudio = nil; self.transitioning = false; incoming.volume = Float(self.volume)
        }
    }
    private func albumArtworkKey(for track: Track) -> String? {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let album = normalized(track.album), artist = normalized(track.artist)
        let unknown: Set<String> = ["", "unknown", "unknown album", "unknown artist", "未知专辑", "未知艺人", "未知歌手", "未知", "不详", "none", "n/a"]
        guard !unknown.contains(album), !unknown.contains(artist) else { return nil }
        // Artwork sharing follows known tags even when an album spans directories.
        // The existing album-grid grouping remains independent of this fallback key.
        return album + "\u{1f}" + artist
    }
    private func rebuildArtworkAlbumIndex() {
        var index: [String: [Track]] = [:]
        for track in tracks {
            if let key = albumArtworkKey(for: track) { index[key, default: []].append(track) }
        }
        artworkAlbumIndex = index
    }
    private func artworkSource(for track: Track) -> (id: UUID, url: URL)? {
        if let url = covers[track.id], FileManager.default.isReadableFile(atPath: url.path) { return (track.id, url) }
        guard let key = albumArtworkKey(for: track) else { return nil }
        let siblings = artworkAlbumIndex[key] ?? []
        for sibling in siblings where sibling.id != track.id {
            if let url = covers[sibling.id], FileManager.default.isReadableFile(atPath: url.path) { return (sibling.id, url) }
        }
        if let source = albumCoverSources[key], FileManager.default.isReadableFile(atPath: source.url.path), siblings.contains(where: { $0.id == source.id }) { return source }
        return nil
    }
    func artworkURL(for track: Track) -> URL? { artworkSource(for: track)?.url }
    func artworkAttribution(for track: Track) -> CoverArtAttribution? {
        guard let source = artworkSource(for: track) else { return nil }
        return coverAttributions[source.id] ?? CoverArtClient.attribution(for: source.url)
    }
    func artworkSourceStatus(for track: Track) -> String? {
        guard let source = artworkSource(for: track), source.id != track.id else { return nil }
        return "专辑封面"
    }
    private nonisolated static func localArtwork(for track: Track, tools: MediaTools, cache: URL) -> URL? {
        let target = cache.appendingPathComponent(track.id.uuidString + ".png")
        if NSImage(contentsOf: target) != nil { return target }
        if let result = try? tools.run(tool: "ffmpeg", arguments: ["-nostdin", "-v", "error", "-i", track.path, "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=360:-1", "-c:v", "png", "-f", "image2pipe", "pipe:1"], timeout: 10, limit: 8 * 1024 * 1024), NSImage(data: result.data) != nil {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            if (try? result.data.write(to: target, options: .atomic)) != nil { return target }
        }
        if let url = ArtworkLocator.find(for: track.url), NSImage(contentsOf: url) != nil { return url }
        return nil
    }
    private func requestAlbumArtwork(for track: Track) {
        guard covers[track.id] == nil, let key = albumArtworkKey(for: track), artworkURL(for: track) == nil,
              !albumCoverPending.contains(key) else { return }
        if let source = albumCoverSources[key], !FileManager.default.isReadableFile(atPath: source.url.path) {
            albumCoverSources[key] = nil; albumCoverScanned[key] = nil
        }
        let candidates = (artworkAlbumIndex[key] ?? []).filter { $0.id != track.id && !(albumCoverScanned[key] ?? []).contains($0.id) }
        guard !candidates.isEmpty else { return }
        albumCoverPending.insert(key); albumCoverQueue.append((key, candidates))
        guard albumCoverTask == nil else { return }
        // One offline worker for all requested albums; it never calls an online provider.
        let tools = self.tools, cache = dataDirectory.appendingPathComponent("Covers", isDirectory: true)
        albumCoverTask = Task { [weak self] in
            while let self, !self.albumCoverQueue.isEmpty {
                let item = self.albumCoverQueue.removeFirst()
                let found: (id: UUID, url: URL)? = await Task.detached(priority: .utility) {
                    let diskOnly = CoverArtClient(providers: [])
                    for candidate in item.candidates {
                        if let url = Self.localArtwork(for: candidate, tools: tools, cache: cache) { return (candidate.id, url) }
                        if let url = await diskOnly.fetch(for: candidate, cacheDirectory: cache.appendingPathComponent("Online", isDirectory: true)) { return (candidate.id, url) }
                    }
                    return nil
                }.value
                self.albumCoverPending.remove(item.key)
                self.albumCoverScanned[item.key, default: []].formUnion(item.candidates.map(\.id))
                if let found, self.artworkAlbumIndex[item.key]?.contains(where: { $0.id == found.id }) == true {
                    self.albumCoverSources[item.key] = found; self.updateNowPlaying()
                }
            }
            self?.albumCoverTask = nil
        }
    }
    func requestCover(_ track: Track, preview: Bool = false, owner: UUID? = nil) {
        if preview {
            let key = owner ?? track.id
            let old = coverPreviewOwners.updateValue(track.id, forKey: key)
            if let old, old != track.id, !coverPreviews.contains(old), currentID != old || !playing { cancelOnlineCover(for: old) }
        }
        if let existing = covers[track.id] {
            if FileManager.default.isReadableFile(atPath: existing.path) { return }
            covers[track.id] = nil; coverAttributions[track.id] = nil
            coverRequests.remove(track.id); localCoversFinished.remove(track.id)
        }
        guard coverRequests.insert(track.id).inserted else {
            if localCoversFinished.contains(track.id) { requestOnlineCover(track) }
            return
        }
        let cache = dataDirectory.appendingPathComponent("Covers", isDirectory: true)
        let target = cache.appendingPathComponent(track.id.uuidString + ".png")
        if NSImage(contentsOf: target) != nil { covers[track.id] = target; localCoversFinished.insert(track.id); return }
        let tools = self.tools
        Task { [weak self] in
            let (updated, result): (Track, URL?) = await Task.detached(priority: .utility) {
                let updated = track.metadataRevision == MetadataInference.revision ? track : ((try? tools.probe(url: track.url)) ?? track)
                // Prefer embedded art, then conventional sibling art; never modify source files.
                if let result = Self.localArtwork(for: track, tools: tools, cache: cache) { return (updated, result) }
                let cached = await CoverArtClient(providers: []).fetch(for: updated, cacheDirectory: cache.appendingPathComponent("Online", isDirectory: true))
                return (updated, cached)
            }.value
            guard let self else { return }
            if updated.metadataRevision == MetadataInference.revision, track.metadataRevision != MetadataInference.revision {
                self.store.updateMetadata(updated, for: track.id); self.persist()
            }
            self.localCoversFinished.insert(track.id)
            if let result, NSImage(contentsOf: result) != nil { self.covers[track.id] = result; self.coverAttributions[track.id] = CoverArtClient.attribution(for: result); self.updateNowPlaying() }
            else { self.requestOnlineCover(self.tracks.first(where: { $0.id == track.id }) ?? track) }
        }
    }
    func releaseCoverPreview(owner: UUID) {
        guard let id = coverPreviewOwners.removeValue(forKey: owner) else { return }
        if !coverPreviews.contains(id), currentID != id || !playing { cancelOnlineCover(for: id) }
    }
    private func cancelOnlineCover(for id: UUID) {
        if onlineCoverTokens[id] != nil { coverAttempts[id] = nil }
        onlineCoverTasks[id]?.cancel(); onlineCoverTasks[id] = nil; onlineCoverTokens[id] = nil
        if covers[id] == nil { coverStatus[id] = nil }
    }
    func cancelOnlineCover(includingPreviews: Bool = false) {
        for id in Array(onlineCoverTokens.keys) where includingPreviews || !coverPreviews.contains(id) { cancelOnlineCover(for: id) }
    }
    func retryCover(_ track: Track) {
        cancelOnlineCover(for: track.id); coverAttempts[track.id] = nil
        coverRequests.remove(track.id); localCoversFinished.remove(track.id); covers[track.id] = nil; coverAttributions[track.id] = nil
        if let key = albumArtworkKey(for: track) { albumCoverScanned[key] = nil }
        requestCover(track)
    }
    private func requestOnlineCover(_ track: Track) {
        if !autoDownloadCovers || !((playing && currentID == track.id) || coverPreviews.contains(track.id)) { requestAlbumArtwork(for: track); return }
        guard autoDownloadCovers, (playing && currentID == track.id) || coverPreviews.contains(track.id), covers[track.id] == nil, onlineCoverTokens[track.id] == nil,
              Date().timeIntervalSince(coverAttempts[track.id] ?? .distantPast) >= 60 else { return }
        let token = UUID(); onlineCoverTokens[track.id] = token; coverAttempts[track.id] = Date()
        coverStatus[track.id] = "正在匹配封面…"
        let fetch = coverFetcher; let cache = dataDirectory.appendingPathComponent("Covers/Online", isDirectory: true)
        onlineCoverTasks[track.id] = Task { [weak self] in
            let result = await fetch(track, cache)
            guard let self, !Task.isCancelled, self.onlineCoverTokens[track.id] == token else { return }
            self.onlineCoverTokens[track.id] = nil; self.onlineCoverTasks[track.id] = nil
            guard self.autoDownloadCovers, self.currentID == track.id || self.coverPreviews.contains(track.id) else { return }
            if let result, NSImage(contentsOf: result) != nil {
                self.covers[track.id] = result; self.coverAttributions[track.id] = CoverArtClient.attribution(for: result); self.coverStatus[track.id] = "已缓存封面"; self.updateNowPlaying()
            } else {
                self.coverStatus[track.id] = track.artist == "未知艺人" ? "缺少歌手信息，无法匹配封面" : "未找到匹配封面，或网络暂不可用"
                self.requestAlbumArtwork(for: track)
            }
        }
    }
    func updateNowPlaying() {
        guard let track = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: track.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        if let url = artworkURL(for: track), let image = NSImage(contentsOf: url) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }
    private func installMediaCommands() {
        let commands = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in Task { @MainActor in action() }; return .success }
            mediaTargets.append((command, target))
        }
        bind(commands.togglePlayPauseCommand) { [weak self] in self?.togglePlay() }
        bind(commands.playCommand) { [weak self] in if self?.playing == false { self?.togglePlay() } }
        bind(commands.pauseCommand) { [weak self] in if self?.playing == true { self?.togglePlay() } }
        bind(commands.nextTrackCommand) { [weak self] in self?.advance() }
        bind(commands.previousTrackCommand) { [weak self] in self?.previous() }
        let target = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        mediaTargets.append((commands.changePlaybackPositionCommand, target))
    }
}
