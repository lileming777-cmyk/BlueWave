import XCTest
import BlueWaveCore
@testable import BlueWave

final class AudioBufferTests: XCTestCase {
    func testQueueCoversAtLeastOneSecondAtEveryOutputRateWithBoundedMemory() {
        for rate in [44100.0, 48000.0, 192000.0] {
            let policy = PCMBufferPolicy(sampleRate: rate)
            XCTAssertGreaterThanOrEqual(Double(policy.framesPerBuffer * policy.bufferCount) / rate, 1.0)
            XCTAssertEqual(Double(policy.framesPerBuffer) / rate, 0.25, accuracy: 1 / rate)
            XCTAssertGreaterThanOrEqual(Double(policy.prebufferFrames) / rate, 1.0)
            XCTAssertLessThanOrEqual(policy.framesPerBuffer * policy.bufferCount * 8, 3 * 1024 * 1024)
        }
    }
    func testShortPipeReadsAccumulateWholeBlocksAndPreserveFinalFrames() {
        var chunks = PCMChunkAccumulator(bytesPerBuffer: 32)
        chunks.append(Data(0..<3)); XCTAssertNil(chunks.pop(ending: false))
        chunks.append(Data(3..<17)); XCTAssertNil(chunks.pop(ending: false))
        chunks.append(Data(17..<43))
        XCTAssertEqual(chunks.pop(ending: false), Data(0..<32))
        XCTAssertNil(chunks.pop(ending: false))
        XCTAssertEqual(chunks.pop(ending: true), Data(32..<40))
        XCTAssertEqual(chunks.pendingByteCount, 3, "An incomplete stereo float frame must not be fabricated")
        XCTAssertNil(chunks.pop(ending: true))
    }
    @MainActor private func blockMainThread(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    @MainActor func testHighRateQueueRefillsWhileMainThreadIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("音频缓冲压力-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MediaTools(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor"))
        let url = root.appendingPathComponent("合成192k.wav")
        var bytes = Data()
        func str(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var word = value.littleEndian; withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var word = value.littleEndian; withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) } }
        let sampleBytes: UInt32 = 192000 * 4 * 2 * 2
        str("RIFF"); u32(36 + sampleBytes); str("WAVEfmt "); u32(16); u16(1); u16(2)
        u32(192000); u32(192000 * 4); u16(4); u16(16); str("data"); u32(sampleBytes)
        bytes.append(Data(repeating: 0, count: Int(sampleBytes)))
        try bytes.write(to: url)
        let track = Track(path: url.path, title: "Synthetic", sampleRate: 192000)
        let audio = AudioPlayback(); audio.volume = 0
        defer { audio.stop() }
        var errors: [String] = []; var finished = false
        audio.onError = { errors.append($0) }; audio.onFinish = { finished = true }
        try audio.play(track: track, offset: 0, tools: tools)
        for _ in 0..<200 {
            if let snapshot = audio.bufferingSnapshot, snapshot.started && snapshot.queuedFrames >= 240000 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let before = try XCTUnwrap(audio.bufferingSnapshot)
        XCTAssertTrue(before.started); XCTAssertGreaterThanOrEqual(before.queuedFrames, 192000)
        // Block for longer than the old six 32KB slots can cover at 192kHz.
        blockMainThread(seconds: 0.6)
        let after = try XCTUnwrap(audio.bufferingSnapshot)
        XCTAssertGreaterThan(after.scheduledFrames, before.scheduledFrames, "The decoder must refill without running the main executor")
        XCTAssertGreaterThanOrEqual(after.queuedFrames, 192000)
        XCTAssertEqual(after.underruns, 0)
        XCTAssertFalse(finished); XCTAssertTrue(errors.isEmpty)
        audio.pause(); let paused = audio.position
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(audio.position, paused, accuracy: 0.03)
        audio.resume()
    }
    @MainActor func testPauseDuringPrebufferingKeepsShortTrackPausedUntilResume() async throws {
        let url = try MediaTests.fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let tools = MediaTools(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor"))
        let audio = AudioPlayback(); audio.volume = 0; defer { audio.stop() }
        var finished = false; audio.onFinish = { finished = true }
        try audio.play(track: Track(path: url.path, sampleRate: 48000), offset: 0.8, tools: tools)
        audio.pause()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(audio.position, 0.8, accuracy: 0.03); XCTAssertFalse(finished)
        audio.resume()
        for _ in 0..<200 { if finished { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(finished, "position=\(audio.position), queued=\(audio.bufferingSnapshot?.queuedFrames ?? -1), started=\(audio.bufferingSnapshot?.started ?? false)")
    }
    @MainActor func testDecoderFailureReportsErrorAndClearsSession() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("损坏音频-\(UUID()).wav")
        try Data("invalid audio".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let tools = MediaTools(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor"))
        let audio = AudioPlayback(); audio.volume = 0; defer { audio.stop() }
        var error: String?; var finished = false
        audio.onError = { error = $0 }; audio.onFinish = { finished = true }
        try audio.play(track: Track(path: url.path, title: "Synthetic invalid audio"), offset: 0, tools: tools)
        for _ in 0..<200 { if error != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(error); XCTAssertFalse(finished); XCTAssertFalse(audio.hasSession)
    }

}
