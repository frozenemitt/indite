import Foundation
import AVFoundation
import Observation
import SwiftData
import os

#if os(macOS)

/// Turns a recording made elsewhere into a meeting: a transcript, speakers where the
/// models are installed, and the audio kept beside it.
///
/// Import used to have a window of its own, with its own view of the transcript, that
/// ended by saying the result was in Meetings. It starts in the Meetings window now
/// and shows its progress as a row in the list, where the meeting will appear.
@MainActor
@Observable
final class MeetingImporter {

    /// One import under way, for the list to show.
    struct Job: Identifiable, Equatable {
        let id = UUID()
        let name: String
        var phase: String
    }

    private(set) var jobs: [Job] = []

    /// Why the last import failed or fell short, until it is dismissed.
    var lastError: String?

    private static let log = Logger(subsystem: "com.inscribe.app", category: "FileTranscribe")

    /// Import one file and return the meeting it became, or nil when it could not be read.
    @discardableResult
    func importRecording(at url: URL, settings: AppSettings, in context: ModelContext) async -> Meeting? {
        // Opened the way the transcriber opens it, so a file is turned away only when
        // the run would fail on it. A list of extensions refused formats it reads, such
        // as .aifc and .m4b.
        guard let file = try? AVAudioFile(forReading: url) else {
            lastError = "\(url.lastPathComponent) has no audio Inscribe can read."
            return nil
        }
        let length = Double(file.length) / file.fileFormat.sampleRate

        var job = Job(name: url.lastPathComponent, phase: "Transcribing…")
        jobs.append(job)
        defer { jobs.removeAll { $0.id == job.id } }
        func enter(_ phase: String) {
            job.phase = phase
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        }

        do {
            let (text, segments) = try await FileTranscriber.transcribe(
                fileURL: url,
                vocabulary: settings.vocabularyHints
            )

            // Speakers whenever the models are there, as for a recorded meeting. It
            // used to be a switch to set per file, and a one-voice recording loses
            // nothing by being found to have one voice.
            var turns: [SpeakerTurn] = []
            if DiarizationModelStore.isInstalled {
                enter("Separating speakers…")
                do {
                    // A new diarizer for each import, so it loads the models installed
                    // now. One kept across imports never reloaded after an update.
                    let diarizer = MeetingDiarizer()
                    try await diarizer.loadModels()
                    // Decoded off the main actor: reading an hour-long file is one
                    // synchronous pass.
                    let samples = try await Task.detached {
                        try AudioFileSamples.read(from: url)
                    }.value
                    turns = try await diarizer.diarizeWholeRecording(samples)
                } catch {
                    // Losing speaker labels should not lose the transcript.
                    lastError = "Speaker separation failed: \(error.localizedDescription)"
                }
            }

            enter("Saving…")
            // The placeholder, as a recorded meeting starts with, so the title writer
            // replaces it. Named after its file, an import of a recording called by
            // a UUID was listed as that UUID, and no writer touched it.
            let meeting = Meeting(title: Meeting.placeholderTitle)
            context.insert(meeting)

            // Dated when the recording was made. It used to be dated now, less its
            // length, so a recording from last month was filed under today.
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date().addingTimeInterval(-length)
            meeting.startedAt = made
            meeting.endedAt = made.addingTimeInterval(length)
            meeting.recordedDuration = length
            meeting.rawTranscript = TextProcessor.process(text, replacements: settings.wordReplacements)

            let attributed = meeting.applyAttribution(
                tracks: [(segments, turns)],
                vocabulary: settings.vocabularyHints,
                replacements: settings.wordReplacements,
                in: context
            )

            // The audio comes along when recordings are kept and there are lines to
            // play it by, as for a recorded meeting. An import used to keep none, so
            // its lines could not be checked against what was said.
            if attributed, settings.keepMeetingAudio {
                enter("Copying the audio…")
                let name = "\(UUID().uuidString).m4a"
                do {
                    try await Self.copyAudio(from: url, to: MeetingAudioStore.url(forFileNamed: name))
                    meeting.audioFileName = name
                    MeetingWordTimings.save(tracks: [segments], forRecording: name)
                } catch {
                    Self.log.error("Could not keep the imported audio: \(error, privacy: .public)")
                    lastError = "The transcript was imported, but its audio could not be kept: \(error.localizedDescription)"
                }
            }

            context.saveOrLog()
            return meeting

        } catch {
            lastError = "\(url.lastPathComponent) could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    /// Write a file's audio into the store as AAC, whatever it came as.
    ///
    /// Re-encoded rather than copied: the source may be a video, or an hour of
    /// uncompressed audio at twenty times the size the store keeps a meeting at.
    @concurrent
    private static func copyAudio(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: destination, as: .m4a)
    }
}

#endif
