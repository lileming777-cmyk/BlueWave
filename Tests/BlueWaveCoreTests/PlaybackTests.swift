import XCTest
import CryptoKit
@testable import BlueWave
import BlueWaveCore

final class PlaybackTests: XCTestCase {
    private let albumPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    @MainActor func testAlbumArtworkOwnOnlineDiskCacheWinsWithDownloadsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = Track(path: root.appendingPathComponent("songs/a.wav").path, title: "Song", artist: "Singer", album: "Album")
        let sibling = Track(path: root.appendingPathComponent("songs/b.wav").path, title: "Other", artist: "Singer", album: "Album")
        let cache = root.appendingPathComponent("Covers/Online"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data("singer\u{1f}album\u{1f}song".utf8)).map { String(format: "%02x", $0) }.joined()
        let ownImage = cache.appendingPathComponent(key + ".image"); try albumPNG.write(to: ownImage)
        let source: [String: Any] = ["artist": "Singer", "album": "Album", "title": "Song", "releaseID": "12345678-1234-1234-1234-123456789012", "sourceURL": "https://archive.org/fixture.png", "fetchedAt": 0]
        try JSONSerialization.data(withJSONObject: source).write(to: cache.appendingPathComponent(key + ".json"))
        var requests = 0
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { _, _ in requests += 1; return nil })
        model.store.add([song, sibling]); model.refresh(); model.covers[sibling.id] = root.appendingPathComponent("sibling.png")
        model.requestCover(song, preview: true)
        for _ in 0..<200 { if model.covers[song.id] != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.artworkURL(for: song), ownImage); XCTAssertEqual(model.covers[song.id], ownImage); XCTAssertEqual(requests, 0)
        XCTAssertEqual(model.artworkAttribution(for: song)?.matchedTitle, "Song"); XCTAssertNil(model.artworkSourceStatus(for: song))
        model.covers[sibling.id] = nil
        XCTAssertEqual(model.artworkURL(for: sibling), ownImage)
        XCTAssertEqual(model.artworkAttribution(for: sibling)?.matchedTitle, "Song", "Shared artwork must retain the source song's attribution, not rename it to Other")
        XCTAssertEqual(model.artworkSourceStatus(for: sibling), "专辑封面")
    }
    @MainActor func testAlbumArtworkSharesKnownAlbumAcrossDirectoriesButOwnArtworkAlwaysWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let albumImage = root.appendingPathComponent("album.png"), ownImage = root.appendingPathComponent("own.png")
        try albumPNG.write(to: albumImage); try albumPNG.write(to: ownImage)
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), enableMediaCommands: false)
        let song = Track(path: root.appendingPathComponent("songs/a.wav").path, artist: "Singer", album: "Album")
        let sibling = Track(path: root.appendingPathComponent("songs/b.wav").path, artist: "Singer", album: "Album")
        let otherSinger = Track(path: root.appendingPathComponent("songs/c.wav").path, artist: "Other", album: "Album")
        let otherFolder = Track(path: root.appendingPathComponent("elsewhere/d.wav").path, artist: " singer ", album: " ALBUM ")
        model.store.add([song, sibling, otherSinger, otherFolder]); model.refresh()
        XCTAssertNil(model.artworkURL(for: song))
        model.covers[sibling.id] = albumImage
        XCTAssertEqual(model.artworkURL(for: song), albumImage, "A later loaded album source must immediately serve its sibling")
        XCTAssertEqual(model.artworkSourceStatus(for: song), "专辑封面")
        XCTAssertNil(model.covers[song.id], "Album fallback must not masquerade as the song's own artwork")
        XCTAssertNil(model.artworkURL(for: otherSinger))
        XCTAssertEqual(model.artworkURL(for: otherFolder), albumImage, "The same known artist and album must share artwork across directories")
        model.covers[song.id] = ownImage
        XCTAssertEqual(model.artworkURL(for: song), ownImage)
        for unknown in ["", "   ", "未知专辑", "Unknown Album"] {
            var a = song, b = sibling; a.album = unknown; b.album = unknown
            model.store.clearLibrary(); model.store.add([a, b]); model.refresh(); model.covers[a.id] = nil
            XCTAssertNil(model.artworkURL(for: a), "Unknown albums must never become one shared album")
        }
    }
    @MainActor func testAlbumArtworkColdSiblingCacheWorksWithDownloadsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = Track(path: root.appendingPathComponent("songs/a.wav").path, artist: "Singer", album: "Album")
        let sibling = Track(path: root.appendingPathComponent("songs/b.wav").path, artist: "Singer", album: "Album")
        let cache = root.appendingPathComponent("Covers"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let image = cache.appendingPathComponent(sibling.id.uuidString + ".png"); try albumPNG.write(to: image)
        var requests = 0
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { _, _ in requests += 1; return nil })
        model.store.add([song, sibling]); model.refresh(); model.requestCover(song, preview: true)
        for _ in 0..<200 { if model.artworkURL(for: song) != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.artworkURL(for: song), image); XCTAssertNil(model.covers[song.id]); XCTAssertEqual(requests, 0)
    }
    @MainActor func testAlbumArtworkReprobesWhenCachedSourceDisappears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = Track(path: root.appendingPathComponent("songs/a.wav").path, artist: "Singer", album: "Album")
        let first = Track(path: root.appendingPathComponent("songs/b.wav").path, artist: "Singer", album: "Album")
        let second = Track(path: root.appendingPathComponent("songs/c.wav").path, artist: "Singer", album: "Album")
        let cache = root.appendingPathComponent("Covers"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let firstImage = cache.appendingPathComponent(first.id.uuidString + ".png"), secondImage = cache.appendingPathComponent(second.id.uuidString + ".png")
        try albumPNG.write(to: firstImage); try albumPNG.write(to: secondImage)
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false)
        model.store.add([song, first, second]); model.refresh(); model.requestCover(song, preview: true)
        for _ in 0..<200 { if model.artworkURL(for: song) != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.artworkURL(for: song), firstImage)
        try FileManager.default.removeItem(at: firstImage)
        model.requestCover(song, preview: true)
        for _ in 0..<200 { if model.artworkURL(for: song) == secondImage { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.artworkURL(for: song), secondImage, "A missing source must not permanently mask another available sibling")
        XCTAssertNil(model.covers[song.id])
    }
    @MainActor func testAlbumArtworkWaitsForOwnOnlineResultBeforeScanningSibling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let song = Track(path: root.appendingPathComponent("songs/a.wav").path, artist: "Singer", album: "Album")
        let sibling = Track(path: root.appendingPathComponent("songs/b.wav").path, artist: "Singer", album: "Album")
        try FileManager.default.createDirectory(at: sibling.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = sibling.url.deletingPathExtension().appendingPathExtension("png"); try albumPNG.write(to: image)
        try albumPNG.write(to: sibling.url.deletingLastPathComponent().appendingPathComponent("unrelated.png"))
        var pending: CheckedContinuation<URL?, Never>?; var requests: [UUID] = []
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { track, _ in requests.append(track.id); return await withCheckedContinuation { pending = $0 } })
        model.store.add([song, sibling]); model.refresh(); model.autoDownloadCovers = true; model.requestCover(song, preview: true)
        for _ in 0..<200 { if pending != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(pending); XCTAssertNil(model.artworkURL(for: song))
        pending?.resume(returning: nil); pending = nil
        for _ in 0..<200 { if model.artworkURL(for: song) != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.artworkURL(for: song)?.resolvingSymlinksInPath(), image.resolvingSymlinksInPath()); XCTAssertNil(model.covers[song.id]); XCTAssertEqual(requests, [song.id])
        model.cancelOnlineCover(includingPreviews: true)
    }
    @MainActor func testAlbumArtworkFindsEmbeddedSiblingWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = try MediaTests.fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: input) }
        let directory = root.appendingPathComponent("songs"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let embedded = directory.appendingPathComponent("b.flac")
        _ = try tools.run(tool: "ffmpeg", arguments: ["-nostdin", "-v", "error", "-i", input.path, "-c:a", "flac", embedded.path])
        // Insert a real FLAC PICTURE block; the shipped decoder intentionally has no image demuxer.
        var flac = try Data(contentsOf: embedded); var offset = 4
        while flac[offset] & 0x80 == 0 { offset += 4 + Int(flac[offset + 1]) * 65536 + Int(flac[offset + 2]) * 256 + Int(flac[offset + 3]) }
        let end = offset + 4 + Int(flac[offset + 1]) * 65536 + Int(flac[offset + 2]) * 256 + Int(flac[offset + 3])
        flac[offset] &= 0x7f
        var picture = Data()
        func u32(_ n: UInt32) { var value = n.bigEndian; withUnsafeBytes(of: &value) { picture.append(contentsOf: $0) } }
        u32(3); u32(9); picture.append(contentsOf: "image/png".utf8); u32(0)
        u32(1); u32(1); u32(16); u32(0); u32(UInt32(albumPNG.count)); picture.append(albumPNG)
        let header = Data([0x86, UInt8(picture.count >> 16 & 255), UInt8(picture.count >> 8 & 255), UInt8(picture.count & 255)])
        flac.insert(contentsOf: header + picture, at: end); try flac.write(to: embedded)
        let extracted = try tools.run(tool: "ffmpeg", arguments: ["-nostdin", "-v", "error", "-i", embedded.path, "-map", "0:v:0", "-frames:v", "1", "-c:v", "png", "-f", "image2pipe", "pipe:1"])
        XCTAssertNotNil(NSImage(data: extracted.data), "Fixture must contain decodable embedded artwork")
        let song = Track(path: directory.appendingPathComponent("a.wav").path, artist: "Singer", album: "Album")
        let sibling = Track(path: embedded.path, artist: "Singer", album: "Album")
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false)
        model.store.add([song, sibling]); model.refresh(); model.requestCover(song, preview: true)
        for _ in 0..<300 { if model.artworkURL(for: song) != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let image = try XCTUnwrap(model.artworkURL(for: song)); XCTAssertNotNil(NSImage(contentsOf: image)); XCTAssertNil(model.covers[song.id])
        XCTAssertEqual(image.lastPathComponent, sibling.id.uuidString + ".png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: embedded.path))
    }
    let tools = MediaTools(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor"))
    @MainActor func testMissingLyricsDoesNotDisplayOldAutomaticTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false)
        var track = Track(path: root.appendingPathComponent("song.wav").path, title: "Song")
        track.lyricsChecked = true
        let cache = root.appendingPathComponent("Transcripts")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let generated = cache.appendingPathComponent(track.id.uuidString + ".lrc")
        try "[00:01.00]wrong automatic words".write(to: generated, atomically: true, encoding: .utf8)
        model.store.add([track]); model.refresh(); model.currentID = track.id
        model.loadLyrics(track)
        XCTAssertTrue(model.lyrics.isEmpty)
        XCTAssertTrue(model.plainLyrics.isEmpty)
        XCTAssertTrue(model.lyricsSource.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: generated.path), "Removing automatic listening must preserve existing user cache files")
    }
    @MainActor func testCoverLookupOnlyForCurrentTrackAndSkipsLocalArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("download.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: image)
        var requests: [UUID] = []
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { track, _ in requests.append(track.id); return image })
        let first = Track(path: root.appendingPathComponent("a/one.wav").path, title: "One")
        let second = Track(path: root.appendingPathComponent("b/two.wav").path, title: "Two")
        let local = Track(path: root.appendingPathComponent("c/three.wav").path, title: "Three")
        try FileManager.default.createDirectory(at: local.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: local.url.deletingPathExtension().appendingPathExtension("png"))
        model.store.add([first, second, local]); model.refresh()
        model.autoDownloadCovers = true; model.currentID = first.id; model.playing = true
        model.requestCover(first); model.requestCover(second); model.requestCover(local)
        for _ in 0..<100 { if model.covers[first.id] != nil && model.covers[local.id] != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(requests, [first.id]); XCTAssertEqual(model.covers[first.id], image)
        XCTAssertNotNil(model.covers[local.id]); XCTAssertNil(model.covers[second.id])
        model.currentID = local.id; model.requestCover(local)
        XCTAssertEqual(requests, [first.id])
        model.stop()
    }
    @MainActor func testDisabledDownloadAndLateResultsDoNotReplaceCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var pending: CheckedContinuation<URL?, Never>?
        var count = 0
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { _, _ in count += 1; return await withCheckedContinuation { pending = $0 } })
        let track = Track(path: root.appendingPathComponent("song.wav").path, title: "Song")
        model.store.add([track]); model.refresh(); model.currentID = track.id; model.playing = true
        model.requestCover(track)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(count, 0)
        model.autoDownloadCovers = true
        for _ in 0..<100 { if pending != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(count, 1)
        model.autoDownloadCovers = false; model.currentID = nil
        pending?.resume(returning: URL(fileURLWithPath: "/tmp/no-cover.png")); pending = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(model.covers[track.id]); model.stop()
    }
    @MainActor func testStoppedCoverLookupCanRetryImmediatelyAndQueueEndCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var pending: [CheckedContinuation<URL?, Never>] = []; var cancelled: [Bool] = []
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { _, _ in
            let result: URL? = await withCheckedContinuation { pending.append($0) }
            cancelled.append(Task.isCancelled); return result
        })
        let track = Track(path: root.appendingPathComponent("song.wav").path, title: "Song")
        model.store.add([track]); model.refresh(); model.currentID = track.id; model.playing = true; model.autoDownloadCovers = true
        for _ in 0..<100 { if pending.count == 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(pending.count, 1)
        model.stop(); model.playing = true; model.requestCover(track)
        for _ in 0..<100 { if pending.count == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(pending.count, 2, "Cancellation must not leave a failure cooldown on returning to the same song")
        model.queue = [track.id]; model.advance()
        for item in pending { item.resume(returning: nil) }; pending = []
        for _ in 0..<100 { if cancelled.count == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(cancelled, [true, true]); XCTAssertFalse(model.playing)
        model.stop()
    }
    @MainActor func testCoverFixVisibleAlbumCanDownloadWithoutStartingPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var requests: [UUID] = []
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { track, _ in requests.append(track.id); return nil })
        let visible = Track(path: root.appendingPathComponent("one.wav").path, title: "One", artist: "Singer")
        let invisible = Track(path: root.appendingPathComponent("two.wav").path, title: "Two", artist: "Singer")
        model.store.add([visible, invisible]); model.refresh(); model.autoDownloadCovers = true
        model.requestCover(visible, preview: true); model.requestCover(invisible)
        for _ in 0..<100 { if !requests.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(requests, [visible.id]); XCTAssertFalse(model.playing); model.stop()
    }
    @MainActor func testCoverFixLegacyUnknownArtistIsRefreshedBeforeDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = try MediaTests.fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let song = root.appendingPathComponent("01 趁早 -孙露.wav"); try FileManager.default.copyItem(at: fixture, to: song)
        var fetched: [Track] = []
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { track, _ in fetched.append(track); return nil })
        var old = Track(path: song.path, title: "01 趁早 -孙露"); old.favorite = true; old.lyricsChecked = true
        model.store.add([old]); let list = model.store.createPlaylist(name: "Keep"); model.store.addTracks([old.id], to: list); model.refresh()
        model.currentID = old.id; model.playing = true; model.autoDownloadCovers = true; model.requestCover(old)
        for _ in 0..<100 { if !fetched.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fetched.first?.artist, "孙露"); XCTAssertEqual(fetched.first?.title, "趁早")
        XCTAssertEqual(model.current?.id, old.id); XCTAssertEqual(model.current?.favorite, true)
        XCTAssertEqual(model.playlists.first?.trackIDs, [old.id]); model.stop()
    }
    @MainActor func testCoverFixPausedCurrentSongAcceptsDownloadedImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("art.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!.write(to: image)
        var pending: CheckedContinuation<URL?, Never>?
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { _, _ in await withCheckedContinuation { pending = $0 } })
        let track = Track(path: root.appendingPathComponent("missing/song.wav").path, title: "Song")
        model.store.add([track]); model.refresh(); model.currentID = track.id; model.playing = true; model.autoDownloadCovers = true
        for _ in 0..<100 { if pending != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(pending)
        model.playing = false // Pausing keeps the current selection; stop explicitly cancels.
        pending?.resume(returning: image); pending = nil
        for _ in 0..<100 { if model.covers[track.id] != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.covers[track.id], image); model.stop()
    }
    @MainActor func testCoverFixReplacingVisibleAlbumRepresentativeCancelsOldPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var pending: [UUID: CheckedContinuation<URL?, Never>] = [:]; var cancelled: [UUID: Bool] = [:]
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false, coverFetcher: { track, _ in
            let result: URL? = await withCheckedContinuation { pending[track.id] = $0 }; cancelled[track.id] = Task.isCancelled; return result
        })
        let a = Track(path: root.appendingPathComponent("a.wav").path, title: "A"), b = Track(path: root.appendingPathComponent("b.wav").path, title: "B")
        let owner = UUID(); model.store.add([a,b]); model.refresh(); model.autoDownloadCovers = true
        model.requestCover(a, preview: true, owner: owner)
        for _ in 0..<100 { if pending[a.id] != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        model.requestCover(b, preview: true, owner: owner)
        for _ in 0..<100 { if pending[b.id] != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        pending.removeValue(forKey: a.id)?.resume(returning: nil)
        for _ in 0..<100 { if cancelled[a.id] != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(cancelled[a.id], true)
        model.autoDownloadCovers = false
        for c in pending.values { c.resume(returning: nil) }; pending = [:]; model.stop()
    }
    @MainActor func testRealOutputClockPauseSeekAndCancellation() async throws {
        let url = try MediaTests.fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let track = try tools.probe(url: url); let audio = AudioPlayback(); audio.volume = 0
        defer { audio.stop() }
        var finished = 0; var errors: [String] = []
        audio.onFinish = { finished += 1 }; audio.onError = { errors.append($0) }
        try audio.play(track: track, offset: 0, tools: tools)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertGreaterThan(audio.position, 0.05)
        audio.pause(); let paused = audio.position
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(audio.position, paused, accuracy: 0.03)
        try audio.play(track: track, offset: 0.5, tools: tools)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertGreaterThan(audio.position, 0.55)
        for _ in 0..<6 { try audio.play(track: track, offset: 0, tools: tools); audio.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(finished, 0)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    }
    @MainActor func testNaturalCompletionOccursAfterPlayback() async throws {
        let url = try MediaTests.fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let track = try tools.probe(url: url); let audio = AudioPlayback(); audio.volume = 0
        defer { audio.stop() }
        var finished = false; audio.onFinish = { finished = true }
        try audio.play(track: track, offset: 0.7, tools: tools)
        try await Task.sleep(nanoseconds: 100_000_000); XCTAssertFalse(finished)
        try await Task.sleep(nanoseconds: 600_000_000); XCTAssertTrue(finished)
    }
    @MainActor func testPlayRetriesAfterMissingFileDuringSeek() async throws {
        let url = try MediaTests.fixture(); let contents = try Data(contentsOf: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PlayerModel(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false)
        let track = try tools.probe(url: url); model.store.add([track]); model.refresh(); model.volume = 0
        defer { model.stop() }
        model.play(track)
        try await Task.sleep(nanoseconds: 400_000_000)
        try FileManager.default.removeItem(at: url); model.seek(0.6)
        XCTAssertFalse(model.playing)
        try contents.write(to: url); model.togglePlay()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.playing)
        XCTAssertGreaterThan(model.audio.position, 0.05)
    }
    @MainActor func testMultipleDroppedURLsAreCollectedBeforeImport() async {
        let urls = [URL(fileURLWithPath: "/tmp/第一首.wav"), URL(fileURLWithPath: "/tmp/第二首.flac")]
        let providers = urls.map { NSItemProvider(object: $0 as NSURL) }
        let result = await withCheckedContinuation { continuation in DropLoader.load(providers) { continuation.resume(returning: $0) } }
        XCTAssertEqual(Set(result), Set(urls))
    }
    @MainActor func testCrossfadeStartsNextAndCanBeStopped() async throws {
        let url = try MediaTests.fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let model = PlayerModel(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false)
        var first = try tools.probe(url: url); first.title = "First"
        var second = try tools.probe(url: url); second.path = url.path + ".second.wav"; second.title = "Second"
        try Data(contentsOf: url).write(to: second.url); defer { try? FileManager.default.removeItem(at: second.url) }
        model.store.add([first, second]); model.refresh(); model.volume = 0; model.crossfadeEnabled = true; model.crossfadeDuration = 0.25
        defer { model.stop() }
        model.play(first, within: [first, second]); model.seek(0.8)
        model.checkCrossfade()
        XCTAssertTrue(model.transitioning)
        XCTAssertEqual(model.currentID, second.id)
        model.advance()
        XCTAssertFalse(model.transitioning, "Next at queue end must stop both fading players")
        model.stop(); try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(model.transitioning); XCTAssertFalse(model.playing); XCTAssertFalse(model.audio.hasSession)
    }
}
