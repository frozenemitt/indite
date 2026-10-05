import Foundation
import AVFoundation
import os

/// Writes a meeting's audio to disk and finds it again later.
///
/// Audio used to be discarded the moment a meeting ended, which left the speaker
/// corrections unverifiable: told that Speaker 2 said something, you had no way to
/// check.
///
/// Written as AAC, not the raw float the engine hands over. An hour of 48 kHz stereo
/// float is about 1.4 GB; the same hour as AAC is around 30 MB, and speech survives
/// the compression well enough for a human listening back.
final class MeetingAudioStore {

    /// Where recordings live, alongside the meeting database.
    ///
    /// Resolved once. As a computed property this created the directory on every
    /// lookup, and the transcript list looks it up once per utterance, four times a
    /// second, for as long as a recording is playing.
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nscribe/MeetingAudio", isDirectory: true)

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func url(forFileNamed name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func fileExists(named name: String?) -> Bool {
        guard let name else { return false }
        return FileManager.default.fileExists(atPath: url(forFileNamed: name).path)
    }

    /// Remove a recording, and the word timings kept beside it.
    static func delete(fileNamed name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(forFileNamed: name))
        try? FileManager.default.removeItem(at: url(forFileNamed: MeetingWordTimings.fileName(forRecording: name)))
    }

    /// Total disk used by every saved recording.
    static func totalSize() -> Int64 {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        return contents.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// Appends live audio to one file for the length of a meeting.
///
/// Deliberately not closed when the user pauses: `AVAudioFile` cannot reopen a file to
/// append, so closing on pause would leave a meeting split across several recordings
/// whose timestamps no longer line up with the transcript.
final class MeetingAudioWriter: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.nscribe.app", category: "MeetingAudio")

    private var file: AVAudioFile?
    private var converter = BufferConverter()
    private let lock = NSLock()

    private(set) var fileName: String?

    private var openFailure: String?

    /// Why the recording file could not be opened, if it could not.
    ///
    /// Kept for the recorder to report. Without it the meeting ended saying "No
    /// recording was kept", as though the user had switched recording off, and the
    /// reason reached only the log.
    ///
    /// Cleared by `finish()` and `discard()`, so the recorder reads it before either. A
    /// meeting that does not keep its audio never calls `begin()`, and while only
    /// `begin()` cleared it, such a meeting reported the previous meeting's failure as
    /// its own.
    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return openFailure
    }

    /// Begin a recording, returning the file name to store on the meeting.
    func begin() -> String {
        let name = "\(UUID().uuidString).m4a"
        fileName = name
        file = nil
        openFailure = nil
        return name
    }

    /// Write a buffer, opening the file on the first one.
    ///
    /// Opened lazily because the engine's format is only known once audio arrives, and
    /// it varies with the input device — a meeting using the system-audio aggregate has
    /// a different channel count from one using the built-in microphone.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard let fileName else { return }

        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: min(buffer.format.channelCount, 2),
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]

            do {
                file = try AVAudioFile(
                    forWriting: MeetingAudioStore.url(forFileNamed: fileName),
                    settings: settings
                )
            } catch {
                Self.log.error("Could not open the recording file: \(error, privacy: .public)")
                openFailure = error.localizedDescription
                self.fileName = nil
                return
            }
        }

        guard let file else { return }

        do {
            // Downmixed to the format the file was opened with. The meeting aggregate's
            // buffer has three channels, the microphone plus a stereo system tap, and
            // AAC is opened for at most two. Written untouched, every call failed and
            // left a file that reports itself playable and holds no audio.
            try file.write(from: converter.convertBuffer(buffer, to: file.processingFormat))
        } catch {
            // One bad buffer should not end the meeting; the transcript is unaffected.
            Self.log.error("Dropped a buffer: \(error, privacy: .public)")
        }
    }

    /// Close the file and report what was written.
    @discardableResult
    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let name = fileName
        let framesWritten = file?.length ?? 0
        file = nil
        converter = BufferConverter()
        fileName = nil
        openFailure = nil

        guard let name, MeetingAudioStore.fileExists(named: name) else { return nil }

        // A file that exists but holds no audio is worse than none: every line of the
        // meeting would offer to play, and clicking one would play nothing.
        guard framesWritten > 0 else {
            Self.log.error("Recording captured no audio; discarding the empty file")
            MeetingAudioStore.delete(fileNamed: name)
            return nil
        }

        return name
    }

    /// Abandon the recording and remove the partial file.
    func discard() {
        lock.lock()
        defer { lock.unlock() }

        let name = fileName
        file = nil
        converter = BufferConverter()
        fileName = nil
        openFailure = nil
        MeetingAudioStore.delete(fileNamed: name)
    }
}
