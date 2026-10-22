import XCTest
@testable import BlueWaveCore

final class MediaTests: XCTestCase {
    let tools = MediaTools(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor"))
    static func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("歌曲 ' $blue-\(UUID()).wav")
        var bytes = Data()
        func str(_ s: String) { bytes.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        str("RIFF"); u32(36 + 96000); str("WAVEfmt "); u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16); str("data"); u32(96000)
        for i in 0..<48000 { u16(UInt16(bitPattern: Int16(sin(Double(i) * 440 * 2 * .pi / 48000) * 3000))) }
        try bytes.write(to: url); return url
    }
    func testProbeAndDecodeUnicodePath() throws {
        let url = try Self.fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let track = try tools.probe(url: url)
        XCTAssertEqual(track.sampleRate, 48000)
        XCTAssertEqual(track.channels, 1)
        XCTAssertEqual(track.duration, 1, accuracy: 0.001)
        let data = try tools.run(tool: "ffmpeg", arguments: tools.decodeArguments(url: url, offset: 0, sampleRate: 48000)).data
        XCTAssertEqual(data.count, 48000 * 2 * 4)
        XCTAssertTrue(data.contains(where: { $0 != 0 }))
    }
    func testInvalidFileProducesRecoverableError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dsf")
        try Data("not audio".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try tools.probe(url: url))
    }
    func testSeekDoesNotPassNonFiniteOrNegativeOffsets() {
        let url = URL(fileURLWithPath: "/tmp/track.wav")
        for value in [-1.0, Double.nan, Double.infinity] {
            let args = tools.decodeArguments(url: url, offset: value, sampleRate: 48000)
            XCTAssertFalse(args.contains("nan")); XCTAssertFalse(args.contains("inf")); XCTAssertFalse(args.contains("-1.0"))
            XCTAssertEqual(args[args.firstIndex(of: "-ss")! + 1], "0.000")
        }
    }
    func testEmbeddedLyricsAreReadFromRealMetadata() throws {
        let input = try Self.fixture(); let output = input.deletingPathExtension().appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        _ = try tools.run(tool: "ffmpeg", arguments: ["-nostdin", "-v", "error", "-y", "-i", input.path, "-c:a", "flac", "-metadata", "lyrics=[00:01.00]蓝色的歌", output.path])
        XCTAssertEqual(try tools.probe(url: output).embeddedLyrics, "[00:01.00]蓝色的歌")
    }
    func testLoudnessNormalizationProducesBoundedPCM() throws {
        let input = try Self.fixture(); defer { try? FileManager.default.removeItem(at: input) }
        let result = try tools.run(tool: "ffmpeg", arguments: tools.decodeArguments(url: input, offset: 0, sampleRate: 48000, normalize: true))
        XCTAssertEqual(result.data.count, 48000 * 2 * 4)
        let peak = result.data.withUnsafeBytes { raw -> Float in
            (0..<(raw.count / 4)).reduce(Float(0)) { max($0, abs(Float(bitPattern: raw.loadUnaligned(fromByteOffset: $1 * 4, as: UInt32.self)))) }
        }
        XCTAssertGreaterThan(peak, 0.02)
        XCTAssertLessThanOrEqual(peak, 1)
    }
    func testCancelledProcessDoesNotLaunchDecoder() throws {
        let cancellation = ProcessCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try tools.run(tool: "missing-tool", arguments: [], cancellation: cancellation)) { error in XCTAssertTrue(error is CancellationError) }
    }
    func testSelectedOutputRateAndPrecisionDecodeSuccessfully() throws {
        let input = try Self.fixture(); defer { try? FileManager.default.removeItem(at: input) }
        for bits in [16, 24, 32] {
            let result = try tools.run(tool: "ffmpeg", arguments: tools.decodeArguments(url: input, offset: 0, sampleRate: 44100, precision: bits))
            XCTAssertEqual(result.data.count, 44100 * 2 * 4)
        }
    }
    func test16BitQuantizationIsAppliedAfterResampling() throws {
        let input = try Self.fixture(); defer { try? FileManager.default.removeItem(at: input) }
        let result = try tools.run(tool: "ffmpeg", arguments: tools.decodeArguments(url: input, offset: 0, sampleRate: 44100, precision: 16))
        let offGrid = result.data.withUnsafeBytes { raw -> Int in
            (0..<(raw.count / 4)).filter { i in
                let sample = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) * 32768
                return abs(sample - sample.rounded()) > 0.00001
            }.count
        }
        XCTAssertEqual(offGrid, 0)
    }
}
