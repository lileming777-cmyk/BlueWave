import Foundation
@preconcurrency import AVFoundation
import BlueWaveCore
import Darwin

/// One session owns its process, buffers and cancellation. Old callbacks cannot advance a new track.
private final class DecodeSession: @unchecked Sendable {
    let process = Process()
    let output = Pipe()
    let slots: DispatchSemaphore
    let group = DispatchGroup()
    // Scheduling, playback control and stop share this lock, never the main executor.
    private let lock = NSLock()
    private let statisticsLock = NSLock()
    private let policy: PCMBufferPolicy
    private var cancelled = false
    private var paused = false
    private var started = false
    private var queuedFrames = 0
    private var scheduledFrames: Int64 = 0
    private var decodingEnded = false
    private var underruns = 0
    private var playbackStarted = false
    init(policy: PCMBufferPolicy) { self.policy = policy; slots = DispatchSemaphore(value: policy.bufferCount) }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var snapshot: AudioBufferSnapshot {
        statisticsLock.lock(); defer { statisticsLock.unlock() }
        return AudioBufferSnapshot(started: playbackStarted, queuedFrames: queuedFrames, scheduledFrames: scheduledFrames, underruns: underruns)
    }
    func pause(_ node: AVAudioPlayerNode) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }; paused = true; node.pause()
    }
    func resume(_ node: AVAudioPlayerNode) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }; paused = false
        if started { node.play() }
    }
    func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { slots.signal(); return false }
        let frames = Int(buffer.frameLength)
        group.enter()
        statisticsLock.lock(); queuedFrames += frames; scheduledFrames += Int64(frames); statisticsLock.unlock()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [self] _ in
            statisticsLock.lock()
            queuedFrames -= frames
            if queuedFrames == 0 && !decodingEnded { underruns += 1 }
            statisticsLock.unlock()
            slots.signal(); group.leave()
        }
        if !started && snapshot.scheduledFrames >= policy.prebufferFrames { start(node) }
        return true
    }
    private func start(_ node: AVAudioPlayerNode) {
        started = true
        statisticsLock.lock(); playbackStarted = true; statisticsLock.unlock()
        if !paused { node.play() }
    }
    func finishDecoding(_ node: AVAudioPlayerNode) {
        lock.lock(); defer { lock.unlock() }
        statisticsLock.lock(); decodingEnded = true; statisticsLock.unlock()
        if !cancelled && !started && snapshot.scheduledFrames > 0 { start(node) }
    }
    func cancel(stopping node: AVAudioPlayerNode? = nil) {
        lock.lock(); cancelled = true
        statisticsLock.lock(); decodingEnded = true; statisticsLock.unlock()
        // No old worker can append to this node after stop and reconnection.
        node?.stop()
        lock.unlock()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
    }
}

