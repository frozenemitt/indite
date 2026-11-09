import Foundation
import AVFoundation
import os

/// Keeps the recording of each dictation in Recent Dictations, so a dictation can be
/// transcribed again.
///
/// A recording is the audio the recognizer was fed: 16 kHz, 16-bit, one channel. It is
/// kept as Apple Lossless in a CAF file, so the recognizer reads back exactly what it
/// heard the first time. A minute of synthetic speech came to 1.10 MB, and to 1.20 to
/// 1.32 MB with a microphone's hiss mixed in at -70 to -50 dBFS: 57 to 69% of the same
/// audio uncompressed. Every one read back sample for sample.
///
/// A recording lives only as long as its entry in Recent Dictations, and no longer than
/// the days chosen in Settings; see `DictationHistory`.
enum DictationAudioStore {

    private static let log = Logger(subsystem: "com.indite.app", category: "DictationAudio")

    /// Where recordings live, beside the store that names them.
    ///
    /// Resolved once, as `MeetingAudioStore.directory` is, so a lookup never creates the
    /// directory again.
    static let directory: URL = {
        let base = AppFolder.url.appendingPathComponent("DictationAudio", isDirectory: true)

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// The extension every recording here has. Only files with it are ever deleted
    /// unasked.
    static let fileExtension = "caf"

    static func url(forFileNamed name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func fileExists(named name: String?) -> Bool {
        guard let name else { return false }
        return FileManager.default.fileExists(atPath: url(forFileNamed: name).path)
    }

    /// Delete a recording by the name its dictation holds.
    ///
    /// The name is read from the store, so it is taken only when it can be a
    /// recording's: a plain file name ending in .caf, with no slash and no "..". Any
    /// other name could reach a file outside this folder.
    static func delete(fileNamed name: String?) {
        guard let name else { return }
        guard isPlainName(name) else {
            log.error("Did not delete a recording whose name is not a plain .\(fileExtension, privacy: .public) file name")
            return
        }
        try? FileManager.default.removeItem(at: url(forFileNamed: name))
    }

    /// Mark a recording as written now, when its dictation has been deleted and the
    /// recording is held for Undo. A copy of Indite launching meanwhile then leaves it
    /// alone, though no dictation names it; see `deleteRecordings(notNamedIn:writtenBefore:)`.
    static func markHeldForUndo(fileNamed name: String?) {
        guard let name, isPlainName(name) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url(forFileNamed: name).path)
    }

    /// Whether a name read from the store can be a recording's here: a plain file name
    /// ending in .caf, with no slash and no "..".
    private static func isPlainName(_ name: String) -> Bool {
        name.hasSuffix(".\(fileExtension)") && !name.contains("/") && !name.contains("..")
    }

    /// Delete every recording whose name is not in `kept` and that was last written
    /// before `cutoff`, and return how many went.
    ///
    /// For the recordings no entry names: one whose dictation ended in a crash before
    /// it reached Recent Dictations, or whose entry was deleted while Indite was quitting.
    ///
    /// One written since `cutoff` is left alone, because another copy of Indite may be
    /// running and need it. A copy recording a dictation writes its file as the words
    /// are spoken, and one holding a deleted dictation for Undo marks its recording as
    /// written when it sets the recording aside.
    static func deleteRecordings(notNamedIn kept: Set<String>, writtenBefore cutoff: Date) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var deleted = 0
        for name in names where name.hasSuffix(".\(fileExtension)") && !kept.contains(name) {
            let file = url(forFileNamed: name)
            guard let written = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  written < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                deleted += 1
            } catch {
                log.error("Could not delete a recording no dictation names: \(error, privacy: .public)")
            }
        }
        return deleted
    }
}

/// Writes one dictation's audio to its file as the recognizer receives it.
///
/// Fed from the engine's audio loop, off the main actor, and closed by the coordinator
/// once the engine has stopped, so it locks around the file.
final class DictationAudioWriter: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.indite.app", category: "DictationAudio")

    /// The name the dictation's entry will carry.
    let fileName = "\(UUID().uuidString).\(DictationAudioStore.fileExtension)"

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    /// Set once the file has been closed or abandoned, or could not be opened. A buffer
    /// arriving after that is dropped rather than opening the file again.
    private var isDone = false

    /// Write a buffer, opening the file on the first one.
    ///
    /// Opened lazily because the buffers' format is known only once audio arrives.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isDone else { return }

        if file == nil {
            let format = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitDepthHintKey: 16
            ]
            do {
                file = try AVAudioFile(
                    forWriting: DictationAudioStore.url(forFileNamed: fileName),
                    settings: settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            } catch {
                Self.log.error("Could not open the dictation's recording: \(error, privacy: .public)")
                isDone = true
                return
            }
        }

        do {
            try file?.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // One lost buffer costs the recording a moment; the dictation is unaffected.
            Self.log.error("Dropped a buffer from the dictation's recording: \(error, privacy: .public)")
        }
    }

    /// Close the file, and return its name, or nil when nothing was written.
    ///
    /// Closed here rather than whenever the last reference goes. Apple Lossless needs
    /// the packet table that CAF writes only on closing: a writer killed after 20
    /// seconds left 427,740 bytes of audio in a file that opened with no frames in it.
    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }

        isDone = true
        file?.close()
        file = nil

        guard framesWritten > 0, DictationAudioStore.fileExists(named: fileName) else {
            DictationAudioStore.delete(fileNamed: fileName)
            return nil
        }
        return fileName
    }

    /// Abandon the recording and remove the file.
    func discard() {
        lock.lock()
        defer { lock.unlock() }

        isDone = true
        file?.close()
        file = nil
        DictationAudioStore.delete(fileNamed: fileName)
    }
}
