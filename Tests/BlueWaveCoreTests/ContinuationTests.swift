import XCTest
import AVFAudio
import BlueWaveCore
@testable import BlueWave

final class ContinuationTests: XCTestCase {
    private let tools = MediaTools(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor"))

    @MainActor private func setup() throws -> (PlayerModel, [Track], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try MediaTests.fixture(); defer { try? FileManager.default.removeItem(at: source) }
        let long = root.appendingPathComponent("a.wav")
        _ = try tools.run(tool: "ffmpeg", arguments: ["-v", "error", "-stream_loop", "9", "-i", source.path, "-c:a", "copy", long.path])
        var tracks = [try tools.probe(url: long)]
        for name in ["b.wav", "c.wav"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.copyItem(at: long, to: url)
            tracks.append(try tools.probe(url: url))
        }
        let model = PlayerModel(storeURL: root.appendingPathComponent("library.json"), toolsDirectory: tools.directory, enableMediaCommands: false)
        model.store.add(tracks); model.refresh(); model.volume = 0
        return (model, tracks, root)
    }

    @MainActor func testSubsetEndContinuesWithWholeLibraryIgnoringViewFilters() throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.section = "favorites"; model.search = "no matching song"
        model.currentID = t[2].id; model.queue = [t[1].id, t[2].id]
        model.advance(automatic: true)
        XCTAssertEqual(model.queue, model.tracks.map(\.id))
        XCTAssertEqual(model.currentID, t[0].id)
        XCTAssertTrue(model.playing)
    }

