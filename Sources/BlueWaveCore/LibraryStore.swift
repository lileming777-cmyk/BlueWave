import Foundation

public final class LibraryStore {
    public private(set) var tracks: [Track] = []
    public private(set) var playlists: [Playlist] = []
    public private(set) var loadError: String?
    public let url: URL
    private struct State: Codable { var version = 1; var tracks: [Track]; var playlists: [Playlist] }
    public init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            guard Set(state.tracks.map(\.id)).count == state.tracks.count,
                  Set(state.tracks.map(\.path)).count == state.tracks.count,
                  Set(state.playlists.map(\.id)).count == state.playlists.count else { throw CocoaError(.fileReadCorruptFile) }
            tracks = state.tracks.map { track in
                var result = track
                if (result.codec.hasPrefix("dsd") || result.codec == "dst"), result.bitDepth != 1 { result.sampleRate *= 8; result.bitDepth = 1 }
                return result
            }; playlists = state.playlists
        } catch { loadError = "曲库文件无法读取，已保留原文件：\(url.path)" }
    }
    public func add(_ items: [Track]) {
        var known = Set(tracks.map(\.path))
        for item in items where known.insert(item.path).inserted { tracks.append(item) }
    }
    @discardableResult public func createPlaylist(name: String) -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: clean.isEmpty ? "新建播放列表" : clean)
        playlists.append(playlist); return playlist.id
    }
    public func renamePlaylist(_ id: UUID, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = clean
    }
    public func deletePlaylist(_ id: UUID) { playlists.removeAll { $0.id == id } }
    public func clearPlaylist(_ id: UUID) { if let i = playlists.firstIndex(where: { $0.id == id }) { playlists[i].trackIDs = [] } }
    public func clearLibrary() { tracks = []; for i in playlists.indices { playlists[i].trackIDs = [] } }
    public func addTracks(_ ids: [UUID], to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let valid = Set(tracks.map(\.id)); var known = Set(playlists[i].trackIDs)
        playlists[i].trackIDs += ids.filter { valid.contains($0) && known.insert($0).inserted }
    }
    public func removeTracks(_ ids: [UUID], from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let removal = Set(ids); playlists[i].trackIDs.removeAll { removal.contains($0) }
    }
    public func moveTracks(in id: UUID, from offsets: IndexSet, to destination: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].trackIDs = Self.moving(playlists[i].trackIDs, from: offsets, to: destination)
    }
    public static func moving<T>(_ array: [T], from offsets: IndexSet, to destination: Int) -> [T] {
        let indices = offsets.filter { array.indices.contains($0) }
        let moving = indices.map { array[$0] }
        var result = array.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        let insertion = max(0, min(result.count, destination - indices.filter { $0 < destination }.count))
        result.insert(contentsOf: moving, at: insertion); return result
    }
    public func toggleFavorite(_ id: UUID) { if let i = tracks.firstIndex(where: { $0.id == id }) { tracks[i].favorite.toggle() } }
    public func markPlayed(_ id: UUID) { if let i = tracks.firstIndex(where: { $0.id == id }) { tracks[i].playedAt = Date() } }
    public func updateMetadata(_ metadata: Track, for id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        var updated = metadata; updated.id = id; updated.favorite = tracks[i].favorite; updated.addedAt = tracks[i].addedAt; updated.playedAt = tracks[i].playedAt
        tracks[i] = updated
    }
    public func remove(_ ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
    }
    public func save() throws {
        guard loadError == nil else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(State(tracks: tracks, playlists: playlists)).write(to: url, options: .atomic)
    }
}
