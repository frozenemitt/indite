import Foundation
import AVFoundation
import Speech
import os

/// Transcribes an audio or video file already on disk.
///
/// The whole pipeline already existed for the microphone; this feeds it a file instead.
/// `SpeechAnalyzer` reads one directly, so the audio is never routed through the engine
/// — which also means it runs faster than real time rather than taking an hour to read
/// an hour.
@MainActor
enum FileTranscriber {

    private static let log = Logger(subsystem: "com.indite.app", category: "FileTranscribe")

    /// Read a file and return its transcript, with each run and the time it was spoken.
    ///
    /// - Parameter vocabulary: The user's listed words, used as in live dictation.
    static func transcribe(
        fileURL: URL,
        vocabulary: [String]
    ) async throws -> (text: String, segments: [TimedTranscriptSegment]) {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)

            let transcriber = SpeechTranscriber(
                // Dictation's locale, which the engine resolves once and caches. Imports
                // once used en-US whether or not this Mac could transcribe it.
                locale: try await TranscriptionEngine.shared.resolveSupportedLocale(),
                transcriptionOptions: [],
                reportingOptions: vocabulary.isEmpty ? [] : [.alternativeTranscriptions],
                attributeOptions: [.audioTimeRange]
            )

            // Same asset the live path uses; already installed after any dictation.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }

            let terms = vocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                finishAfterFile: true
            )

            var collected = ""
            var segments: [TimedTranscriptSegment] = []

            for try await result in transcriber.results where result.isFinal {
                collected += Vocabulary.choose(
                    String(result.text.characters),
                    alternatives: result.alternatives.map { String($0.characters) },
                    terms: terms
                )
                segments += TranscriptionEngine.timedRuns(from: result.text)
            }

            try await analyzer.finalizeAndFinishThroughEndOfInput()

            Self.log.notice("Transcribed \(fileURL.lastPathComponent, privacy: .public): \(collected.count) characters")
            let text = Vocabulary.spell(collected.trimmingCharacters(in: .whitespacesAndNewlines), terms: terms)
            return (text, segments)

        } catch {
            Self.log.error("Failed on \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            throw error
        }
    }

    /// Read a dictation's recording again, and apply the listed words by the steps a
    /// live dictation takes: the recognizer's second guess when it holds a listed word,
    /// the spotter's listening for them, and their spelling.
    ///
    /// Names read from the screen are left out. They belonged to the window in front
    /// when the words were spoken, and the screen now is another one.
    ///
    /// A 30-second recording took 0.92 s with 14 listed words, and 0.39 s with none:
    /// the spotter's reading is most of the difference.
    static func transcribeDictation(fileURL: URL, vocabulary: [String]) async throws -> String {
        let terms = vocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let audioFile = try AVAudioFile(forReading: fileURL)

        // Asked for as the live engine asks: second guesses and confidence only when
        // there is a list for them to serve.
        let transcriber = SpeechTranscriber(
            locale: try await TranscriptionEngine.shared.resolveSupportedLocale(),
            transcriptionOptions: [],
            reportingOptions: terms.isEmpty ? [] : [.alternativeTranscriptions],
            attributeOptions: terms.isEmpty ? [.audioTimeRange] : [.audioTimeRange, .transcriptionConfidence]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // The spotter hears the recording while the recognizer reads it.
        let spotting = terms.isEmpty ? nil : VocabularySpotter.shared.session().map { session in
            Task.detached(priority: .userInitiated) {
                try Self.feed(fileURL, to: session)
                return await session.finish(terms: terms)
            }
        }

        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )

        var text = ""
        var segments: [Vocabulary.Segment] = []
        for try await result in transcriber.results where result.isFinal {
            let heard = String(result.text.characters)
            let chosen = Vocabulary.choose(
                heard,
                alternatives: result.alternatives.map { String($0.characters) },
                terms: terms,
                keeping: terms
            )
            text += chosen
            segments.append(Vocabulary.Segment(
                text: chosen,
                tookSecondGuess: chosen != heard,
                runs: TranscriptionEngine.vocabularyRuns(from: result.text)
            ))
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()

        if let spotting {
            let spotted = Vocabulary.applySpotted(try await spotting.value, to: segments, listed: terms)
            text = spotted.text
            Self.log.notice("Spotter put in \(spotted.replaced, privacy: .public) listed words on a second reading")
        }
        return Vocabulary.spell(text, terms: terms).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hand the spotter a recording's audio, a second at a time.
    private nonisolated static func feed(_ fileURL: URL, to session: VocabularySpotter.Session) throws {
        let file = try AVAudioFile(forReading: fileURL)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000) else { return }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { return }
            session.append(buffer)
        }
    }
}
