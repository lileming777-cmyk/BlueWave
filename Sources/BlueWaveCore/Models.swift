import Foundation

public struct Track: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var title: String
    public var artist: String
    public var album: String
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var bitDepth: Int
    public var duration: Double
    public var favorite: Bool
    public var addedAt: Date
    public var playedAt: Date?
    public var embeddedLyrics: String?
    public var lyricsChecked: Bool? = true
    public var metadataSource: String?
    public var metadataRevision: Int?
    public init(path: String, title: String = "", artist: String = "未知艺人", album: String = "未知专辑", codec: String = "", sampleRate: Int = 0, channels: Int = 2, bitDepth: Int = 0, duration: Double = 0) {
        self.id = UUID(); self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.title = title.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : title
        self.artist = artist; self.album = album; self.codec = codec; self.sampleRate = sampleRate
        self.channels = channels; self.bitDepth = bitDepth; self.duration = duration
        self.favorite = false; self.addedAt = Date()
    }
    public var url: URL { URL(fileURLWithPath: path) }
    public var fileFormat: String { url.pathExtension.uppercased() }
    public var albumIdentity: String { url.deletingLastPathComponent().path + "\u{1f}" + album }
    public var isHighRes: Bool { sampleRate > 48000 || bitDepth > 16 || ["DSF", "DFF"].contains(fileFormat) }
    public var quality: String {
        let rate = sampleRate >= 1_000_000 ? String(format: "%.1f MHz", Double(sampleRate) / 1_000_000) : String(format: "%g kHz", Double(sampleRate) / 1000)
        return sampleRate > 0 ? "\(fileFormat) · \(rate)\(bitDepth > 0 ? " · \(bitDepth) bit" : "")" : fileFormat
    }
}

public struct Playlist: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    public var trackIDs: [UUID] = []
    public init(name: String) { self.name = name }
}

public enum MusicFiles {
    public static let extensions: Set<String> = ["mp3","aac","m4a","mp4","wav","wave","aif","aiff","flac","alac","ogg","oga","opus","wma","ape","dsf","dff","oma","aa3","at3","wv","tta","ac3","mka","mp2","au","caf"]
    public static func isAudio(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix("._") }
}

public func timeLabel(_ value: Double) -> String {
    guard value.isFinite && value >= 0 else { return "0:00" }
    let seconds = Int(value)
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
