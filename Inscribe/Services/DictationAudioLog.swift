import AVFoundation
import Foundation
import os

/// Measurement only, and removed once the test is done: keeps each dictation's audio
/// and what the recognizer made of it, so the vocabulary routes can be tried again on
/// the user's own voice rather than on the Mac's reading voices.
///
/// Files stay on this Mac, in ~/Library/Application Support/Inscribe/Diagnostics/
/// DictationAudio: one .wav per dictation, in the format the recognizer was fed, and
/// a .json beside it.
final class DictationAudioLog: @unchecked Sendable {
    static let directory = URL.applicationSupportDirectory
        .appending(path: "Inscribe/Diagnostics/DictationAudio", directoryHint: .isDirectory)

    private let file: AVAudioFile
    private let name: String
    private let lock = NSLock()
    private var screen: ScreenVocabulary.Reading?

    /// The unusual words on screen when the dictation began. Only the words are kept.
    func noteScreen(_ reading: ScreenVocabulary.Reading) {
        lock.withLock { screen = reading }
    }

    init?(format: AVAudioFormat) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        name = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            file = try AVAudioFile(
                forWriting: Self.directory.appending(path: "\(name).wav"),
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            Log.dictation.error("Could not start the dictation audio log: \(error, privacy: .public)")
            return nil
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        try? file.write(from: buffer)
    }

    /// What the recognizer delivered, and its first guesses before the vocabulary chose.
    func finish(recognized: String, firstGuesses: String, vocabulary: [String]) {
        var entry: [String: Any] = ["recognized": recognized, "firstGuesses": firstGuesses, "vocabulary": vocabulary]
        if let screen = lock.withLock({ screen }) {
            entry["screenTerms"] = screen.terms
            entry["screenCharacters"] = screen.characters
            entry["screenElements"] = screen.elements
            entry["screenMilliseconds"] = screen.milliseconds
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted]) else { return }
        try? data.write(to: Self.directory.appending(path: "\(name).json"))
    }
}
