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
}
