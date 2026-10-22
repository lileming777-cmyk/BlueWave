import XCTest
import Darwin
@preconcurrency import AVFoundation
import BlueWaveCore
@testable import BlueWave

#if DEBUG

/// Tap inspection runs on the audio callback, independently of the main executor.
private final class PCMContinuityMeter: @unchecked Sendable {
    struct Reading {
        let frames: Int64
        let signalSpan: Int64
        let nonzeroFrames: Int64
        let longestInteriorZeroRun: Int64
        let largestTimestampGap: Int64
        let sampleRate: Double
        let peak: Float
        let buffers: Int
    }
    private let lock = NSLock()
    private var frames: Int64 = 0
    private var firstSignal: Int64?
    private var lastSignal: Int64 = 0
    private var nonzeroFrames: Int64 = 0
    private var pendingZeros: Int64 = 0
    private var longestInteriorZeroRun: Int64 = 0
    private var expectedTimestamp: Int64?
    private var largestTimestampGap: Int64 = 0
    private var sampleRate: Double = 0
    private var peak: Float = 0
    private var buffers = 0
    func inspect(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        sampleRate = buffer.format.sampleRate; buffers += 1
        let count = Int(buffer.frameLength)
        if time.isSampleTimeValid {
            if let expectedTimestamp { largestTimestampGap = max(largestTimestampGap, abs(time.sampleTime - expectedTimestamp)) }
            expectedTimestamp = time.sampleTime + Int64(count)
        }
        for index in 0..<count {
            let amplitude = abs(channels[0][index])
            peak = max(peak, amplitude)
            if amplitude > 0.000001 {
                if firstSignal == nil { firstSignal = frames + Int64(index) }
                else { longestInteriorZeroRun = max(longestInteriorZeroRun, pendingZeros) }
                lastSignal = frames + Int64(index); nonzeroFrames += 1; pendingZeros = 0
            } else if firstSignal != nil { pendingZeros += 1 }
        }
        frames += Int64(count)
    }
    var reading: Reading {
        lock.lock(); defer { lock.unlock() }
        return Reading(frames: frames, signalSpan: firstSignal.map { lastSignal - $0 + 1 } ?? 0,
                       nonzeroFrames: nonzeroFrames, longestInteriorZeroRun: longestInteriorZeroRun,
                       largestTimestampGap: largestTimestampGap, sampleRate: sampleRate, peak: peak, buffers: buffers)
    }
}

