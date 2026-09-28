import Foundation
import os
import AVFoundation
import FluidAudio

/// One stretch of audio attributed to one speaker.
struct SpeakerTurn: Sendable, Equatable {
    /// The diarizer's own identifier, stable across the meeting.
    let speakerId: String
    let start: TimeInterval
    let end: TimeInterval

    /// How confident the diarizer is, 0–1. Low scores usually mean crosstalk.
    let quality: Float

    func covers(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// Speaker diarization over a whole meeting, using pyannote community-1 through
/// FluidAudio's CoreML port.
///
/// The meeting's audio is written to a temporary file as it is captured, and the
/// speakers are separated once, over the whole of it, when the meeting ends. Every
/// voice is compared with every other across the recording, instead of being
/// matched speaker by speaker as 30-second chunks arrived.
///
/// Measured on the 16 AMI test meetings of four people, against their reference
/// labels: 18.4% error, where the chunked model we used before made 27.4%, and the
/// right number of speakers in 12 meetings rather than 5. It confuses one speaker
/// for another about a fifth as often. The chunked model tended to invent people,
/// up to nine in a meeting of four.
///
/// An actor rather than a class: the pipeline is CPU-bound, and running it on the
/// main actor would stall the UI while a long meeting is separated.
actor MeetingDiarizer {

    /// What FluidAudio's models expect.
    static let sampleRate = 16_000

    /// The meeting's audio at 16 kHz mono, written as it arrives.
    ///
    /// On disk rather than in memory: an hour is about 230 MB of float samples. One
    /// fixed name, so a crash leaves at most one file behind, and the next meeting
    /// overwrites it.
    private static let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("meeting-diarization.caf")

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
    )!

    // MARK: - State

    private var pipeline: Pipeline?
    private var recording: AVAudioFile?

    /// Total audio handed to this diarizer.
    ///
    /// The meeting's master clock. The turns are stamped against it, so a resumed
    /// session must offset its transcript by this value or the two analyses stop
    /// describing the same moment.
    private(set) var receivedSeconds: TimeInterval = 0

    // MARK: - Lifecycle

    /// Load the CoreML models from disk, and open the file the audio goes into.
    ///
    /// Throws when they are not installed rather than fetching them: a meeting is the
    /// wrong moment to start a download, and the recording path stays offline.
    func prepare() async throws {
        guard pipeline == nil else { return }

        // Starting a meeting must not reach the network: the models are installed from
        // Settings, deliberately, before any of this runs.
        guard DiarizationModelStore.isInstalled else {
            throw DiarizationModelStore.ModelStoreError.notInstalled
        }

        let models = try await OfflineDiarizerModels.load(from: DiarizationModelStore.modelsRoot)
        // pyannote's own step and no minimum segment, rather than FluidAudio's
        // faster default. The default found no speaker for 4 s in the middle of a
        // sentence, and the end of it went to the other person. These settings found
        // the missing second. Measured against the default: AMI error 18.4% against
        // 19.3%; a 28-minute two-person meeting 63 of 65 lines right against 59, with
        // none left unattributed; at half the speed, about 10 s for 30 minutes. The
        // cost seen was one phantom speaker holding 2 s of that meeting.
        var config = OfflineDiarizerConfig.default
        config.segmentation.stepRatio = 0.1
        config.embedding.minSegmentDurationSeconds = 0
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        pipeline = Pipeline(manager: manager)

        try? FileManager.default.removeItem(at: Self.recordingURL)
        recording = try AVAudioFile(
            forWriting: Self.recordingURL,
            settings: Self.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        receivedSeconds = 0
        Log.diarization.notice("Ready")
    }

    /// Add newly captured audio to the recording.
    func append(_ samples: [Float]) {
        guard let recording, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        do {
            try recording.write(from: buffer)
            receivedSeconds += Double(samples.count) / Double(Self.sampleRate)
        } catch {
            Log.diarization.error("Could not keep audio for speaker separation: \(error, privacy: .public)")
        }
    }

    /// Separate the speakers over everything recorded, and delete the recording.
    func finish() async -> [SpeakerTurn] {
        guard let pipeline, recording != nil else { return [] }
        recording = nil  // Closes the file.
        defer { try? FileManager.default.removeItem(at: Self.recordingURL) }

        let started = Date()
        do {
            let turns = Self.turns(from: try await pipeline.manager.process(Self.recordingURL))
            Log.diarization.notice("""
                Separated \(Int(self.receivedSeconds), privacy: .public)s into \
                \(Set(turns.map(\.speakerId)).count, privacy: .public) speakers in \
                \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s
                """)
            return turns
        } catch {
            Log.diarization.error("Speaker separation failed: \(error, privacy: .public)")
            return []
        }
    }

    /// Diarize a complete recording in one pass, for imported files.
    func diarizeWholeRecording(_ samples: [Float]) async -> [SpeakerTurn] {
        guard let pipeline else { return [] }
        recording = nil
        try? FileManager.default.removeItem(at: Self.recordingURL)

        do {
            return Self.turns(from: try await pipeline.manager.process(audio: samples))
        } catch {
            Log.diarization.error("Speaker separation failed: \(error, privacy: .public)")
            return []
        }
    }

    func reset() {
        pipeline = nil
        recording = nil
        try? FileManager.default.removeItem(at: Self.recordingURL)
        receivedSeconds = 0
    }

    /// FluidAudio's manager is not marked Sendable. It is only ever used from this
    /// actor, one call at a time, which is what makes handing it to its own async
    /// methods safe.
    private final class Pipeline: @unchecked Sendable {
        let manager: OfflineDiarizerManager
        init(manager: OfflineDiarizerManager) { self.manager = manager }
    }

    private static func turns(from result: DiarizationResult) -> [SpeakerTurn] {
        result.segments
            .map { segment in
                SpeakerTurn(
                    speakerId: segment.speakerId,
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds),
                    quality: segment.qualityScore
                )
            }
            .sorted { $0.start < $1.start }
    }
}

// MARK: - File Reading

/// Reads a whole audio file as the mono float the diarizer expects.
///
/// Lets an already-recorded meeting be speaker-separated on import, not just one
/// captured live.
enum AudioFileSamples {

