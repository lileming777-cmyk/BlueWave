import XCTest
@testable import BlueWaveCore

final class CoreTests: XCTestCase {
    func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json") }
    func testDuplicateImportPreservesPlaylistReferenceAndFavorite() throws {
        let store = LibraryStore(url: location())
        let a = Track(path: "/tmp/歌曲 $test.wav", title: "Original")
        store.add([a]); store.toggleFavorite(a.id)
        let list = store.createPlaylist(name: "  蓝色时刻  ")
        store.addTracks([a.id, a.id], to: list)
        store.add([Track(path: a.path, title: "Updated")])
        XCTAssertEqual(store.tracks.count, 1)
        XCTAssertEqual(store.tracks.first?.id, a.id)
        XCTAssertEqual(store.playlists.first?.trackIDs, [a.id])
        XCTAssertTrue(store.tracks.first?.favorite == true)
        XCTAssertEqual(store.playlists.first?.name, "蓝色时刻")
    }
    func testPlaylistCRUDReorderAndPersistence() throws {
        let url = location(); let store = LibraryStore(url: url)
        let tracks = [Track(path: "/a.wav"), Track(path: "/b.wav"), Track(path: "/c.wav")]
        store.add(tracks)
        let id = store.createPlaylist(name: "Morning")
        store.addTracks(tracks.map(\.id), to: id)
        store.moveTracks(in: id, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(store.playlists[0].trackIDs, [tracks[1].id, tracks[2].id, tracks[0].id])
        store.renamePlaylist(id, name: "Evening")
        store.removeTracks([tracks[2].id], from: id)
        try store.save()
        let loaded = LibraryStore(url: url)
        XCTAssertEqual(loaded.playlists.first?.name, "Evening")
        XCTAssertEqual(loaded.playlists.first?.trackIDs, [tracks[1].id, tracks[0].id])
        loaded.deletePlaylist(id)
        XCTAssertTrue(loaded.playlists.isEmpty)
        XCTAssertEqual(loaded.tracks.count, 3)
    }
    func testCorruptStateCannotBeSilentlyOverwritten() throws {
        let url = location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("broken-json".utf8); try original.write(to: url)
        let store = LibraryStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.save())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testUnavailableFilesRemainAfterReload() throws {
        let url = location(); let store = LibraryStore(url: url)
        store.add([Track(path: "/Volumes/absent/music.dsf")]); try store.save()
        XCTAssertEqual(LibraryStore(url: url).tracks.first?.path, "/Volumes/absent/music.dsf")
    }
    func testDuplicateSavedIdentitiesAreRejectedWithoutOverwrite() throws {
        let url = location(); let store = LibraryStore(url: url)
        store.add([Track(path: "/a.wav")]); try store.save()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let tracks = json["tracks"] as! [[String: Any]]
        json["tracks"] = [tracks[0], tracks[0]]
        let damaged = try JSONSerialization.data(withJSONObject: json); try damaged.write(to: url)
        let loaded = LibraryStore(url: url)
        XCTAssertNotNil(loaded.loadError)
        XCTAssertTrue(loaded.tracks.isEmpty)
        XCTAssertThrowsError(try loaded.save())
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }
    func testOfflineLyricFallbackAndPlainText() {
        let result = ResolvedLyrics.resolve(sidecarText: "", embedded: "[00:02.00]内嵌歌词")
        XCTAssertEqual(result.lines.first?.text, "内嵌歌词")
        XCTAssertEqual(result.source, "内嵌歌词")
        let local = ResolvedLyrics.resolve(sidecarText: "[00:01.00]本地歌词", embedded: "[00:02.00]内嵌歌词")
        XCTAssertEqual(local.lines.first?.time, 1)
        let plain = ResolvedLyrics.resolve(sidecarText: nil, embedded: "第一句\n第二句")
        XCTAssertTrue(plain.lines.isEmpty)
        XCTAssertEqual(plain.plainText, "第一句\n第二句")
    }
    func testLyricsMultipleTimestampsOffsetAndBoundaries() {
        let lyrics = Lyrics.parse("[offset:500]\n[00:01.20][00:03.00]你好\n[00:02.00]蓝色\n[bad]skip")
        XCTAssertEqual(lyrics.map(\.time), [1.7, 2.5, 3.5])
        XCTAssertEqual(lyrics.map(\.text), ["你好", "蓝色", "你好"])
        XCTAssertNil(lyrics.activeIndex(at: 1))
        XCTAssertEqual(lyrics.activeIndex(at: 2.5), 1)
        XCTAssertEqual(lyrics.activeIndex(at: 100), 2)
    }
    func testTransitionGainsHaveNoGainBoostAndClampBoundaries() {
        for progress in [-1.0, 0, 0.25, 0.5, 0.75, 1, 2] {
            let gains = TransitionGains.at(progress: progress, volume: 0.8)
            XCTAssertEqual(gains.incoming + gains.outgoing, 0.8, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(gains.incoming, 0); XCTAssertGreaterThanOrEqual(gains.outgoing, 0)
        }
        XCTAssertEqual(TransitionGains.at(progress: 0, volume: 1).incoming, 0)
        XCTAssertEqual(TransitionGains.at(progress: 1, volume: 1).outgoing, 0)
    }
    func testAlbumInferenceAndCoverLookup() throws {
        let folder = location().deletingLastPathComponent().appendingPathComponent("蓝色专辑")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("歌手 - 一首歌.flac")
        let inferred = MetadataInference.resolve(url: file, tags: [:])
        XCTAssertEqual(inferred.album, "蓝色专辑")
        XCTAssertEqual(inferred.artist, "歌手")
        XCTAssertEqual(inferred.title, "一首歌")
        let tagged = MetadataInference.resolve(url: file, tags: ["album":"原始专辑", "artist":"原始艺人", "title":"原始标题"])
        XCTAssertEqual(tagged.album, "原始专辑")
        let cover = folder.appendingPathComponent("封面.jpg"); try Data([1]).write(to: cover)
        XCTAssertEqual(ArtworkLocator.find(for: file)?.resolvingSymlinksInPath(), cover.resolvingSymlinksInPath())
    }
    func testClearListAndLibraryKeepSourceFiles() throws {
        let url = location(); let store = LibraryStore(url: url)
        let file = url.deletingLastPathComponent().appendingPathComponent("song.wav")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        let track = Track(path: file.path); store.add([track])
        let list = store.createPlaylist(name: "Playlist"); store.addTracks([track.id], to: list)
        store.clearPlaylist(list)
        XCTAssertTrue(store.playlists[0].trackIDs.isEmpty); XCTAssertEqual(store.tracks.count, 1)
        store.clearLibrary(); try store.save()
        XCTAssertTrue(LibraryStore(url: url).tracks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }
    func testUnrelatedCueAndNumericTrackPrefixAreNotArtists() throws {
        let folder = location().deletingLastPathComponent().appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "TITLE \"Wrong album\"\nPERFORMER \"Wrong artist\"\nFILE \"unrelated.flac\" WAVE\nTRACK 01 AUDIO".write(to: folder.appendingPathComponent("wrong.cue"), atomically: true, encoding: .utf8)
        let result = MetadataInference.resolve(url: folder.appendingPathComponent("01 - Singer - Song.flac"), tags: [:])
        XCTAssertEqual(result.album, "Album"); XCTAssertEqual(result.artist, "Singer"); XCTAssertEqual(result.title, "Song")
        let numbered = MetadataInference.resolve(url: folder.appendingPathComponent("01 - Song.flac"), tags: [:])
        XCTAssertEqual(numbered.artist, "未知艺人"); XCTAssertEqual(numbered.title, "Song")
        try "TITLE \"Right album\"\nPERFORMER \"Right artist\"\nFILE \"song.flac\" WAVE\nTRACK 01 AUDIO".write(to: folder.appendingPathComponent("right.cue"), atomically: true, encoding: .utf8)
        let matching = MetadataInference.resolve(url: folder.appendingPathComponent("song.flac"), tags: [:])
        XCTAssertEqual(matching.album, "Right album"); XCTAssertEqual(matching.artist, "Right artist")
    }
    func testCoverFixReadsNumberedTitleThenSingerFilenames() {
        let folder = URL(fileURLWithPath: "/tmp/音源")
        for name in ["01 趁早 -孙露.wav", "02 爱的代价 -邓杰.wav"] {
            let result = MetadataInference.resolve(url: folder.appendingPathComponent(name), tags: [:])
            XCTAssertEqual(result.artist, name.contains("孙露") ? "孙露" : "邓杰")
            XCTAssertEqual(result.title, name.contains("趁早") ? "趁早" : "爱的代价")
        }
        let standard = MetadataInference.resolve(url: folder.appendingPathComponent("01 Singer - Song.wav"), tags: [:])
        XCTAssertEqual(standard.artist, "Singer"); XCTAssertEqual(standard.title, "Song")
        let tagged = MetadataInference.resolve(url: folder.appendingPathComponent("01 趁早 -孙露.wav"), tags: ["title":"Tag Title", "artist":"Tag Artist"])
        XCTAssertEqual(tagged.title, "Tag Title"); XCTAssertEqual(tagged.artist, "Tag Artist")
    }

}
