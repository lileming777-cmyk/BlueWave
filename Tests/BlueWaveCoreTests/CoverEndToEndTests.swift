import XCTest
import AppKit
import SwiftUI
import ImageIO
@testable import BlueWaveCore
@testable import BlueWave

/// Exercises the real metadata/image client, model preview path and SwiftUI pixels.
/// HTTP is entirely in memory. No application/window or user music is opened.
final class CoverEndToEndTests: XCTestCase {
    private static let releaseID = "12345678-1234-1234-1234-123456789012"
    private static let sourceURL = URL(string: "https://archive.org/bluewave-synthetic-fixture/red-front-500.png")!

    private actor FixtureHTTP {
        let artist: String
        let png: Data
        private var requests: [URLRequest] = []

        init(artist: String = "Fixture Singer", png: Data) {
            self.artist = artist
            self.png = png
        }

        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard let url = request.url else { throw URLError(.badURL) }
            let data: Data
            let responseURL: URL
            if url.host == "musicbrainz.org", ["/ws/2/release", "/ws/2/release/"].contains(url.path) {
                data = try JSONSerialization.data(withJSONObject: ["releases": [[
                    "id": CoverEndToEndTests.releaseID, "title": "Fixture Album", "score": 100,
                    "status": "Official", "artist-credit": [["name": artist, "artist": ["name": artist]]]
                ]]])
                responseURL = url
            } else if url.host == "musicbrainz.org", ["/ws/2/recording", "/ws/2/recording/"].contains(url.path) {
                data = try JSONSerialization.data(withJSONObject: ["recordings": [[
                    "title": "Fixture Song", "score": 100,
                    "artist-credit": [["name": artist, "artist": ["name": artist]]],
                    "releases": [["id": CoverEndToEndTests.releaseID, "status": "Official"]]
                ]]])
                responseURL = url
            } else if url.host == "coverartarchive.org", url.path == "/release/\(CoverEndToEndTests.releaseID)/front-500" {
                data = png
                responseURL = CoverEndToEndTests.sourceURL
            } else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
            return (data, response)
        }