    /// Decode `url` to 16 kHz mono float, resampling whatever it holds.
    static func read(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(MeetingDiarizer.sampleRate),
            channels: 1,
            interleaved: false
        ) else { throw AudioFileError.unsupportedFormat }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioFileError.unsupportedFormat
        }
        // Mixed to mono rather than remapped, which keeps only the first channel: a
        // call recorded with each side on its own channel would lose one side.
        converter.downmix = true

        // Read in chunks so an hour-long file does not arrive as one enormous buffer.
        let framesPerChunk: AVAudioFrameCount = 1 << 16
        var samples: [Float] = []
        var finished = false

        while !finished {
            let ratio = target.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(framesPerChunk) * ratio) + 1024

            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw AudioFileError.unsupportedFormat
            }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let input = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: framesPerChunk
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try file.read(into: input, frameCount: framesPerChunk)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                if input.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                inputStatus.pointee = .haveData
                return input
            }

            if let conversionError { throw conversionError }
            if status == .endOfStream || output.frameLength == 0 { finished = true }

            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        }

        return samples
    }

    enum AudioFileError: LocalizedError {
        case unsupportedFormat
        var errorDescription: String? { "That audio format could not be read." }
    }
}

// MARK: - Audio Conversion

/// Resamples microphone buffers to the 16 kHz mono float the diarizer expects.
///
/// Separate from the actor because conversion happens on the audio thread, where
/// hopping to an actor per buffer would be wasteful.
final class DiarizationAudioConverter: @unchecked Sendable {

    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(MeetingDiarizer.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.targetFormat = format
    }

    /// Convert one buffer, rebuilding the converter if the input format changed.
    func floats(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = buffer.format

        if converter == nil || sourceFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            // Mixed, not remapped. Without this the converter keeps channel 0 and drops
            // the rest, and with system audio on, channel 0 is the microphone: the
            // diarizer never heard anyone on the call.
            converter?.downmix = true
            sourceFormat = inputFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024

        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?

        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
