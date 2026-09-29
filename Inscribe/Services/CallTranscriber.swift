import AVFoundation
import Foundation
import os
import Speech

/// Transcribes the other side of a call, beside the engine that transcribes the
/// microphone.
///
/// A meeting recording a call hands on two channels: the microphone and the system
/// audio. One recognizer on a mix of both followed whichever side was louder. A voice
/// talking over a video through headphones was 5 to 8 times quieter than the video,
/// and only the video was transcribed. Each side now has a recognizer of its own, as
/// other meeting recorders do, and the two transcripts are merged by time.
///
/// Fed from the audio thread and read from the main actor, so its state is held
/// under a lock. One session runs per stretch of capture: started when the meeting
/// starts or resumes, and finished when it pauses or stops.
final class CallTranscriber: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "CallTranscriber")

    private struct Session {
        var analyzer: SpeechAnalyzer
        var input: AsyncStream<AnalyzerInput>.Continuation
        var format: AVAudioFormat
        var results: Task<Void, Never>
    }

    private let lock = NSLock()
    private var session: Session?
    private var finals: [TimedTranscriptSegment] = []
    private var volatile = ""
    private let converter = BufferConverter()

    /// The words heard so far this session, finished ones stamped with their time.
    /// Called on the main actor whenever they change.
    var onChange: (@MainActor ([TimedTranscriptSegment], String) -> Void)?

    /// Start a session. The speech model is already installed by the time a meeting
    /// runs, because the engine checks for it before the microphone opens.
    func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionEngineError.setupFailed("No compatible audio format for the call")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.receive(result.text, isFinal: result.isFinal)
                }
            } catch {
                Self.log.error("Call transcription failed: \(error, privacy: .public)")
            }
        }

        lock.withLock {
            finals = []
            volatile = ""
            session = Session(analyzer: analyzer, input: continuation, format: format, results: results)
        }
        try await analyzer.start(inputSequence: stream)
        Self.log.notice("Transcribing the call")
    }

    /// Add one buffer of the call's audio.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return }
        do {
            session.input.yield(AnalyzerInput(buffer: try converter.convertBuffer(buffer, to: session.format)))
        } catch {
            Self.log.error("Could not convert call audio: \(error, privacy: .public)")
        }
    }

    /// Finish the session and return what it heard, each run stamped with its time
    /// from the session's start.
    func finish() async -> [TimedTranscriptSegment] {
        guard let session = lock.withLock({ () -> Session? in
            let current = self.session
            self.session = nil
            return current
        }) else { return [] }

        session.input.finish()
        do {
            try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Self.log.error("Could not finish call transcription: \(error, privacy: .public)")
        }
        await session.results.value

        return lock.withLock {
            let heard = finals
            finals = []
            volatile = ""
            return heard
        }
    }

    private func receive(_ text: AttributedString, isFinal: Bool) {
        let (segments, pending) = lock.withLock { () -> ([TimedTranscriptSegment], String) in
            if isFinal {
                finals += TranscriptionEngine.timedRuns(from: text)
                volatile = ""
            } else {
                volatile = String(text.characters)
            }
            return (finals, volatile)
        }
        guard let onChange else { return }
        Task { @MainActor in onChange(segments, pending) }
    }
}
