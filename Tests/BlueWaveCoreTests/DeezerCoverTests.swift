import XCTest
@testable import BlueWaveCore

final class DeezerCoverTests: XCTestCase {
    struct Reply: Sendable {
        let host: String
        let data: Data
        var status = 200
        var finalURL: URL? = nil
    }
    actor Server {
        var replies: [Reply]
        var requests: [URLRequest] = []
        init(_ replies: [Reply]) { self.replies = replies }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
            let reply = replies.removeFirst()
            guard request.url?.host == reply.host else { throw URLError(.badURL) }
            return (reply.data, HTTPURLResponse(url: reply.finalURL ?? request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
        }
        func all() -> [URLRequest] { requests }
    }
    let singer = "Example Singer", title = "Example Song", album = "Preferred Album"
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("deezer-mock-\(UUID())") }
    func track(album: String = "Preferred Album", artist: String = "Example Singer", title: String = "Example Song") -> Track {
        Track(path: "/private/synthetic/no-audio.wav", title: title, artist: artist, album: album)
    }
    func entry(id: Int = 1, artist: String = "Example Singer", title: String = "Example Song", album: String = "Preferred Album", cover: String = "https://cdn-images.dzcdn.net/images/cover/one/500.jpg") -> [String: Any] {
        ["id": id, "title": title, "title_short": "Example Song", "artist": ["name": artist], "album": ["title": album, "cover_big": cover], "preview": "https://never-download.invalid/audio.mp3", "link": "https://www.deezer.com/track/\(id)"]
    }
    func json(_ entries: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: ["data": entries]) }
    func metadata(_ entries: [[String: Any]], status: Int = 200) -> Reply { Reply(host: "api.deezer.com", data: json(entries), status: status) }
    func image() -> Reply { Reply(host: "cdn-images.dzcdn.net", data: CoverArtTests().image()) }
    func client(_ server: Server, providers: [CoverArtProvider] = [.deezer, .musicBrainz]) -> CoverArtClient {
        CoverArtClient(providers: providers, http: { try await server.send($0) }, now: { Date(timeIntervalSince1970: 10) }, sleep: { _ in try Task.checkCancellation() })
    }
    func testJointQueryRejectsFirstWrongSongAndPrefersMatchingAlbum() async throws {
        let wrong = entry(id: 1, title: "Other Song")
        let otherAlbum = entry(id: 2, album: "Other Album", cover: "https://cdn-images.dzcdn.net/images/other.jpg")
        let preferred = entry(id: 3, cover: "https://cdn-images.dzcdn.net/images/preferred.jpg")
        let server = Server([metadata([wrong, otherAlbum, preferred]), image()])
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fetched = await client(server).fetch(for: track(), cacheDirectory: root)
        let result = try XCTUnwrap(fetched)
        let requests = await server.all()
        XCTAssertEqual(requests.count, 2)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "Example Singer Example Song")
        XCTAssertEqual(requests.last?.url?.path, "/images/preferred.jpg")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "User-Agent"), "BlueWave/1.0.4")
        XCTAssertFalse(requests.contains { $0.url!.absoluteString.contains("synthetic") || $0.url!.absoluteString.contains("preview") })
        let attribution = try XCTUnwrap(CoverArtClient.attribution(for: result))
        XCTAssertEqual(attribution.provider, .deezer)
        XCTAssertEqual(attribution.matchedArtist, singer); XCTAssertEqual(attribution.matchedTitle, title)
        XCTAssertEqual(attribution.matchedAlbum, album)
        XCTAssertEqual(attribution.sourceURL.absoluteString, "https://www.deezer.com/track/3")
        struct Legacy: Decodable { let artist: String; let title: String; let album: String; let releaseID: String; let sourceURL: URL; let fetchedAt: Date }
        let sidecar = result.deletingPathExtension().appendingPathExtension("json")
        let legacy = try JSONDecoder().decode(Legacy.self, from: Data(contentsOf: sidecar))
        XCTAssertEqual(legacy.releaseID, "deezer:3"); XCTAssertEqual(legacy.sourceURL.host, "cdn-images.dzcdn.net")
        let offline = Server([])
        let cached = await client(offline).fetch(for: track(), cacheDirectory: root)
        XCTAssertEqual(cached, result)
        let calls = await offline.all(); XCTAssertTrue(calls.isEmpty)
    }
    func testWrongSingerAndVersionTitleCannotUseTitleShort() async {
        let server = Server([metadata([entry(artist: "Other Singer"), entry(title: "Example Song (Live)")])])
        let result = await client(server, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(result)
        let requests = await server.all(); XCTAssertEqual(requests.count, 1)
    }
    func testUnmatchedAlbumUsesFirstExactSingerAndTitleWithoutChangingTags() async throws {
        let server = Server([metadata([entry(id: 9, album: "Actual Album"), entry(id: 10, album: "Another Album")]), image()])
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = track(album: "Unmatched local tag")
        let fetched = await client(server).fetch(for: input, cacheDirectory: root)
        let result = try XCTUnwrap(fetched)
        XCTAssertEqual(CoverArtClient.attribution(for: result)?.matchedAlbum, "Actual Album")
        XCTAssertEqual(input.album, "Unmatched local tag")
    }
    func testDeezerFailureFallsBackToMusicBrainzAndSharesRateLimit() async throws {
        let fixtures = CoverArtTests()
        let clock = CoverArtTests.TestClock(), times = CoverArtTests.Times()
        let server = Server([metadata([], status: 503), metadata([], status: 503), Reply(host: "musicbrainz.org", data: fixtures.album()), Reply(host: "coverartarchive.org", data: fixtures.image())])
        let client = CoverArtClient(http: { request in await times.add(clock.date().timeIntervalSince1970); return try await server.send(request) }, now: { clock.date() }, sleep: { clock.advance($0) })
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fetched = await client.fetch(for: fixtures.track(), cacheDirectory: root)
        let result = try XCTUnwrap(fetched)
        XCTAssertEqual(CoverArtClient.attribution(for: result)?.provider, .musicBrainz)
        let requests = await server.all(); XCTAssertEqual(requests.count, 4)
        let stamps = await times.all()
        XCTAssertGreaterThanOrEqual(stamps[1] - stamps[0], 1)
        XCTAssertGreaterThanOrEqual(stamps[2] - stamps[1], 1)
    }
    func testUnknownTagsNoNetworkAndCancelledRequestDoesNotFallThrough() async {
        let server = Server([])
        for input in [track(artist: "未知艺人"), track(title: "Unknown Title")] {
            let result = await client(server).fetch(for: input, cacheDirectory: directory()); XCTAssertNil(result)
        }
        let requests = await server.all(); XCTAssertTrue(requests.isEmpty)
        let cancelling = CoverArtClient(http: { _ in withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }, now: { Date() }, sleep: { _ in })
        let result = await Task { await cancelling.fetch(for: self.track(), cacheDirectory: self.directory()) }.value
        XCTAssertNil(result)
    }
    func testUntrustedImageDomainsAndOversizeResponsesAreRejected() async {
        for url in ["http://cdn-images.dzcdn.net/a.jpg", "https://cdn-images.dzcdn.net.attacker.invalid/a.jpg", "https://api.deezer.com/image", "https://never-download.invalid/audio.mp3"] {
            let server = Server([metadata([entry(cover: url)])])
            let result = await client(server, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
            XCTAssertNil(result)
            let requests = await server.all(); XCTAssertEqual(requests.count, 1)
        }
        for reply in [Reply(host: "cdn-images.dzcdn.net", data: Data(repeating: 0, count: 8 * 1024 * 1024 + 1)), Reply(host: "cdn-images.dzcdn.net", data: image().data, finalURL: URL(string: "https://attacker.invalid/image")!)] {
            let server = Server([metadata([entry()]), reply])
            let result = await client(server, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
            XCTAssertNil(result)
        }
    }
    func testEmptyDeezerResultsFallThroughToMusicBrainz() async throws {
        let fixtures = CoverArtTests()
        let server = Server([metadata([]), Reply(host: "musicbrainz.org", data: fixtures.album()), Reply(host: "coverartarchive.org", data: fixtures.image())])
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fetched = await client(server).fetch(for: fixtures.track(), cacheDirectory: root)
        XCTAssertNotNil(fetched)
        let requests = await server.all(); XCTAssertEqual(requests.map { $0.url!.host! }, ["api.deezer.com", "musicbrainz.org", "coverartarchive.org"])
    }
    func testCDNRedirectStaysWithinDeezerImageHosts() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secondCDN = URL(string: "https://e-cdns-images.dzcdn.net/images/cover/one/500.jpg")!
        let accepted = Server([metadata([entry()]), Reply(host: "cdn-images.dzcdn.net", data: image().data, finalURL: secondCDN)])
        let fetched = await client(accepted, providers: [.deezer]).fetch(for: track(), cacheDirectory: root)
        XCTAssertNotNil(fetched)
        for destination in ["https://coverartarchive.org/release/image", "https://api.deezer.com/image", "https://cdn-images.dzcdn.net.attacker.invalid/x"] {
            let server = Server([metadata([entry()]), Reply(host: "cdn-images.dzcdn.net", data: image().data, finalURL: URL(string: destination)!)])
            let result = await client(server, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
            XCTAssertNil(result)
        }
        let metadataRedirect = Server([Reply(host: "api.deezer.com", data: json([entry()]), finalURL: URL(string: "https://musicbrainz.org/unexpected")!)])
        let result = await client(metadataRedirect, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(result)
    }
    func testOldMusicBrainzSidecarAttributionRemainsReadable() throws {
        let root = directory(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("old.image"), id = CoverArtTests().releaseID
        let old: [String: Any] = ["artist": singer, "title": title, "album": album, "releaseID": id,
                                  "sourceURL": "https://coverartarchive.org/release/\(id)/front-500", "fetchedAt": 1]
        try JSONSerialization.data(withJSONObject: old).write(to: root.appendingPathComponent("old.json"))
        let attribution = try XCTUnwrap(CoverArtClient.attribution(for: image))
        XCTAssertEqual(attribution.provider, .musicBrainz); XCTAssertEqual(attribution.matchedArtist, singer)
        XCTAssertEqual(attribution.sourceURL.absoluteString, "https://musicbrainz.org/release/\(id)")
    }
    func testMetadataSizeAndFakeImageAreRejected() async {
        let huge = Server([Reply(host: "api.deezer.com", data: Data(repeating: 0, count: 8 * 1024 * 1024 + 1))])
        let first = await client(huge, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(first)
        let invalid = Server([metadata([entry()]), Reply(host: "cdn-images.dzcdn.net", data: Data("not an image".utf8))])
        let second = await client(invalid, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(second)
    }

    func testTransient503RecoversAndArtworkAttemptsAreBounded() async throws {
        let retrying = Server([metadata([], status: 503), metadata([entry()]), image()])
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fetched = await client(retrying).fetch(for: track(), cacheDirectory: root)
        XCTAssertNotNil(fetched)
        let requests = await retrying.all(); XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.prefix(2).map { $0.url!.host! }, ["api.deezer.com", "api.deezer.com"])
        let candidates = (1...5).map { entry(id: $0) }
        let bounded = Server([metadata(candidates)] + (0..<3).map { _ in Reply(host: "cdn-images.dzcdn.net", data: Data(), status: 404) })
        let absent = await client(bounded, providers: [.deezer]).fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(absent)
        let attempts = await bounded.all(); XCTAssertEqual(attempts.count, 4)
    }

    func testThreeFailedDeezerImagesDoNotConsumeMusicBrainzCandidateBudget() async throws {
        let fixtures = CoverArtTests()
        let candidates = (1...3).map { entry(id: $0, artist: "Test Singer", title: "Test Song", album: "Test Album") }
        let server = Server([metadata(candidates)]
                            + (0..<3).map { _ in Reply(host: "cdn-images.dzcdn.net", data: Data(), status: 404) }
                            + [Reply(host: "musicbrainz.org", data: fixtures.album()), Reply(host: "coverartarchive.org", data: fixtures.image())])
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fetched = await client(server).fetch(for: fixtures.track(), cacheDirectory: root)
        XCTAssertNotNil(fetched, "Exhausting Deezer images must still allow a MusicBrainz image")
        let requests = await server.all()
        XCTAssertEqual(requests.filter { $0.url?.host == "coverartarchive.org" }.count, 1)
    }

}