    @MainActor func testSubsetEndingOnFirstLibraryTrackAvoidsImmediateRepeat() throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.currentID = t[0].id; model.queue = [t[0].id]
        model.advance(automatic: true)
        XCTAssertEqual(model.currentID, t[1].id)
    }

    @MainActor func testFullLibraryEndStopsAndManualNextDoesNotExpandSubset() throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.currentID = t[2].id; model.queue = t.map(\.id); model.playing = true
        model.advance(automatic: true)
        XCTAssertFalse(model.playing); XCTAssertEqual(model.currentID, t[2].id)
        model.queue = [t[2].id]; model.advance()
        XCTAssertEqual(model.queue, [t[2].id]); XCTAssertFalse(model.playing)
    }

    @MainActor func testRepeatModesKeepPriorityOverLibraryContinuation() throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        for mode in [1, 2] {
            model.currentID = t[2].id; model.queue = [t[1].id, t[2].id]; model.repeatMode = mode
            model.advance(automatic: true)
            XCTAssertEqual(model.currentID, mode == 1 ? t[1].id : t[2].id)
            XCTAssertEqual(model.queue, [t[1].id, t[2].id])
            model.stop()
        }
    }

    // Stop the actual engine then send the same public notification as a hardware
    // reconfiguration. No output-device settings or microphone access are changed.
    @MainActor private func interrupt(_ audio: AudioPlayback) throws {
        let engine = try XCTUnwrap(Mirror(reflecting: audio).children.first { $0.label == "engine" }?.value as? AVAudioEngine)
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    @MainActor func testOutputInterruptionResumesSameSongAndOffsetWithoutAdvancing() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.play(t[0], within: t); model.seek(2)
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = model.audio.position
        try interrupt(model.audio)
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertEqual(model.currentID, t[0].id)
        XCTAssertEqual(model.queue, t.map(\.id))
        XCTAssertTrue(model.playing)
        XCTAssertGreaterThan(model.audio.position, before + 0.05)
        XCTAssertLessThan(model.audio.position, before + 1.2)
    }

    @MainActor func testPausedOutputInterruptionKeepsOffsetAndCanManuallyResume() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.play(t[0]); model.seek(2); model.togglePlay()
        let before = model.audio.position
        try interrupt(model.audio)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(model.playing)
        XCTAssertEqual(model.position, before, accuracy: 0.06)
        model.togglePlay()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.playing)
        XCTAssertGreaterThan(model.audio.position, before + 0.04)
    }

    @MainActor func testStopOrManualPauseDuringRecoveryCancelsAutomaticRestart() async throws {
        for stop in [true, false] {
            let (model, t, root) = try setup()
            model.play(t[0]); model.seek(2)
            try await Task.sleep(nanoseconds: 100_000_000)
            try interrupt(model.audio)
            try await Task.sleep(nanoseconds: 100_000_000)
            if stop { model.stop() } else { model.togglePlay() }
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertFalse(model.playing)
            if stop { XCTAssertFalse(model.audio.hasSession); XCTAssertEqual(model.position, 0) }
            else { XCTAssertGreaterThanOrEqual(model.position, 2) }
            model.stop(); try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor func testRepeatedInterruptionAndChangingTrackDoNotRestoreOldSong() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.play(t[0], within: t); model.seek(2)
        try interrupt(model.audio); try interrupt(model.audio)
        try await Task.sleep(nanoseconds: 100_000_000)
        model.play(t[1])
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(model.currentID, t[1].id)
        XCTAssertTrue(model.playing); XCTAssertLessThan(model.audio.position, 1.3)
    }
    @MainActor func testCrossfadeOutgoingInterruptionKeepsIncomingSong() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.crossfadeEnabled = true; model.crossfadeDuration = 2
        model.play(t[0], within: t); model.seek(8.2); model.checkCrossfade()
        XCTAssertTrue(model.transitioning); XCTAssertEqual(model.currentID, t[1].id)
        let outgoing = try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == "fadingAudio" }?.value as? AudioPlayback)
        try interrupt(outgoing)
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertFalse(model.transitioning); XCTAssertTrue(model.playing)
        XCTAssertEqual(model.currentID, t[1].id)
        XCTAssertGreaterThan(model.audio.position, 0.05)
    }

    @MainActor func testSeekDuringRecoveryCancelsOldOffset() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.play(t[0]); model.seek(2)
        try interrupt(model.audio)
        try await Task.sleep(nanoseconds: 100_000_000)
        model.seek(5)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(model.playing); XCTAssertEqual(model.currentID, t[0].id)
        XCTAssertGreaterThan(model.audio.position, 5.1)
    }

    @MainActor func testRecoveryRetriesTemporaryFailureAndRetainsSong() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.play(t[0]); model.seek(2)
        let data = try Data(contentsOf: t[0].url)
        try interrupt(model.audio)
        try FileManager.default.removeItem(at: t[0].url)
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(model.playing); XCTAssertFalse(model.audio.hasSession)
        try data.write(to: t[0].url)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(model.audio.hasSession); XCTAssertEqual(model.currentID, t[0].id)
        XCTAssertGreaterThan(model.audio.position, 2.05)
    }

    @MainActor func testExhaustedRecoveryPreservesOffsetForManualResume() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.play(t[0]); model.seek(2)
        let data = try Data(contentsOf: t[0].url)
        try interrupt(model.audio)
        try FileManager.default.removeItem(at: t[0].url)
        for _ in 0..<340 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !model.playing { break }
        }
        XCTAssertFalse(model.playing); XCTAssertNotNil(model.error)
        XCTAssertGreaterThanOrEqual(model.position, 2)
        XCTAssertEqual(model.currentID, t[0].id)
        try data.write(to: t[0].url)
        model.togglePlay()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(model.playing); XCTAssertGreaterThan(model.audio.position, 2.05)
    }

    @MainActor func testNaturalSubsetCompletionCallsContinuation() async throws {
        let (model, t, root) = try setup()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        model.play(t[2], within: [t[2]]); model.seek(9.7)
        try await Task.sleep(nanoseconds: 950_000_000)
        XCTAssertEqual(model.currentID, t[0].id)
        XCTAssertEqual(model.queue, t.map(\.id)); XCTAssertTrue(model.playing)
    }

}
