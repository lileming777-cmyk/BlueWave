import Foundation
import Darwin

public struct MediaError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct ToolResult { public var data: Data; public var diagnostics: String }
public final class ProcessCancellation {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func attach(_ process: Process) {
        lock.lock(); self.process = process; let stopped = cancelled; lock.unlock()
        if stopped && process.isRunning { process.terminate() }
    }
    public func cancel() {
        lock.lock(); cancelled = true; let process = self.process; lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
    }
}
public struct MediaTools {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func executable(_ name: String) -> URL { directory.appendingPathComponent(name) }
    public func run(tool: String, arguments: [String], timeout: Double = 25, limit: Int = 32 * 1024 * 1024, cancellation: ProcessCancellation? = nil) throws -> ToolResult {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let process = Process(); process.executableURL = executable(tool); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardInput = FileHandle.nullDevice
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("bluewave-\(UUID()).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: log); process.standardError = errorHandle
        defer { try? errorHandle.close(); try? output.fileHandleForReading.close(); try? FileManager.default.removeItem(at: log) }
        try process.run()
        cancellation?.attach(process)
        let expiry = DispatchWorkItem {
            if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        defer { expiry.cancel() }
        var data = Data()
        while let block = try output.fileHandleForReading.read(upToCount: 65536), !block.isEmpty {
            data.append(block)
            if data.count > limit { process.terminate(); throw MediaError("文件信息过大，已停止读取") }
        }
        process.waitUntilExit(); try? errorHandle.synchronize()
        if cancellation?.isCancelled == true { throw CancellationError() }
        let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else { throw MediaError("无法解码此文件，可能损坏、加密或格式不支持。\n" + String(diagnostic.suffix(600))) }
        return ToolResult(data: data, diagnostics: diagnostic)
    }
    public func probe(url: URL) throws -> Track {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaError("文件无法访问，请确认外接设备已连接：\(url.lastPathComponent)") }
        let result = try run(tool: "ffprobe", arguments: ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,sample_rate,channels,bits_per_sample,bits_per_raw_sample,duration:format=duration:format_tags:stream_tags", "-of", "json", url.path])
        guard let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any], let streams = json["streams"] as? [[String: Any]], let stream = streams.first else { throw MediaError("文件中没有可播放的音频：\(url.lastPathComponent)") }
        let format = json["format"] as? [String: Any] ?? [:]
        let tags = (format["tags"] as? [String: String] ?? [:]).merging(stream["tags"] as? [String: String] ?? [:]) { a, _ in a }.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        func integer(_ key: String) -> Int { (stream[key] as? Int) ?? Int(stream[key] as? String ?? "") ?? 0 }
        let seconds = Double(format["duration"] as? String ?? stream["duration"] as? String ?? "0") ?? 0
        let identified = MetadataInference.resolve(url: url, tags: tags)
        var track = Track(path: url.path, title: identified.title, artist: identified.artist, album: identified.album, codec: stream["codec_name"] as? String ?? "", sampleRate: integer("sample_rate"), channels: integer("channels"), bitDepth: max(integer("bits_per_sample"), integer("bits_per_raw_sample")), duration: seconds.isFinite ? max(0, seconds) : 0)
        track.metadataSource = identified.source
        track.metadataRevision = MetadataInference.revision
        track.embeddedLyrics = tags.keys.sorted().first(where: { $0.hasPrefix("lyrics") || $0.hasPrefix("unsyncedlyrics") }).flatMap { tags[$0] }
        if track.codec.hasPrefix("dsd") || track.codec == "dst" { track.sampleRate *= 8; track.bitDepth = 1 }
        return track
    }
    public func decodeArguments(url: URL, offset: Double, sampleRate: Int, normalize: Bool = false, precision: Int = 32) -> [String] {
        let start = offset.isFinite ? max(0, offset) : 0
        var args = ["-nostdin", "-v", "error", "-ss", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), start), "-i", url.path, "-map", "0:a:0", "-vn", "-sn", "-dn"]
        var filters: [String] = []
        if normalize { filters.append("loudnorm=I=-18:TP=-1.5:LRA=11") }
        if precision == 16 { filters.append("aresample=osr=\(sampleRate):osf=s16:dither_method=triangular") }
        if precision == 24 { filters.append("aresample=osr=\(sampleRate):osf=s32:output_sample_bits=24:dither_method=triangular") }
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        return args + ["-ac", "2", "-ar", String(sampleRate), "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"]
    }
}
