import Foundation
import CryptoKit
import ImageIO

public enum CoverArtProvider: String, Codable, Sendable { case deezer, musicBrainz }

public struct CoverArtAttribution: Codable, Sendable, Equatable {
    public let provider: CoverArtProvider
    public let matchedArtist: String
    public let matchedTitle: String
    public let matchedAlbum: String
    public let sourceURL: URL
}

/// Downloads artwork using text tags only. Audio data and local paths never leave the device.
public actor CoverArtClient {
    typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let providers: [CoverArtProvider]
    private let http: HTTP
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Double) async throws -> Void
    private var nextSearch = Date.distantPast
    private static let maximumBytes = 8 * 1024 * 1024
    private struct Source: Codable {
        let artist: String
        let album: String
        let title: String
        let releaseID: String
        let sourceURL: URL
        let fetchedAt: Date
        var provider: CoverArtProvider? = nil
        var matchedArtist: String? = nil
        var matchedTitle: String? = nil
        var matchedAlbum: String? = nil
    }

    public init(providers: [CoverArtProvider] = [.deezer, .musicBrainz]) {
        self.providers = providers
        http = { try await Self.download($0) }
        now = { Date() }
        sleep = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    }

    init(providers: [CoverArtProvider] = [.deezer, .musicBrainz], http: @escaping HTTP, now: @escaping @Sendable () -> Date,
         sleep: @escaping @Sendable (Double) async throws -> Void) {
        self.providers = providers; self.http = http; self.now = now; self.sleep = sleep
    }

    public nonisolated static func attribution(for imageURL: URL) -> CoverArtAttribution? {
        let sidecar = imageURL.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: sidecar),
              let source = try? JSONDecoder().decode(Source.self, from: data) else { return nil }
        let provider: CoverArtProvider = source.releaseID.hasPrefix("deezer:") ? .deezer : .musicBrainz
        let detailURL: URL
        if provider == .deezer {
            let id = String(source.releaseID.dropFirst("deezer:".count))
            guard validDeezerID(id) else { return nil }
            detailURL = URL(string: "https://www.deezer.com/track/\(id)")!
        } else {
            guard UUID(uuidString: source.releaseID) != nil else { return nil }
            detailURL = URL(string: "https://musicbrainz.org/release/\(source.releaseID)")!
        }
        return CoverArtAttribution(provider: provider, matchedArtist: source.matchedArtist ?? source.artist,
                                   matchedTitle: source.matchedTitle ?? source.title,
                                   matchedAlbum: source.matchedAlbum ?? source.album, sourceURL: detailURL)
    }

    public func fetch(for track: Track, cacheDirectory: URL) async -> URL? {
        do {
            try Task.checkCancellation()
            guard Self.known(track.artist, kind: "artist"), Self.known(track.title, kind: "title") else { return nil }
            let identity = [track.artist, track.album, track.title].map(Self.normalized).joined(separator: "\u{1f}")
            let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let imageURL = cacheDirectory.appendingPathComponent(key + ".image")
            let sourceURL = cacheDirectory.appendingPathComponent(key + ".json")
            if let data = try? Data(contentsOf: imageURL, options: .mappedIfSafe), Self.validImage(data),
               let sourceData = try? Data(contentsOf: sourceURL),
               let source = try? JSONDecoder().decode(Source.self, from: sourceData),
               Self.normalized(source.artist) == Self.normalized(track.artist),
               Self.normalized(source.album) == Self.normalized(track.album),
               Self.normalized(source.title) == Self.normalized(track.title) {
                try Task.checkCancellation()
                return imageURL
            }
            for provider in providers {
                // Each provider owns its three-image budget; one outage cannot
                // exhaust the fallback provider before it has tried an image.
                var tried = Set<String>()
                try Task.checkCancellation()
                do {
                    let result: URL?
                    switch provider {
                    case .deezer:
                        result = try await deezerArtwork(track: track, tried: &tried, imageURL: imageURL, sourceURL: sourceURL)
                    case .musicBrainz:
                        result = try await musicBrainzArtwork(track: track, tried: &tried, imageURL: imageURL, sourceURL: sourceURL)
                    }
                    if let result { return result }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    // A provider outage must not suppress another provider's lookup.
                }
            }
            return nil
        } catch { return nil }
    }

    private func musicBrainzArtwork(track: Track, tried: inout Set<String>, imageURL: URL, sourceURL: URL) async throws -> URL? {
        // Every provider first establishes the singer AND song identity. Album tags
        // only rank releases of that exact recording; they cannot authorize artwork.
        let recordings = try await search(entity: "recording", field: "recording", value: track.title, artist: track.artist)
        let candidates = recordings.filter {
            Self.score($0) >= 90 && Self.normalized($0["title"] as? String ?? "") == Self.normalized(track.title)
            && Self.matchesArtist($0, artist: track.artist)
        }.flatMap { ($0["releases"] as? [[String: Any]] ?? []).filter {
            ["official", "pseudo-release"].contains(($0["status"] as? String)?.lowercased() ?? "")
            && ($0["artist-credit"] == nil || Self.matchesArtist($0, artist: track.artist))
        } }
        let preferred = candidates.filter { Self.normalized($0["title"] as? String ?? "") == Self.normalized(track.album) }
        let others = candidates.filter { Self.normalized($0["title"] as? String ?? "") != Self.normalized(track.album) }
        return try await artwork(preferred + others, track: track, tried: &tried, imageURL: imageURL, sourceURL: sourceURL)
    }

    private func deezerArtwork(track: Track, tried: inout Set<String>, imageURL: URL, sourceURL: URL) async throws -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: track.artist + " " + track.title), URLQueryItem(name: "limit", value: "10")]
        let (data, _) = try await request(components.url!, image: false)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = (root?["data"] as? [[String: Any]] ?? []).filter {
            Self.normalized($0["title"] as? String ?? "") == Self.normalized(track.title)
            && Self.normalized(($0["artist"] as? [String: Any])?["name"] as? String ?? "") == Self.normalized(track.artist)
        }
        // Stable album preference: ties preserve the provider's original result order.
        let preferred = entries.filter { Self.normalized(($0["album"] as? [String: Any])?["title"] as? String ?? "") == Self.normalized(track.album) }
        let others = entries.filter { Self.normalized(($0["album"] as? [String: Any])?["title"] as? String ?? "") != Self.normalized(track.album) }
        for entry in preferred + others {
            try Task.checkCancellation()
            guard tried.count < 3 else { break }
            let id = (entry["id"] as? NSNumber)?.stringValue ?? entry["id"] as? String ?? ""
            guard Self.validDeezerID(id), !tried.contains("deezer:" + id),
                  let album = entry["album"] as? [String: Any] else { continue }
            let urls = ["cover_big", "cover_medium", "cover_xl", "cover_small"].compactMap { (album[$0] as? String).flatMap(URL.init(string:)) }
            guard let url = urls.first(where: Self.allowedDeezerImage) else { continue }
            tried.insert("deezer:" + id)
            do {
                let (data, response) = try await request(url, image: true)
                guard Self.validImage(data) else { continue }
                let source = Source(artist: track.artist, album: track.album, title: track.title,
                                    releaseID: "deezer:" + id, sourceURL: response.url ?? url, fetchedAt: now(),
                                    provider: .deezer, matchedArtist: (entry["artist"] as? [String: Any])?["name"] as? String,
                                    matchedTitle: entry["title"] as? String, matchedAlbum: album["title"] as? String)
                return try Self.cache(data, source: source, imageURL: imageURL, sourceURL: sourceURL)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
            }
        }
        return nil
    }

    private static func validDeezerID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 20 && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && id.contains { $0 != "0" }
    }
    private static func allowedDeezerImage(_ url: URL) -> Bool {
        allowed(url, image: true) && ["cdn-images.dzcdn.net", "e-cdns-images.dzcdn.net"].contains(url.host?.lowercased() ?? "")
    }
    private static func cache(_ data: Data, source: Source, imageURL: URL, sourceURL: URL) throws -> URL {
        try Task.checkCancellation()
        let sourceData = try JSONEncoder().encode(source)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sourceData.write(to: sourceURL, options: .atomic)
        try data.write(to: imageURL, options: .atomic)
        try Task.checkCancellation()
        return imageURL
    }

    private func search(entity: String, field: String, value: String, artist: String) async throws -> [[String: Any]] {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(entity)/")!
        components.queryItems = [URLQueryItem(name: "query", value: "artist:\"\(Self.escaped(artist))\" AND \(field):\"\(Self.escaped(value))\""), URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "10")]
        let (data, _) = try await request(components.url!, image: false)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?[entity == "release" ? "releases" : "recordings"] as? [[String: Any]] ?? []).sorted { Self.score($0) > Self.score($1) }
    }

    private func artwork(_ releases: [[String: Any]], track: Track, tried: inout Set<String>, imageURL: URL, sourceURL: URL) async throws -> URL? {
        for release in releases {
            try Task.checkCancellation()
            guard tried.count < 3 else { break }
            guard let id = release["id"] as? String, UUID(uuidString: id) != nil, !tried.contains(id) else { continue }
            tried.insert(id)
            let url = URL(string: "https://coverartarchive.org/release/\(id)/front-500")!
            do {
                let (data, response) = try await request(url, image: true)
                guard Self.validImage(data) else { continue }
                try Task.checkCancellation()
                let source = Source(artist: track.artist, album: track.album, title: track.title, releaseID: id,
                                    sourceURL: response.url ?? url, fetchedAt: now(), provider: .musicBrainz,
                                    matchedArtist: track.artist, matchedTitle: track.title,
                                    matchedAlbum: release["title"] as? String ?? track.album)
                return try Self.cache(data, source: source, imageURL: imageURL, sourceURL: sourceURL)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
            }
        }
        return nil
    }

    private func request(_ url: URL, image: Bool) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard Self.allowed(url, image: image) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("BlueWave/1.0.4", forHTTPHeaderField: "User-Agent")
        request.setValue(image ? "image/*" : "application/json", forHTTPHeaderField: "Accept")
        for attempt in 0...1 {
            if !image {
                let current = now(), slot = max(current, nextSearch)
                nextSearch = slot.addingTimeInterval(1)
                if slot > current { try await sleep(slot.timeIntervalSince(current)) }
                try Task.checkCancellation()
            }
            let (data, response) = try await http(request)
            try Task.checkCancellation()
            guard data.count <= Self.maximumBytes, response.expectedContentLength <= Int64(Self.maximumBytes),
                  Self.allowedDestination(response.url, from: url, image: image) else { throw URLError(.badServerResponse) }
            if !image, attempt == 0, [429, 502, 503, 504].contains(response.statusCode) {
                let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1.2
                try await sleep(max(1.2, min(15, retry)))
                try Task.checkCancellation()
                continue
            }
            guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
            return (data, response)
        }
        throw URLError(.badServerResponse)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func known(_ text: String, kind: String) -> Bool {
        let value = normalized(text)
        let unknown: Set<String> = ["", "unknown", "unknown artist", "unknown title", "unknown album", "unknown singer", "untitled", "未知艺人", "未知歌手", "未知标题", "未知歌曲", "未知专辑", "无标题", "不详", "未知", "n a", "none"]
        return !unknown.contains(value)
    }
    private static func escaped(_ text: String) -> String {
        let special = CharacterSet(charactersIn: "+-&|!(){}[]^\"~*?:\\/")
        return text.unicodeScalars.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
    private static func score(_ item: [String: Any]) -> Int {
        (item["score"] as? Int) ?? Int(item["score"] as? String ?? "") ?? 0
    }
    private static func matchesArtist(_ item: [String: Any], artist: String) -> Bool {
        guard let credits = item["artist-credit"] as? [[String: Any]], !credits.isEmpty else { return false }
        let target = normalized(artist)
        for canonical in [false, true] {
            let name = credits.map { credit -> String in
                let artistName = (credit["artist"] as? [String: Any])?["name"] as? String ?? ""
                return (canonical ? artistName : (credit["name"] as? String ?? artistName)) + (credit["joinphrase"] as? String ?? "")
            }.joined()
            if normalized(name) == target { return true }
        }
        return false
    }
    private static func validImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 10000, height <= 10000, width * height <= 40_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }
    fileprivate static func allowed(_ url: URL?, image: Bool) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        if !image { return ["musicbrainz.org", "api.deezer.com"].contains(host) }
        if ["cdn-images.dzcdn.net", "e-cdns-images.dzcdn.net"].contains(host) { return true }
        return ["coverartarchive.org", "archive.org"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    fileprivate static func allowedDestination(_ destination: URL?, from origin: URL?, image: Bool) -> Bool {
        guard allowed(destination, image: image), let destination, let originHost = origin?.host?.lowercased() else { return false }
        if !image { return destination.host?.lowercased() == originHost }
        if ["cdn-images.dzcdn.net", "e-cdns-images.dzcdn.net"].contains(originHost) { return allowedDeezerImage(destination) }
        let host = destination.host?.lowercased() ?? ""
        return ["coverartarchive.org", "archive.org"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    private static func download(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let image = !["musicbrainz.org", "api.deezer.com"].contains(request.url?.host?.lowercased() ?? "")
        guard allowed(request.url, image: image) else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, rawResponse) = try await session.bytes(for: request, delegate: CoverRedirectGuard(image: image, origin: request.url))
        guard let response = rawResponse as? HTTPURLResponse,
              response.expectedContentLength <= Int64(maximumBytes), allowedDestination(response.url, from: request.url, image: image) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class CoverRedirectGuard: NSObject, URLSessionTaskDelegate {
    let image: Bool
    let origin: URL?
    init(image: Bool, origin: URL?) { self.image = image; self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(CoverArtClient.allowedDestination(request.url, from: origin, image: image) ? request : nil)
    }
}
