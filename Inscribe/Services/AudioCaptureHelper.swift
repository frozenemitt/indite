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

    /// Where every start and stop runs: off the main thread, and one at a time.
    ///
    /// Starting the engine takes 39–44 ms with the built-in microphone and can take far
    /// longer with a Bluetooth one, and it used to run on the main thread, freezing
    /// the app for as long as the device took. Serial, so a stop always finishes before
    /// the next start touches the device.
    private static let queue = DispatchQueue(label: "com.inscribe.audio-capture", qos: .userInitiated)

    init() {}

    /// `startCapture`, run on the capture queue.
    func start(preferredDeviceUID: String = "default", waitForAudio: Bool = false) async throws -> AsyncStream<AudioData> {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: try self.startCapture(
                        preferredDeviceUID: preferredDeviceUID,
                        waitForAudio: waitForAudio
                    ))
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
    /// - Parameters:
    ///   - preferredDeviceUID: CoreAudio UID of the microphone to record from, or
    ///     "default" to follow the system setting.
    ///   - waitForAudio: Return only once the first buffer has arrived. For a
    ///     meeting's combined device, which reports itself started seconds before its
    ///     microphone delivers anything.
    func startCapture(preferredDeviceUID: String = "default", waitForAudio: Bool = false) throws -> AsyncStream<AudioData> {
        Log.audio.notice("Starting capture...")

        #if os(iOS)
        // Setup iOS audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        Log.audio.notice("iOS audio session configured")
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
        let firstBuffer = DispatchSemaphore(value: 0)
        // The size asked for is a request, and macOS does not honour it: every buffer
        // logged has held 4,800 frames, a tenth of a second at 48 kHz, whatever was
        // asked. The level band therefore changes ten times a second.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: format
        ) { [weak self] buffer, time in
            let count = tapCount.withLock { $0 += 1; return $0 }
            if count == 1 { firstBuffer.signal() }
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
            // Eight seconds while nothing has arrived yet. The meeting's combined
            // device, built around the iPhone's microphone, reports itself started at
            // once and delivers its first buffer up to 4.4 s later; half a second
            // paused every such meeting before its first word. A device that has
            // been delivering and stops is still caught within half a second.
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

        // A meeting built around the iPhone's microphone started, played its sound
        // and said "Recording" 4.7–6.1 s before the first buffer, and everything said
        // in between was lost. Dictation never had the gap: starting the plain device
        // blocks until it is live. Waiting here gives meetings the same guarantee.
        if waitForAudio {
            let started = Date()
            guard firstBuffer.wait(timeout: .now() + 8) == .success else {
                Log.audio.error("No audio 8 s after starting — giving up")
                stopCapture()
                throw AudioCaptureError.noAudio
            }
            Log.audio.notice("First audio \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s after the engine started")
        }

        return stream
    }

    #if os(macOS)
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
        if audioEngine != nil {
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
            "No microphone input. Grant Inscribe microphone access in System Settings → Privacy & Security → Microphone."
        case .engineNotRunning:
            "The audio engine is not running."
        case .noAudio:
            "The microphone started but sent no audio for 8 seconds. If it is an iPhone, check that it is nearby and unlocked, then try again."
        }
    }
}