@MainActor final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var session: DecodeSession?
    private var configurationObserver: NSObjectProtocol?
    private var lastKnownPosition = 0.0
    private var startOffset = 0.0
    private var sampleRate = 48000.0
    var effectiveSampleRate: Double { sampleRate }
    private(set) var effectivePrecision = 32
    var hasSession: Bool { session != nil }
    var onOutputInterrupted: (() -> Void)?
    var isOutputRunning: Bool { engine.isRunning }
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    var volume: Float = 0.7 { didSet { node.volume = volume } }
    var position: Double {
        guard let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render), time.sampleRate > 0 else { return lastKnownPosition }
        lastKnownPosition = max(lastKnownPosition, startOffset + Double(time.sampleTime) / time.sampleRate)
        return lastKnownPosition
    }
    #if DEBUG
    // Test-only digital tap. Muting the final mixer keeps node samples measurable
    // without sending the verification signal to speakers or Bluetooth devices.
    func prepareSilentVerification() { engine.mainMixerNode.outputVolume = 0 }
    var verificationMixerVolume: Float { engine.mainMixerNode.outputVolume }
    func installVerificationTap(_ block: @escaping AVAudioNodeTapBlock) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil, block: block)
    }
    func removeVerificationTap() { node.removeTap(onBus: 0) }
    #endif
    init() {
        engine.attach(node)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // The notification can arrive on an audio thread. Rebuild on MainActor,
            // outside the engine callback, and ignore notifications from our own start.
            Task { @MainActor [weak self] in
                guard let self, self.hasSession, !self.engine.isRunning else { return }
                self.onOutputInterrupted?()
            }
        }
    }
    func pause() { session?.pause(node) }
    func resume() { session?.resume(node) }
    func stop() {
        if let session { session.cancel(stopping: node) } else { node.stop() }
        session = nil; engine.stop()
    }
    func play(track: Track, offset: Double, tools: MediaTools, normalize: Bool = false, outputRate: Int = 0, precision: Int = 32) throws {
        stop()
        guard FileManager.default.isReadableFile(atPath: track.path) else { throw MediaError("找不到音乐文件，请重新连接设备或检查文件位置") }
        startOffset = offset.isFinite ? max(0, offset) : 0
        lastKnownPosition = startOffset
        effectivePrecision = [16, 24, 32].contains(precision) ? precision : 32
        // DSD is converted to 176.4 kHz PCM; other high rates are bounded to 192 kHz.
        sampleRate = track.sampleRate > 768000 ? 176400 : Double(min(192000, max(8000, track.sampleRate > 0 ? track.sampleRate : 48000)))
        if [44100, 48000, 88200, 96000, 176400, 192000].contains(outputRate) { sampleRate = Double(outputRate) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { throw MediaError("无法建立音频输出格式") }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start(); node.volume = volume
        let policy = PCMBufferPolicy(sampleRate: sampleRate)
        let current = DecodeSession(policy: policy); session = current
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("bluewave-play-\(UUID()).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: log)
        current.process.executableURL = tools.executable("ffmpeg")
        current.process.arguments = tools.decodeArguments(url: track.url, offset: startOffset, sampleRate: Int(sampleRate), normalize: normalize, precision: precision)
        current.process.standardInput = FileHandle.nullDevice
        current.process.standardOutput = current.output
        current.process.standardError = errorHandle
        do { try current.process.run() } catch { stop(); try? errorHandle.close(); try? FileManager.default.removeItem(at: log); throw error }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, node] in
            defer { try? errorHandle.close(); try? current.output.fileHandleForReading.close(); try? FileManager.default.removeItem(at: log) }
            var chunks = PCMChunkAccumulator(bytesPerBuffer: policy.framesPerBuffer * 8)
            var produced = false; var ended = false
            do {
                while !current.isCancelled {
                    // A GCD worker can run for an entire album. Drain Foundation/AVFAudio
                    // temporary objects per read, rather than retaining them until EOF.
                    let keepReading = try autoreleasepool { () throws -> Bool in
                        if !ended {
                            let remaining = policy.framesPerBuffer * 8 - chunks.pendingByteCount
                            let block = try current.output.fileHandleForReading.read(upToCount: remaining) ?? Data()
                            ended = block.isEmpty
                            chunks.append(block)
                        }
                        guard let block = chunks.pop(ending: ended) else {
                            if ended { return false }
                            return true
                        }
                        let count = block.count / 8
                        while current.slots.wait(timeout: .now() + 0.05) == .timedOut { if current.isCancelled { return false } }
                        if current.isCancelled { current.slots.signal(); return false }
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channels = buffer.floatChannelData else {
                            current.slots.signal(); throw MediaError("音频缓冲区分配失败")
                        }
                        buffer.frameLength = AVAudioFrameCount(count)
                        block.withUnsafeBytes { raw in
                            for frame in 0..<count {
                                channels[0][frame] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 8, as: UInt32.self)))
                                channels[1][frame] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 8 + 4, as: UInt32.self)))
                            }
                        }
                        guard current.schedule(buffer, on: node) else { return false }
                        produced = true
                        return true
                    }
                    if !keepReading { break }
                }
                if current.isCancelled { return }
                current.finishDecoding(node)
                if current.isCancelled { return }
                current.process.waitUntilExit()
                if current.process.terminationStatus != 0 || !produced || chunks.pendingByteCount != 0 {
                    let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    throw MediaError("音频解码失败：\(track.title)\n" + String(diagnostic.suffix(500)))
                }
                while current.group.wait(timeout: .now() + 0.1) == .timedOut { if current.isCancelled { return } }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session === current, !current.isCancelled else { return }
                    // A configuration change can flush scheduled buffers and invoke
                    // completion callbacks. This is an interruption, not track EOF.
                    if !self.engine.isRunning { self.onOutputInterrupted?(); return }
                    self.onFinish?()
                }
            } catch {
                current.cancel()
                DispatchQueue.main.async { [weak self] in guard let self, self.session === current else { return }; self.stop(); self.onError?(error.localizedDescription) }
            }
        }
    }
    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }; if let session { session.cancel(stopping: node) } else { node.stop() }; engine.stop() }
}

/// Stereo Float32 blocks are sized by playback time, independently of pipe read sizes.
struct PCMBufferPolicy {
    let framesPerBuffer: Int
    let bufferCount = 6
    let prebufferFrames: Int64
    init(sampleRate: Double) {
        framesPerBuffer = max(1, Int((sampleRate * 0.25).rounded(.up)))
        prebufferFrames = Int64(sampleRate.rounded(.up))
    }
}
struct PCMChunkAccumulator {
    let bytesPerBuffer: Int
    private var pending = Data()
    var pendingByteCount: Int { pending.count }
    mutating func append(_ data: Data) { pending.append(data) }
    mutating func pop(ending: Bool) -> Data? {
        let size = ending ? min(bytesPerBuffer, pending.count / 8 * 8) : bytesPerBuffer
        guard size > 0, pending.count >= size else { return nil }
        let block = Data(pending.prefix(size))
        // Data.removeFirst leaves a view into its original allocation. Appending to
        // that view can retain/grow the entire consumed stream behind an empty view.
        if size == pending.count { pending = Data() }
        else {
            pending = pending.withUnsafeBytes { raw in
                Data(bytes: raw.baseAddress!.advanced(by: size), count: raw.count - size)
            }
        }
        return block
    }
}
struct AudioBufferSnapshot {
    let started: Bool
    let queuedFrames: Int
    let scheduledFrames: Int64
    /// Counts exhausted queued buffers before decoder EOF; a diagnostic, not acoustic proof.
    let underruns: Int
}
extension AudioPlayback {
    var bufferingSnapshot: AudioBufferSnapshot? { session?.snapshot }
}
