import AVFoundation
import os
import Foundation

#if os(macOS)
import CoreAudio
#endif

/// Non-actor-isolated audio capture helper
/// AVAudioEngine callbacks work better without MainActor isolation
final class AudioCaptureHelper: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var outputContinuation: AsyncStream<AudioData>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?

    private(set) var isRunning = false

    #if os(macOS)
    /// Set while a device carrying a system-audio tap is read directly. See
    /// `startCombinedCapture`.
    private var ioProcID: AudioDeviceIOProcID?
    private var ioDevice = AudioDeviceID(kAudioObjectUnknown)
    private var silenceWatch: DispatchSourceTimer?

    /// Where a combined device's audio arrives. Not the capture queue: stopping a
    /// device from the queue its own callbacks run on deadlocks.
    private static let ioQueue = DispatchQueue(label: "com.nscribe.audio-io", qos: .userInteractive)
    #endif

    /// Where every start and stop runs: off the main thread, and one at a time.
    ///
    /// Starting the engine takes 39–44 ms with the built-in microphone and can take far
    /// longer with a Bluetooth one, and it used to run on the main thread, freezing
    /// the app for as long as the device took. Serial, so a stop always finishes before
    /// the next start touches the device.
    private static let queue = DispatchQueue(label: "com.nscribe.audio-capture", qos: .userInitiated)

    init() {}

    /// `startCapture`, run on the capture queue.
    func start(preferredDeviceUID: String = "default") async throws -> AsyncStream<AudioData> {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: try self.startCapture(preferredDeviceUID: preferredDeviceUID))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `stopCapture`, run on the capture queue, waiting until it has finished.
    func stop() async {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                self.stopCapture()
                continuation.resume()
            }
        }
    }

    /// `stopCapture`, run on the capture queue, without waiting.
    ///
    /// For paths that cannot wait. The queue is serial, so a start that follows still
    /// finds the device released.
    func stopSoon() {
        Self.queue.async { self.stopCapture() }
    }

    /// Start capturing audio and return a stream of audio buffers
    /// - Parameter preferredDeviceUID: CoreAudio UID of the microphone to record from,
    ///   or "default" to follow the system setting.
    func startCapture(preferredDeviceUID: String = "default") throws -> AsyncStream<AudioData> {
        Log.audio.notice("Starting capture...")

        #if os(iOS)
        // Setup iOS audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        Log.audio.notice("iOS audio session configured")
        #endif

        #if os(macOS)
        if let device = AudioDeviceCatalog.resolveDeviceID(uid: preferredDeviceUID),
           Self.tapCount(of: device) > 0 {
            return try startCombinedCapture(device: device)
        }
        #endif

        // Create fresh engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Reset to clean state
        engine.reset()

        let inputNode = engine.inputNode

        #if os(macOS)
        // Must happen before the format is read: changing the device changes the
        // format, and a tap installed against the old one gets silence.
        selectInputDevice(uid: preferredDeviceUID, on: inputNode)
        #endif

        let format = inputNode.outputFormat(forBus: 0)

        Log.audio.notice("Input format: \(format, privacy: .public)")

        // A denied microphone does not raise an error here; the input node simply
        // reports a zero sample rate. Saying so beats "invalid format", which sends
        // the user looking at audio settings rather than at privacy settings.
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            Log.audio.error("Input format is \(format, privacy: .public) — microphone access is probably denied")
            throw AudioCaptureError.microphoneUnavailable
        }

        // Create stream with makeStream for immediate continuation
        let (stream, continuation) = AsyncStream<AudioData>.makeStream(bufferingPolicy: .unbounded)
        self.outputContinuation = continuation

        // Install tap
        // Counted under a lock: the tap writes it on the audio thread, and the
        // configuration check below reads it from the capture queue.
        let tapCount = OSAllocatedUnfairLock(initialState: 0)
        // The size asked for is a request, and macOS does not honour it: every buffer
        // logged has held 4,800 frames, a tenth of a second at 48 kHz, whatever was
        // asked. The level band therefore changes ten times a second.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: format
        ) { [weak self] buffer, time in
            let count = tapCount.withLock { $0 += 1; return $0 }
            if count <= 5 {
                Log.audio.notice("Tap callback #\(count, privacy: .public), frames: \(buffer.frameLength, privacy: .public)")
            }
            let audioData = AudioData(buffer: buffer, time: time)
            self?.outputContinuation?.yield(audioData)
        }
        Log.audio.notice("Tap installed")

        // A change of input device — AirPods connecting, a USB microphone unplugged —
        // stops the engine without an error, and the tap simply goes quiet. Ending the
        // stream turns that silence into something the engine can see and report.
        //
        // Only once the tap has actually gone quiet. The meeting's aggregate device
        // announces a configuration change 20–60 ms after every start, and the audio
        // carries on through it; ending the stream on the announcement alone paused
        // every meeting before its first word, blaming a microphone that never changed.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Counted from when the capture queue is free, not from the change. The
            // iPhone's microphone takes 2–3 s to start and announces a change during
            // the start; counted from then, the half second had passed before the
            // first buffer, and every dictation on the iPhone ended as it began.
            //
            // Eight seconds while nothing has arrived yet. The iPhone's first buffer can
            // come later than half a second after the engine reports itself started,
            // and a dictation on it ended before its first word. A device that has been
            // delivering and stops is still caught within half a second.
            Self.queue.async {
                let before = tapCount.withLock { $0 }
                let wait: TimeInterval = before == 0 ? 8 : 0.5
                Self.queue.asyncAfter(deadline: .now() + wait) {
                    guard let self, self.audioEngine === engine else { return }
                    let after = tapCount.withLock { $0 }
                    guard after == before else {
                        Log.audio.notice("Audio configuration changed; \(after - before, privacy: .public) buffers since, carrying on")
                        return
                    }
                    Log.audio.error("Audio configuration changed and the tap went quiet — ending the stream")
                    self.outputContinuation?.finish()
                }
            }
        }

        // Start engine
        engine.prepare()
        try engine.start()
        isRunning = engine.isRunning
        Log.audio.notice("Engine started, running: \(self.isRunning, privacy: .public)")

        return stream
    }

    #if os(macOS)
    /// Read a meeting's combined device, the microphone plus a system-audio tap,
    /// directly through Core Audio.
    ///
    /// AVAudioEngine reads only a device's first input stream. In the combined device
    /// that is the microphone, and the tap arrives as a second stream the engine
    /// never sees, so the other side of a call was never recorded: a sound played
    /// through the speakers measured the same with the tap as without it. Read here,
    /// the tap's stream carries it directly (level 0 when quiet, 0.13 during a test
    /// sound), as it does in every working system-audio recorder found.
    ///
    /// The buffers handed on have two channels, the microphone on the left and the
    /// system audio on the right, a tenth of a second each as the engine's were.
    /// Transcription and speaker separation mix them down; the saved recording keeps
    /// the two sides apart.
    private func startCombinedCapture(device: AudioDeviceID) throws -> AsyncStream<AudioData> {
        // Sub-devices' streams come first and taps' after, in the order they were
        // added to the device.
        let channels = Self.inputChannelsPerStream(of: device)
        let tapStreams = Self.tapCount(of: device)
        guard channels.count > tapStreams, Self.inputStreamsAreFloat32(device),
              let rate = Self.nominalSampleRate(of: device), rate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 2, interleaved: false) else {
            Log.audio.error("Combined device has streams \(channels, privacy: .public), which cannot be read")
            throw AudioCaptureError.invalidFormat
        }
        let microphone = 0..<(channels.count - tapStreams)
        let system = (channels.count - tapStreams)..<channels.count
        Log.audio.notice("Recording combined device: \(channels, privacy: .public) channels per stream at \(rate, privacy: .public) Hz")

        let (stream, continuation) = AsyncStream<AudioData>.makeStream(bufferingPolicy: .unbounded)
        outputContinuation = continuation

        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let firstAudio = DispatchSemaphore(value: 0)
        let chunk = ChunkBuilder(format: format, frames: AVAudioFrameCount(rate / 10))

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, Self.ioQueue) { [weak self] _, input, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard list.count == channels.count else { return }
            chunk.append(list, microphone: microphone, system: system, time: inputTime.pointee) { buffer, time in
                let count = delivered.withLock { $0 += 1; return $0 }
                if count == 1 { firstAudio.signal() }
                if count <= 5 {
                    Log.audio.notice("Combined buffer #\(count, privacy: .public), frames: \(buffer.frameLength, privacy: .public)")
                }
                self?.outputContinuation?.yield(AudioData(buffer: buffer, time: time))
            }
        }
        guard status == noErr, let procID else {
            Log.audio.error("Could not attach to the combined device, OSStatus \(status, privacy: .public)")
            throw AudioCaptureError.engineNotRunning
        }
        ioProcID = procID
        ioDevice = device

        let started = Date()
        let startStatus = AudioDeviceStart(device, procID)
        guard startStatus == noErr else {
            Log.audio.error("Could not start the combined device, OSStatus \(startStatus, privacy: .public)")
            stopCapture()
            throw AudioCaptureError.engineNotRunning
        }

        // Returned only once audio is arriving, as a plain device's start does. The
        // built-in microphone delivers in about 0.05 s; the iPhone's takes up to 4 s.
        guard firstAudio.wait(timeout: .now() + 10) == .success else {
            Log.audio.error("The combined device started but sent no audio for 10 s")
            stopCapture()
            throw AudioCaptureError.noAudio
        }
        Log.audio.notice("First audio \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s after start")
        isRunning = true

        // A sub-device that goes away mid-meeting, AirPods connecting or a USB
        // microphone unplugged, stops the device's callbacks without an error. A
        // second with no buffer ends the stream, so the engine sees it and reports it.
        let watch = DispatchSource.makeTimerSource(queue: Self.queue)
        var seen = delivered.withLock { $0 }
        watch.schedule(deadline: .now() + 1, repeating: 1)
        watch.setEventHandler { [weak self] in
            let now = delivered.withLock { $0 }
            defer { seen = now }
            guard now == seen, let self, self.ioProcID != nil else { return }
            Log.audio.error("The combined device stopped sending audio — ending the stream")
            self.silenceWatch?.cancel()
            self.silenceWatch = nil
            self.outputContinuation?.finish()
        }
        watch.resume()
        silenceWatch = watch

        return stream
    }

    /// Point the engine's input at a specific microphone.
    ///
    /// Silently leaves the system default in place when the device has been unplugged,
    /// which beats refusing to record at all.
    private func selectInputDevice(uid: String, on inputNode: AVAudioInputNode) {
        guard uid != AudioInputDevice.systemDefaultUID else { return }

        // Resolved by UID rather than looked up in the device list: the meeting input
        // is a private aggregate, which deliberately does not appear there.
        guard let resolvedID = AudioDeviceCatalog.resolveDeviceID(uid: uid) else {
            Log.audio.notice("Device \(uid, privacy: .public) not connected, using system default")
            return
        }
        let deviceName = AudioDeviceCatalog.device(forUID: uid)?.name ?? uid

        guard let audioUnit = inputNode.audioUnit else {
            Log.audio.error("No audio unit on the input node")
            return
        }

        var deviceID = resolvedID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status == noErr {
            Log.audio.notice("Recording from \(deviceName, privacy: .public)")
        } else {
            Log.audio.error("Could not select \(deviceName, privacy: .public), OSStatus \(status, privacy: .public)")
        }
    }
    #endif

    /// Stop capturing audio
    func stopCapture() {
        Log.audio.notice("Stopping capture...")

        #if os(macOS)
        if let procID = ioProcID {
            silenceWatch?.cancel()
            silenceWatch = nil
            // Stopped before the stream is finished: once AudioDeviceStop returns, no
            // callback can yield into a finished stream.
            AudioDeviceStop(ioDevice, procID)
            AudioDeviceDestroyIOProcID(ioDevice, procID)
            ioProcID = nil
            ioDevice = AudioDeviceID(kAudioObjectUnknown)
            outputContinuation?.finish()
            outputContinuation = nil
            isRunning = false
            Log.audio.notice("Capture stopped")
            return
        }
        #endif

        guard let engine = audioEngine else {
            Log.audio.notice("No engine to stop")
            return
        }

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            Log.audio.notice("iOS audio session deactivated")
        } catch {
            Log.audio.error("Warning: Failed to deactivate audio session: \(error, privacy: .public)")
        }
        #endif

        outputContinuation?.finish()
        outputContinuation = nil
        audioEngine = nil
        isRunning = false

        Log.audio.notice("Capture stopped")
    }

    deinit {
        // A safety net only. Teardown is explicit everywhere it matters, because
        // AVAudioEngine.stop() blocks and deinit runs on whichever thread drops the
        // last reference — which was once the main thread, mid-hotkey.
        #if os(macOS)
        let live = audioEngine != nil || ioProcID != nil
        #else
        let live = audioEngine != nil
        #endif
        if live {
            Log.audio.error("deinit found a live engine — teardown was missed")
            stopCapture()
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case invalidFormat
    case microphoneUnavailable
    case engineNotRunning
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "The audio input format could not be used."
        case .microphoneUnavailable:
            "No microphone input. Grant Nscribe microphone access in System Settings → Privacy & Security → Microphone."
        case .engineNotRunning:
            "The audio engine is not running."
        case .noAudio:
            "The microphone started but sent no audio for 10 seconds. If it is an iPhone, check that it is nearby and unlocked."
        }
    }
}