        func allRequests() -> [URLRequest] { requests }
    }

    private func client(_ server: FixtureHTTP) -> CoverArtClient {
        CoverArtClient(providers: [.musicBrainz], http: { try await server.send($0) },
                       now: { Date(timeIntervalSince1970: 100) },
                       sleep: { _ in try Task.checkCancellation() })
    }

    @MainActor private func redPNG() throws -> Data {
        let rgba = Data([255, 0, 0, 255, 255, 0, 0, 255,
                         255, 0, 0, 255, 255, 0, 0, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: rgba as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: 8, space: space,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func fixtureTrack(root: URL) -> Track {
        var track = Track(path: root.appendingPathComponent("NoArtwork/fixture.wav").path,
                          title: "Fixture Song", artist: "Fixture Singer", album: "Fixture Album")
        track.metadataRevision = 2
        return track
    }

    @MainActor private func model(root: URL, client: CoverArtClient) -> PlayerModel {
        PlayerModel(storeURL: root.appendingPathComponent("library.json"),
                    toolsDirectory: root.appendingPathComponent("NoTools"), enableMediaCommands: false,
                    coverFetcher: { track, cache in await client.fetch(for: track, cacheDirectory: cache) })
    }

    @MainActor private func waitForCoverResult(_ model: PlayerModel, track: Track) async throws {
        for _ in 0..<300 {
            if model.covers[track.id] != nil || model.coverStatus[track.id]?.hasPrefix("未找到") == true { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Cover request did not finish; status=\(model.coverStatus[track.id] ?? "nil")")
    }

    @MainActor private func renderedCenter(_ model: PlayerModel, track: Track, evidenceName: String) throws -> NSColor {
        let content = Artwork(track: track, size: 96, onlinePreview: true)
            .environmentObject(model).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer could not render Artwork offscreen")
        let renderedCG = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(renderedCG.width, 96)
        XCTAssertEqual(renderedCG.height, 96)
        // colorAt() labels samples as calibrated RGB even for an sRGB bitmap.
        // Sample explicit sRGB RGBA bytes instead of converting that mislabeled NSColor.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 96,
                                             bitsPerComponent: 8, bytesPerRow: 96 * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(renderedCG, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = 48 * context.bytesPerRow + 48 * 4
        let color = NSColor(srgbRed: CGFloat(bytes[offset]) / 255,
                            green: CGFloat(bytes[offset + 1]) / 255,
                            blue: CGFloat(bytes[offset + 2]) / 255,
                            alpha: CGFloat(bytes[offset + 3]) / 255)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let evidence = URL(fileURLWithPath: "/private/tmp/bluewave-cover-e2e-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent(evidenceName + ".png"), options: .atomic)
        print("Artwork E2E \(evidenceName): center sRGB=(\(color.redComponent),\(color.greenComponent),\(color.blueComponent)); \(evidence.path)/\(evidenceName).png")
        return color
    }

    private func assertRed(_ color: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(color.redComponent, 0.95, "Expected downloaded red artwork, not placeholder", file: file, line: line)
        XCTAssertLessThan(color.greenComponent, 0.05, "Expected downloaded red artwork, not placeholder", file: file, line: line)
        XCTAssertLessThan(color.blueComponent, 0.05, "Expected downloaded red artwork, not placeholder", file: file, line: line)
    }

    @MainActor func testRealClientModelAndArtworkRenderDownloadedCoverThenReloadDiskCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueWave-cover-e2e-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try redPNG(), server = FixtureHTTP(png: png)
        let firstClient = client(server)
        let first = model(root: root, client: firstClient)
        let track = fixtureTrack(root: root), owner = UUID()
        first.store.add([track]); first.persist(); first.autoDownloadCovers = true
        defer { first.releaseCoverPreview(owner: owner); first.cancelOnlineCover(includingPreviews: true); first.stop() }
        first.requestCover(track, preview: true, owner: owner)
        try await waitForCoverResult(first, track: track)
        assertRed(try renderedCenter(first, track: track, evidenceName: "downloaded-artwork"))
        let imageURL = try XCTUnwrap(first.covers[track.id])
        XCTAssertEqual(try Data(contentsOf: imageURL), png)
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: imageURL.deletingPathExtension().appendingPathExtension("json"))) as? [String: Any])
        XCTAssertEqual(source["sourceURL"] as? String, Self.sourceURL.absoluteString)
        XCTAssertEqual(source["artist"] as? String, track.artist)
        let initialRequests = await server.allRequests()
        XCTAssertEqual(initialRequests.count, 2)
        XCTAssertEqual(initialRequests.last?.url?.host, "coverartarchive.org")
        XCTAssertFalse(initialRequests.compactMap { $0.url?.absoluteString }.joined().contains(root.path))
        XCTAssertFalse(first.playing)

        let second = model(root: root, client: client(server)), secondOwner = UUID()
        defer { second.releaseCoverPreview(owner: secondOwner); second.cancelOnlineCover(includingPreviews: true); second.stop() }
        let restoredTrack = try XCTUnwrap(second.tracks.first { $0.id == track.id })
        second.autoDownloadCovers = true
        second.requestCover(restoredTrack, preview: true, owner: secondOwner)
        try await waitForCoverResult(second, track: restoredTrack)
        XCTAssertEqual(second.covers[track.id], imageURL)
        assertRed(try renderedCenter(second, track: restoredTrack, evidenceName: "cache-reloaded-artwork"))
        let finalRequests = await server.allRequests()
        XCTAssertEqual(finalRequests.count, initialRequests.count, "A new model/client must reuse disk cache without HTTP")
    }

    @MainActor func testWrongSingerWithSameAlbumAndTitleNeverReachesModelOrArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueWave-cover-wrong-singer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = FixtureHTTP(artist: "Different Fixture Singer", png: try redPNG())
        let model = model(root: root, client: client(server)), track = fixtureTrack(root: root), owner = UUID()
        defer { model.releaseCoverPreview(owner: owner); model.cancelOnlineCover(includingPreviews: true); model.stop() }
        model.store.add([track]); model.persist(); model.autoDownloadCovers = true
        model.requestCover(track, preview: true, owner: owner)
        try await waitForCoverResult(model, track: track)
        XCTAssertNil(model.covers[track.id], "Wrong singer must be rejected at model boundary")
        let pixel = try renderedCenter(model, track: track, evidenceName: "wrong-singer-placeholder")
        XCTAssertFalse(pixel.redComponent > 0.95 && pixel.greenComponent < 0.05 && pixel.blueComponent < 0.05)
        let requests = await server.allRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "musicbrainz.org" }, "Artist mismatch must never request CAA pixels")
    }
    @MainActor func testMissingArtworkUsesSongTitleRatherThanSharedWaveform() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueWave-title-artwork-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(root: root, client: client(FixtureHTTP(png: try redPNG())))
        var first = fixtureTrack(root: root)
        first.title = "味道"
        var second = first
        second.title = "挪威的森林"
        _ = try renderedCenter(model, track: first, evidenceName: "fallback-title-weidao")
        _ = try renderedCenter(model, track: second, evidenceName: "fallback-title-forest")
        let evidence = URL(fileURLWithPath: "/private/tmp/bluewave-cover-e2e-evidence")
        XCTAssertNotEqual(try Data(contentsOf: evidence.appendingPathComponent("fallback-title-weidao.png")),
                          try Data(contentsOf: evidence.appendingPathComponent("fallback-title-forest.png")),
                          "Missing covers must display their different song titles")
    }

    @MainActor func testOptInProductionJointSearchDownloadsRenderableArtwork() async throws {
        guard ProcessInfo.processInfo.environment["BLUEWAVE_VERIFY_ONLINE_COVER"] == "1" else {
            throw XCTSkip("Explicit opt-in required for live public cover lookup")
        }
        let root = URL(fileURLWithPath: "/private/tmp/bluewave-live-cover-verification-\(UUID())")
        var track = Track(path: root.appendingPathComponent("nonexistent.wav").path,
                          title: "味道", artist: "江智民", album: "未知专辑")
        let client = CoverArtClient(providers: [.deezer])
        let fetched = await client.fetch(for: track, cacheDirectory: root.appendingPathComponent("Covers/Online"))
        let result = try XCTUnwrap(fetched)
        let attribution = try XCTUnwrap(CoverArtClient.attribution(for: result))
        XCTAssertEqual(attribution.matchedArtist, track.artist)
        XCTAssertEqual(attribution.matchedTitle, track.title)
        XCTAssertEqual(attribution.matchedAlbum, "声音")
        XCTAssertNotNil(NSImage(contentsOf: result))
        let model = model(root: root, client: client)
        track.metadataRevision = MetadataInference.revision
        model.store.add([track]); model.persist(); model.autoDownloadCovers = true
        let owner = UUID()
        defer { model.releaseCoverPreview(owner: owner); model.cancelOnlineCover(includingPreviews: true); model.stop() }
        model.requestCover(track, preview: true, owner: owner)
        try await waitForCoverResult(model, track: track)
        XCTAssertEqual(model.covers[track.id], result)
        XCTAssertEqual(model.coverAttributions[track.id], attribution)
        _ = try renderedCenter(model, track: track, evidenceName: "live-deezer-weidao")
        print("Live public cover verified: \(attribution.matchedArtist) / \(attribution.matchedTitle) / \(attribution.matchedAlbum); \(result.path)")
    }

    @MainActor func testAlbumFallbackActuallyRendersImageWithoutOverwritingSongCover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlueWave-album-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = try redPNG(), image = root.appendingPathComponent("album.png")
        try png.write(to: image)
        let model = model(root: root, client: client(FixtureHTTP(png: png)))
        let track = fixtureTrack(root: root)
        var sibling = fixtureTrack(root: root)
        sibling.title = "Another Song"
        sibling.path = root.appendingPathComponent("Other Folder/another.wav").path
        model.store.add([track, sibling]); model.persist()
        model.covers[sibling.id] = image
        XCTAssertEqual(model.artworkSourceStatus(for: track), "专辑封面")
        assertRed(try renderedCenter(model, track: track, evidenceName: "same-album-fallback"))
        XCTAssertNil(model.covers[track.id], "Borrowing an album image must not suppress the song's own lookup")
    }

}
