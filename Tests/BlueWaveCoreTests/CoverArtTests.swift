import XCTest
import AppKit
@testable import BlueWaveCore

final class CoverArtTests: XCTestCase {
    actor Server {
        var requests: [URLRequest] = []
        var replies: [(Data, Int)]
        init(_ replies: [(Data, Int)]) { self.replies = replies }
        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
            let reply = replies.removeFirst()
            return (reply.0, HTTPURLResponse(url: request.url!, statusCode: reply.1, httpVersion: nil, headerFields: nil)!)
        }
        func count() -> Int { requests.count }
        func urls() -> [URL] { requests.compactMap(\.url) }
    }
    let releaseID = "12345678-1234-1234-1234-123456789012"
    func json(_ text: String) -> Data { Data(text.utf8) }
    func image() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])!
    }
    func album(artist: String = "Test Singer", title: String = "Test Song", score: Int = 100) -> Data {
        json("""
        {"recordings":[{"title":"\(title)","score":\(score),"artist-credit":[{"name":"\(artist)","artist":{"name":"\(artist)"}}],"releases":[{"id":"\(releaseID)","title":"Test Album","status":"Official","artist-credit":[{"artist":{"name":"\(artist)"}}]}]}]}
        """)
    }
    func track(album: String = "Test Album", artist: String = "Test Singer", title: String = "Test Song") -> Track {
        Track(path: "/private/synthetic/song.wav", title: title, artist: artist, album: album)
    }
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cover-tests-\(UUID())") }
    func client(_ server: Server) -> CoverArtClient {
        CoverArtClient(providers: [.musicBrainz], http: { try await server.send($0) }, now: { Date(timeIntervalSince1970: 10) }, sleep: { _ in try Task.checkCancellation() })
    }
    func testMatchingAlbumCachesImageAndSourceWithoutSendingPath() async throws {
        let server = Server([(album(), 200), (image(), 200)])
        let client = client(server), directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = await client.fetch(for: track(), cacheDirectory: directory)
        XCTAssertNotNil(first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(first)), image())
        let second = await self.client(server).fetch(for: track(), cacheDirectory: directory)
        XCTAssertEqual(first, second)
        let count = await server.count(); XCTAssertEqual(count, 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasSuffix(".json") })
        let urls = await server.urls()
        XCTAssertFalse(urls.map(\.absoluteString).joined().contains("synthetic"))
        let query = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
        XCTAssertTrue(query.contains("artist:\"Test Singer\"")); XCTAssertTrue(query.contains("recording:\"Test Song\""))
        XCTAssertEqual(urls.last?.path, "/release/\(releaseID)/front-500")
    }
    func testSameAlbumOrTitleByDifferentSingerIsRejected() async {
        let recording = json("""
        {"recordings":[{"title":"Test Song","score":100,"artist-credit":[{"artist":{"name":"Other Singer"}}],"releases":[{"id":"\(releaseID)","status":"Official"}]}]}
        """)
        let server = Server([(album(artist: "Other Singer"), 200), (recording, 200)])
        let result = await client(server).fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(result)
        let count = await server.count(); XCTAssertEqual(count, 1)
    }
    func testRecordingFallbackRequiresExactTitleSingerAndOfficialRelease() async {
        let recording = json("""
        {"recordings":[{"title":"Test Song","score":95,"artist-credit":[{"artist":{"name":"Test Singer"}}],"releases":[{"id":"\(releaseID)","status":"Official"}]}]}
        """)
        let server = Server([(recording, 200), (image(), 200)])
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = await client(server).fetch(for: track(), cacheDirectory: directory)
        XCTAssertNotNil(result)
        let urls = await server.urls(); XCTAssertEqual(urls[0].path, "/ws/2/recording")
    }
    func testUnknownMetadataDoesNotUseNetwork() async {
        let server = Server([])
        for song in [track(artist: "未知艺人"), track(title: "Unknown Title")] {
            let result = await client(server).fetch(for: song, cacheDirectory: directory())
            XCTAssertNil(result)
        }
        let count = await server.count(); XCTAssertEqual(count, 0)
    }
    func testOfflineAndInvalidOrOversizeImageReturnNil() async {
        for replies: [(Data, Int)] in [[], [(album(), 200), (Data("not an image".utf8), 200)], [(album(), 200), (Data(repeating: 0, count: 8 * 1024 * 1024 + 1), 200)], [(Data(), 503)]] {
            let result = await client(Server(replies)).fetch(for: track(), cacheDirectory: directory())
            XCTAssertNil(result)
        }
    }
    func testCancellationStopsBeforeNetwork() async {
        let server = Server([(album(), 200), (image(), 200)])
        let client = client(server)
        let task = Task { () -> URL? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.fetch(for: track(), cacheDirectory: directory())
        }
        let result = await task.value; XCTAssertNil(result)
        let count = await server.count(); XCTAssertEqual(count, 0)
    }
    func testLowScoreWrongTitleAndUnofficialReleaseAreRejected() async {
        for response in [album(score: 89), album(title: "Another Album")] {
            let server = Server([(response, 200), (json("{\"recordings\":[]}"), 200)])
            let result = await client(server).fetch(for: track(), cacheDirectory: directory())
            XCTAssertNil(result)
            let count = await server.count(); XCTAssertEqual(count, 1)
        }
        let recording = json("""
        {"recordings":[{"title":"Test Song","score":100,"artist-credit":[{"artist":{"name":"Test Singer"}}],"releases":[{"id":"\(releaseID)","status":"Bootleg"}]}]}
        """)
        let result = await client(Server([(recording, 200)])).fetch(for: track(album: "未知专辑"), cacheDirectory: directory())
        XCTAssertNil(result)
    }
    func testFinalResponseFromUntrustedHostIsRejected() async {
        let client = CoverArtClient(providers: [.musicBrainz], http: { request in
            (self.image(), HTTPURLResponse(url: URL(string: "https://coverartarchive.org.attacker.invalid/image")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, now: { Date() }, sleep: { _ in })
        let result = await client.fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(result)
    }
    func testOnlyThreeArtworkCandidatesAreAttempted() async {
        let releases = (1...5).map { number in
            "{\"id\":\"12345678-1234-1234-1234-12345678900\(number)\",\"title\":\"Test Album\",\"status\":\"Official\",\"score\":100,\"artist-credit\":[{\"artist\":{\"name\":\"Test Singer\"}}]}"
        }.joined(separator: ",")
        let server = Server([(json("{\"recordings\":[{\"title\":\"Test Song\",\"score\":100,\"artist-credit\":[{\"artist\":{\"name\":\"Test Singer\"}}],\"releases\":[\(releases)]}]}"), 200), (Data(), 404), (Data(), 404), (Data(), 404)])
        let result = await client(server).fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(result)
        let urls = await server.urls()
        XCTAssertEqual(urls.filter { $0.host == "coverartarchive.org" }.count, 3)
    }
    func testCancellationDuringHTTPDoesNotCacheOrTryFallback() async {
        let directory = directory()
        let client = CoverArtClient(providers: [.musicBrainz], http: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }, now: { Date() }, sleep: { _ in })
        let result = await Task { await client.fetch(for: self.track(), cacheDirectory: directory) }.value
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    actor Delays {
        var values: [Double] = []
        func add(_ value: Double) { values.append(value) }
        func all() -> [Double] { values }
    }
    func testMusicBrainzFallbackWaitsAtLeastOneSecond() async {
        let delays = Delays()
        let server = Server([(json("{\"recordings\":[]}"), 200), (json("{\"recordings\":[]}"), 200)])
        let client = CoverArtClient(providers: [.musicBrainz], http: { try await server.send($0) }, now: { Date(timeIntervalSince1970: 10) }, sleep: { await delays.add($0) })
        let result = await client.fetch(for: track(), cacheDirectory: directory())
        _ = await client.fetch(for: track(), cacheDirectory: directory())
        XCTAssertNil(result)
        let waits = await delays.all(); XCTAssertEqual(waits, [1])
    }

    func testRecordingReleaseWithDifferentArtistIsRejected() async {
        let recording = json("""
        {"recordings":[{"title":"Test Song","score":100,"artist-credit":[{"artist":{"name":"Test Singer"}}],"releases":[{"id":"\(releaseID)","status":"Official","artist-credit":[{"artist":{"name":"Other Singer"}}]}]}]}
        """)
        let server = Server([(recording, 200), (image(), 200)])
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = await client(server).fetch(for: track(album: "未知专辑"), cacheDirectory: directory)
        XCTAssertNil(result)
        let count = await server.count(); XCTAssertEqual(count, 1)
    }

    func testCoverFixTranslatedReleaseStillMatchesExactSingerAndSong() async {
        let recording = json("""
        {"recordings":[{"title":"Test Song","score":100,"artist-credit":[{"artist":{"name":"Test Singer"}}],"releases":[{"id":"\(releaseID)","status":"Pseudo-Release","artist-credit":[{"artist":{"name":"Test Singer"}}]}]}]}
        """)
        let server = Server([(recording, 200), (image(), 200)])
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = await client(server).fetch(for: track(album: "未知专辑"), cacheDirectory: directory)
        XCTAssertNotNil(result)
    }
    func testCoverFixTransientMetadata503RetriesWithoutUsingWrongSinger() async {
        let server = Server([(Data(), 503), (album(), 200), (image(), 200)])
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = await client(server).fetch(for: track(), cacheDirectory: directory)
        XCTAssertNotNil(result)
        let count = await server.count(); XCTAssertEqual(count, 3)
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock(); private var time = 10.0
        func date() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: time) }
        func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; time += seconds }
    }
    actor Times {
        var values: [Double] = []
        func add(_ t: Double) { values.append(t) }
        func all() -> [Double] { values }
    }
    func testCoverFixRetriesAndFallbackShareGlobalRateLimit() async {
        let clock = TestClock(), times = Times()
        let server = Server([(Data(),503),(json("{\"releases\":[]}"),200),(json("{\"recordings\":[]}"),200)])
        let client = CoverArtClient(providers: [.musicBrainz], http: { request in await times.add(clock.date().timeIntervalSince1970); return try await server.send(request) }, now: { clock.date() }, sleep: { clock.advance($0) })
        _ = await client.fetch(for: track(), cacheDirectory: directory())
        _ = await client.fetch(for: track(), cacheDirectory: directory())
        let stamps = await times.all(); XCTAssertEqual(stamps.count, 3)
        for i in 1..<stamps.count { XCTAssertGreaterThanOrEqual(stamps[i] - stamps[i-1], 0.999) }
    }

}