#if os(macOS)
// MARK: - Combined device reading

extension AudioCaptureHelper {
    /// How many system-audio taps a device carries. Zero for any ordinary microphone.
    static func tapCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return 0 }
        var list: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &list) == noErr,
              let taps = list?.takeRetainedValue() else { return 0 }
        return CFArrayGetCount(taps)
    }

    /// The channel count of each input stream, in stream order.
    static func inputChannelsPerStream(of device: AudioDeviceID) -> [Int] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Whether every input stream hands over 32-bit float samples, the only kind the
    /// mixing below reads.
    static func inputStreamsAreFloat32(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return false }
        return streams.allSatisfy { stream in
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var description = AudioStreamBasicDescription()
            var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &descriptionSize, &description) == noErr else { return false }
            return description.mFormatID == kAudioFormatLinearPCM
                && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && description.mBitsPerChannel == 32
                && description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        }
    }

    static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }
}

/// Gathers a combined device's small callbacks into buffers of a tenth of a second.
///
/// Touched only on the device's IO queue, one callback at a time.
private final class ChunkBuilder: @unchecked Sendable {
    private let format: AVAudioFormat
    private let frames: AVAudioFrameCount
    private var pending: AVAudioPCMBuffer?
    private var pendingTime: AVAudioTime?

