import XCTest
import BlueWaveCore
@testable import BlueWave

final class SessionTests: XCTestCase {
    // Removing session save/restore must lose the selected song and offset on relaunch.
    @MainActor func testRelaunchRestoresSongProgressAndQueueWithoutStartingAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.json")
        let first = Track(path: folder.appendingPathComponent("first.wav").path, duration: 180)
        let second = Track(path: folder.appendingPathComponent("second.wav").path, duration: 240)
        let model = PlayerModel(storeURL: url, enableMediaCommands: false)
        model.store.add([first, second]); model.refresh()
        model.currentID = second.id; model.position = 73.5; model.queue = [second.id, first.id]
        model.persist()
        let reopened = PlayerModel(storeURL: url, enableMediaCommands: false)
        XCTAssertEqual(reopened.currentID, second.id)
        XCTAssertEqual(reopened.position, 73.5, accuracy: 0.01)
        XCTAssertEqual(reopened.queue, [second.id, first.id])
        XCTAssertFalse(reopened.playing)
        XCTAssertFalse(reopened.audio.hasSession)
    }
    @MainActor func testRestoredPlayStartsAtSavedOffsetAndTerminationKeepsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audioFile = try MediaTests.fixture()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: audioFile) }
        let url = folder.appendingPathComponent("library.json")
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor")
        let track = Track(path: audioFile.path, duration: 1)
        let original = PlayerModel(storeURL: url, toolsDirectory: tools, enableMediaCommands: false)
        original.store.add([track]); original.refresh()
        original.currentID = track.id; original.position = 0.4; original.persist()
        let reopened = PlayerModel(storeURL: url, toolsDirectory: tools, enableMediaCommands: false)
        reopened.volume = 0
        reopened.togglePlay()
        defer { reopened.audio.stop() }
        XCTAssertTrue(reopened.playing)
        XCTAssertTrue(reopened.audio.hasSession)
        XCTAssertGreaterThanOrEqual(reopened.audio.position, 0.4)
        XCTAssertLessThan(reopened.audio.position, 0.9)
        reopened.prepareForTermination()
        let nextLaunch = PlayerModel(storeURL: url, enableMediaCommands: false)
        XCTAssertEqual(nextLaunch.currentID, track.id)
        XCTAssertGreaterThanOrEqual(nextLaunch.position, 0.4)
        XCTAssertFalse(nextLaunch.playing)
    }

    @MainActor func testRemovedTrackIsNotRestoredAndStaleQueueEntriesAreDiscarded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.json")
        let first = Track(path: folder.appendingPathComponent("first.wav").path, duration: 30)
        let removed = Track(path: folder.appendingPathComponent("removed.wav").path, duration: 30)
        let model = PlayerModel(storeURL: url, enableMediaCommands: false)
        model.store.add([first, removed]); model.refresh()
        model.currentID = first.id; model.position = 900; model.queue = [removed.id, first.id, first.id]; model.persist()
        model.store.remove([removed.id]); try model.store.save()
        let reopened = PlayerModel(storeURL: url, enableMediaCommands: false)
        XCTAssertEqual(reopened.queue, [first.id])
        XCTAssertEqual(reopened.position, 30)
        reopened.store.remove([first.id]); try reopened.store.save()
        let empty = PlayerModel(storeURL: url, enableMediaCommands: false)
        XCTAssertNil(empty.currentID); XCTAssertEqual(empty.position, 0); XCTAssertTrue(empty.queue.isEmpty)
    }

}
