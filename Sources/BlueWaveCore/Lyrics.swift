import Foundation

public struct LyricLine: Identifiable, Equatable {
    public var id: Int
    public var time: Double
    public var text: String
}
public enum Lyrics {
    public static func parse(_ text: String) -> [LyricLine] {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d{1,2}(?:\.\d+)?)\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let ns = text as NSString
        let offset = offsetPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var lines: [LyricLine] = []
        for line in text.components(separatedBy: .newlines) {
            let string = line as NSString
            let matches = timestamp.matches(in: line, range: NSRange(location: 0, length: string.length))
            guard let last = matches.last else { continue }
            let content = string.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(string.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(string.substring(with: match.range(at: 2))) ?? 0
                lines.append(LyricLine(id: lines.count, time: max(0, minutes * 60 + seconds + offset), text: content))
            }
        }
        return lines.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}
public extension Array where Element == LyricLine {
    func activeIndex(at time: Double) -> Int? { lastIndex(where: { $0.time <= time }) }
}
public struct ResolvedLyrics {
    public var lines: [LyricLine]
    public var plainText: String
    public var source: String
    public static func resolve(sidecarText: String?, embedded: String?) -> ResolvedLyrics {
        for (value, source) in [(sidecarText, "本地 LRC"), (embedded, "内嵌歌词")] {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let lines = Lyrics.parse(value)
            return ResolvedLyrics(lines: lines, plainText: lines.isEmpty ? value : "", source: source)
        }
        return ResolvedLyrics(lines: [], plainText: "", source: "")
    }
}