    init(format: AVAudioFormat, frames: AVAudioFrameCount) {
        self.format = format
        self.frames = frames
    }

    /// Mix one callback's streams into two channels and hand on every buffer it fills.
    func append(
        _ list: UnsafeMutableAudioBufferListPointer,
        microphone: Range<Int>,
        system: Range<Int>,
        time: AudioTimeStamp,
        deliver: (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        let available = list.map { buffer in
            Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(Int(buffer.mNumberChannels), 1))
        }
        guard let total = available.min(), total > 0 else { return }

        var offset = 0
        while offset < total {
            if pending == nil {
                pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
                pendingTime = AVAudioTime(hostTime: time.mHostTime)
            }
            guard let buffer = pending, let out = buffer.floatChannelData, let bufferTime = pendingTime else { return }
            let start = Int(buffer.frameLength)
            let count = min(total - offset, Int(frames) - start)
            Self.mix(list, streams: microphone, frames: offset..<(offset + count), into: out[0] + start)
            Self.mix(list, streams: system, frames: offset..<(offset + count), into: out[1] + start)
            buffer.frameLength += AVAudioFrameCount(count)
            offset += count
            if buffer.frameLength == frames {
                pending = nil
                deliver(buffer, bufferTime)
            }
        }
    }

    /// The mean of every channel in `streams`, frame by frame. Each stream is
    /// interleaved 32-bit float.
    private static func mix(
        _ list: UnsafeMutableAudioBufferListPointer,
        streams: Range<Int>,
        frames: Range<Int>,
        into destination: UnsafeMutablePointer<Float>
    ) {
        let channelTotal = streams.reduce(0) { $0 + Int(list[$1].mNumberChannels) }
        guard channelTotal > 0 else {
            destination.update(repeating: 0, count: frames.count)
            return
        }
        let scale = 1 / Float(channelTotal)
        for (i, frame) in frames.enumerated() {
            var sum: Float = 0
            for index in streams {
                let buffer = list[index]
                let channels = Int(buffer.mNumberChannels)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for channel in 0..<channels { sum += data[frame * channels + channel] }
            }
            destination[i] = sum * scale
        }
    }
}
#endif