final class AudioSoakTests: XCTestCase {
    private let rate = 192000
    private var tools: MediaTools {
        MediaTools(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor"))
    }
    /// Repeats a deterministic 480Hz waveform; no private audio and no network.
    private func fixture(seconds: Int, silence: Range<Int>? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("数字连续性-\(UUID()).wav")
        var header = Data()
        func str(_ text: String) { header.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        let byteCount = UInt32(seconds * rate * 4)
        str("RIFF"); u32(36 + byteCount); str("WAVEfmt "); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16); str("data"); u32(byteCount)
        try header.write(to: url)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd()
        var wave = Data(capacity: rate * 4)
        for frame in 0..<rate {
            var value = Int16(sin(Double(frame % 400) * 2 * .pi / 400) * 5000).littleEndian
            withUnsafeBytes(of: &value) { wave.append(contentsOf: $0); wave.append(contentsOf: $0) }
        }
        for second in 0..<seconds {
            if let silence, silence.overlaps(second * rate..<(second + 1) * rate) {
                var block = wave
                let start = max(0, silence.lowerBound - second * rate)
                let end = min(rate, silence.upperBound - second * rate)
                block.replaceSubrange(start * 4..<end * 4, with: Data(repeating: 0, count: (end - start) * 4))
                try file.write(contentsOf: block)
            } else { try file.write(contentsOf: wave) }
        }
        return url
    }
    private func report(_ message: String) {
        let data = Data((message + "\n").utf8)
        FileHandle.standardError.write(data)
        // SwiftPM may buffer XCTest output until completion; keep an immediate local log.
        let path = "/private/tmp/bluewave-audio-soak-progress.log"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    @MainActor private func blockMain(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    @MainActor private func verify(seconds: Int, silence: Range<Int>? = nil, normalize: Bool, stalls: [Double]) async throws -> PCMContinuityMeter.Reading {
        let url = try fixture(seconds: seconds, silence: silence)
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = AudioPlayback(); audio.prepareSilentVerification(); audio.volume = 1
        XCTAssertEqual(audio.verificationMixerVolume, 0, "The final mixer must be silent before starting the engine")
        defer { audio.removeVerificationTap(); audio.stop() }
        let meter = PCMContinuityMeter()
        var finished = false; var error: String?
        audio.onFinish = { finished = true }; audio.onError = { error = $0 }
        try audio.play(track: Track(path: url.path, title: "Synthetic continuity", sampleRate: rate), offset: 0, tools: tools, normalize: normalize)
        audio.installVerificationTap { buffer, time in meter.inspect(buffer, time: time) }
        XCTAssertEqual(audio.verificationMixerVolume, 0)
        let start = Date(); var pendingStalls = stalls; var maximumQueued = 0; var maximumUnderruns = 0
        let initialResident = residentBytes(); var peakResident = initialResident
        var nextReport = 15.0
        while !finished && error == nil && Date().timeIntervalSince(start) < Double(seconds) + 15 {
            let elapsed = Date().timeIntervalSince(start)
            if let next = pendingStalls.first, elapsed >= next {
                pendingStalls.removeFirst()
                report("SOAK main-block begin elapsed=\(elapsed)")
                blockMain(seconds: 1)
                report("SOAK main-block end elapsed=\(Date().timeIntervalSince(start))")
            }
            if let snapshot = audio.bufferingSnapshot {
                maximumQueued = max(maximumQueued, snapshot.queuedFrames)
                maximumUnderruns = max(maximumUnderruns, snapshot.underruns)
            }
            peakResident = max(peakResident, residentBytes())
            if elapsed >= nextReport {
                let reading = meter.reading
                report("SOAK progress elapsed=\(elapsed) signalFrames=\(reading.signalSpan) maxZero=\(reading.longestInteriorZeroRun) maxTimestampGap=\(reading.largestTimestampGap) rss=\(residentBytes()) queued=\(audio.bufferingSnapshot?.queuedFrames ?? -1)")
                nextReport += 15
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(error); XCTAssertTrue(finished, "Playback must complete naturally")
        XCTAssertTrue(pendingStalls.isEmpty)
        XCTAssertEqual(audio.verificationMixerVolume, 0)
        XCTAssertLessThanOrEqual(maximumQueued, rate * 3 / 2)
        XCTAssertEqual(maximumUnderruns, 0)
        XCTAssertGreaterThan(initialResident, 0)
        XCTAssertLessThanOrEqual(peakResident - initialResident, 64 * 1024 * 1024, "Retained audio buffers must not grow throughout the run")
        let reading = meter.reading
        report("SOAK result duration=\(seconds) normalize=\(normalize) frames=\(reading.frames) signalSpan=\(reading.signalSpan) nonzero=\(reading.nonzeroFrames) maxZero=\(reading.longestInteriorZeroRun) maxTimestampGap=\(reading.largestTimestampGap) peak=\(reading.peak) buffers=\(reading.buffers) maximumQueued=\(maximumQueued) underruns=\(maximumUnderruns) initialRSS=\(initialResident) peakRSS=\(peakResident)")
        XCTAssertEqual(reading.sampleRate, Double(rate))
        XCTAssertGreaterThan(reading.peak, 0.01)
        XCTAssertEqual(reading.signalSpan, Int64(seconds * rate), accuracy: Int64(rate / 10))
        XCTAssertLessThanOrEqual(reading.largestTimestampGap, Int64(rate / 50))
        return reading
    }
    @MainActor func test00DigitalTapPositiveAndNegativeControls() async throws {
        let clean = try await verify(seconds: 2, normalize: true, stalls: [])
        XCTAssertGreaterThan(clean.nonzeroFrames, Int64(rate * 19 / 10))
        XCTAssertLessThanOrEqual(clean.longestInteriorZeroRun, Int64(rate / 50))
        let intentionalGap = try await verify(seconds: 3, silence: rate..<(rate + rate / 10), normalize: false, stalls: [])
        XCTAssertGreaterThanOrEqual(intentionalGap.longestInteriorZeroRun, Int64(rate / 10 - 2), "A deliberately silent 100ms interior segment must fail the 20ms continuity threshold")
    }
    func test01ConsumedPCMChunksDoNotRetainTheStreamPrefix() {
        let payload = Data(repeating: 17, count: 64 * 1024)
        var chunks = PCMChunkAccumulator(bytesPerBuffer: payload.count)
        let initial = residentBytes(); var peak = initial
        for index in 0..<4096 {
            autoreleasepool {
                chunks.append(payload)
                let block = chunks.pop(ending: false)
                XCTAssertEqual(block?.count, payload.count)
                XCTAssertEqual(chunks.pendingByteCount, 0)
            }
            if index % 64 == 0 { peak = max(peak, residentBytes()) }
        }
        report("SOAK accumulator initialRSS=\(initial) peakRSS=\(peak)")
        XCTAssertLessThanOrEqual(peak - initial, 64 * 1024 * 1024, "Consuming chunks must release the prefix instead of growing storage with the whole stream")
    }
    @MainActor func test10NormalizedHighRate120SecondContinuityWithMainStalls() async throws {
        let reading = try await verify(seconds: 120, normalize: true, stalls: [15, 45, 75, 105])
        XCTAssertGreaterThan(reading.nonzeroFrames, Int64(120 * rate * 99 / 100))
        XCTAssertLessThanOrEqual(reading.longestInteriorZeroRun, Int64(rate / 50), "Unexpected interior silence exceeded 20ms")
    }
}

#endif
