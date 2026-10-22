import Foundation
import CoreFoundation

public struct IdentifiedMetadata {
    public var title: String
    public var artist: String
    public var album: String
    public var source: String
}
public enum MetadataInference {
    public static let revision = 2
    public static func resolve(url: URL, tags: [String: String]) -> IdentifiedMetadata {
        func value(_ key: String) -> String? { guard let s = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }; return s }
        var title = value("title"), artist = value("artist") ?? value("album_artist"), album = value("album")
        var origins: [String] = []
        if title != nil || artist != nil || album != nil { origins.append("文件标签") }
        let folder = url.deletingLastPathComponent()
        if album == nil || artist == nil {
            let cue = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".cue")
            let candidates = [cue] + ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter { $0.pathExtension.lowercased() == "cue" }
            for cueURL in candidates.sorted(by: { $0.path < $1.path }) {
                guard let size = try? cueURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000, let data = try? Data(contentsOf: cueURL) else { continue }
                let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb) {
                    let pattern = try! NSRegularExpression(pattern: #"(?im)^\s*FILE\s+(?:"([^"]+)"|(\S+))"#)
                    let string = text as NSString
                    let references = pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match -> String in
                        let range = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                        return string.substring(with: range).replacingOccurrences(of: "\\", with: "/")
                    }
                    guard references.contains(where: { URL(fileURLWithPath: $0, relativeTo: folder).standardizedFileURL.resolvingSymlinksInPath().path.caseInsensitiveCompare(url.standardizedFileURL.resolvingSymlinksInPath().path) == .orderedSame }) else { continue }
                    for line in text.components(separatedBy: .newlines) {
                        let clean = line.trimmingCharacters(in: .whitespaces)
                        if clean.uppercased().hasPrefix("TRACK ") { break }
                        if clean.uppercased().hasPrefix("TITLE "), album == nil { album = String(clean.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")); origins.append("CUE") }
                        if clean.uppercased().hasPrefix("PERFORMER "), artist == nil { artist = String(clean.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
                    }
                    break
                }
            }
        }
        if album == nil {
            let name = folder.lastPathComponent
            if !["music", "音乐", "音源", "新音源", "downloads", "download", "untitled", "walkman", "tmp"].contains(name.lowercased()) {
                album = name; origins.append("文件夹推断")
            }
        }
        let rawFilename = url.deletingPathExtension().lastPathComponent
        let filename = rawFilename.replacingOccurrences(of: #"^\d{1,3}\s*(?:[-._]\s*|\s+)"#, with: "", options: .regularExpression)
        // Collection filenames commonly use `01 Song -Singer`; preserve the
        // established `Artist - Song` convention for unnumbered filenames.
        let separator = filename.range(of: " - ") ?? filename.range(of: " -") ?? filename.range(of: "- ")
        if let separator {
            let prefix = String(filename[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let suffix = String(filename[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty, !suffix.isEmpty {
                let titleFirst = (!filename.contains(" - ") && filename.contains(" -")) || (title == prefix) || (artist == suffix)
                if title == nil { title = titleFirst ? prefix : suffix }
                if artist == nil { artist = titleFirst ? suffix : prefix }
                origins.append("文件名推断")
            }
        }
        return IdentifiedMetadata(title: title ?? filename, artist: artist ?? "未知艺人", album: album ?? "未知专辑", source: origins.isEmpty ? "文件名" : Array(NSOrderedSet(array: origins)).compactMap { $0 as? String }.joined(separator: " · "))
    }
}

public enum ArtworkLocator {
    public static func find(for url: URL) -> URL? {
        let directory = url.deletingLastPathComponent()
        let images = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? []).filter { ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        for name in [base, "cover", "folder", "front", "album", "封面"] {
            if let image = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) { return image }
        }
        if let image = images.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: { ["cover", "front", "封面"].contains(where: $0.deletingPathExtension().lastPathComponent.lowercased().contains) }) { return image }
        return images.count == 1 ? images.first : nil
    }
}
