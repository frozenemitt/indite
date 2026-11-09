import Accelerate
import AVFoundation

/// Whether the microphone is sending sound, judged from its buffers as they arrive.
///
/// A working microphone always sends faint noise, so a buffer in which every sample is
/// smaller than one step of 16-bit audio is dead: whatever sent it heard nothing. The
/// 170 saved dictations that hold audio, 70 minutes in all and up to four minutes
/// each, never held 10 ms of exact zeros after their first 174 ms, and their quietest
/// tenth of a second still peaked at 37 steps.
///
/// The timing starts from the microphone, not from the key. Nothing counts as silence
/// until the microphone has sent its first live buffer, which shows it is connected
/// and running. Until then it is starting up, and it gets an allowance to do so.
struct MicrophoneSignal: Sendable {

    /// What the buffers say about the microphone.
    enum Verdict: Equatable, Sendable {
        /// Sound is arriving, or the microphone still has time to start.
        case fine
        /// The start allowance ran out before a live buffer arrived. `sentAudio` is
        /// false when not even a dead buffer came.
        case notStarted(sentAudio: Bool)
        /// Dead buffers for the silence limit since the last live one.
        case silent
        /// No buffer at all for the silence limit, after sound had been arriving.
        case stalled
    }

    /// One step of 16-bit audio as a fraction of full scale. A sample below it is
    /// nothing a microphone heard.
    static let floor: Float = 1 / 32_768

    /// How long sound may be missing from the built-in microphone, once it has arrived,
    /// before that is a problem.
    static let limit: Duration = .seconds(1)

    /// The same limit for every other microphone, none of which has been measured.
    ///
    /// AirPods clean up the voice in the earbuds before sending it, and whether that
    /// turns the gaps between words into exact silence is not known, so the one-second
    /// limit could sound the alarm at every pause. A USB headset on a radio dongle, a
    /// microphone behind a noise gate such as Krisp or Blue VO!CE, and an aggregate
    /// device can send silence between words too. Five seconds is the limit Wispr Flow
    /// uses for every microphone. Jonathan chose it for Bluetooth on 2026-11-08, until
    /// AirPods are measured, and every microphone not measured gets the same.
    static let slowLimit: Duration = .seconds(5)

    /// How long the built-in microphone has to send its first live buffer, counted from
    /// when capture started.
    ///
    /// It sent its first buffer 103 to 104 ms after the engine started in all 48
    /// dictations logged on 2026-11-08, and every saved dictation held sound within its
    /// first two tenths of a second, so its first live buffer arrives by about 0.2 s.
    static let quickStart: Duration = .seconds(1)

    /// The allowance for every other microphone.
    ///
    /// The iPhone's microphone took 2 to 3 s to start on 2026-09-28, and in a meeting
    /// that day its first audio came as late as 6.1 s after the start. Eight seconds is
    /// the wait the audio capture already gives a microphone that has sent nothing
    /// yet. No Bluetooth, USB or aggregate microphone has been measured, and each gets
    /// the iPhone's allowance.
    static let slowStart: Duration = .seconds(8)

    let startedAt: ContinuousClock.Instant
    let startAllowance: Duration
    let silenceLimit: Duration

    /// When the latest live buffer arrived, or nil while none has.
    private(set) var lastSoundAt: ContinuousClock.Instant?
    /// Whether a live buffer has arrived in this recording.
    var heardSound: Bool { lastSoundAt != nil }
    private var sentAudio = false
    private var lastBufferAt: ContinuousClock.Instant?

    /// Frames in the dead buffers since the last live one, and the rate they came at.
    /// Counted in frames rather than seconds, so ten buffers of a tenth of a second
    /// add up to exactly one second.
    private var deadFrames = 0
    private var deadRate = 0.0

    /// Whether a second passed with no buffer at all since the last live one. Only a
    /// live buffer clears it, so a stalled microphone that comes back sending dead
    /// buffers is still reported.
    private var stalledSinceSound = false

    init(startedAt: ContinuousClock.Instant, startAllowance: Duration, silenceLimit: Duration = Self.limit) {
        self.startedAt = startedAt
        self.startAllowance = startAllowance
        self.silenceLimit = silenceLimit
    }

    /// Note one buffer as it arrives.
    ///
    /// - Parameters:
    ///   - peak: The largest sample magnitude in the microphone's channels.
    ///   - frames: How many frames the buffer holds.
    ///   - sampleRate: Its sample rate.
    ///   - now: When it arrived.
    mutating func take(peak: Float, frames: Int, sampleRate: Double, at now: ContinuousClock.Instant) {
        if heardSound, let lastBufferAt, now - lastBufferAt >= silenceLimit {
            stalledSinceSound = true
        }
        lastBufferAt = now
        sentAudio = true
        if peak >= Self.floor {
            lastSoundAt = now
            deadFrames = 0
            stalledSinceSound = false
        } else {
            deadFrames += frames
            deadRate = sampleRate
        }
    }

    /// What the buffers so far say at `now`.
    func verdict(at now: ContinuousClock.Instant) -> Verdict {
        guard heardSound else {
            return now - startedAt >= startAllowance ? .notStarted(sentAudio: sentAudio) : .fine
        }
        if let lastBufferAt, now - lastBufferAt >= silenceLimit { return .stalled }
        let deadForLimit = deadFrames > 0 && Double(deadFrames) >= deadRate * (silenceLimit / .seconds(1))
        return stalledSinceSound || deadForLimit ? .silent : .fine
    }
}

extension AVAudioPCMBuffer {
    /// The largest sample magnitude in one channel, or in every channel when `channel`
    /// is nil.
    ///
    /// The capture hands over separate channels of floating-point samples. A buffer of
    /// any other kind reads as infinitely loud, so it is never taken for silence.
    func peak(channel: Int?) -> Float {
        guard let data = floatChannelData else { return .infinity }
        let channels = channel.map { [$0] } ?? Array(0..<Int(format.channelCount))
        return channels.reduce(0) { loudest, index in
            max(loudest, vDSP.maximumMagnitude(UnsafeBufferPointer(start: data[index], count: Int(frameLength))))
        }
    }
}
