import Foundation
import SwiftData
import os

/// A recorded meeting: the transcript, who said what, and an optional summary.
@Model
final class Meeting {

    var title: String
    var startedAt: Date
    var endedAt: Date?

    /// Everything said, in order, without speaker attribution.
    ///
    /// Kept alongside the utterances because diarization can fail or be switched off,
    /// and a transcript with no speaker labels still beats no transcript.
    var rawTranscript: String

    /// AI-generated summary, if the user has asked for one.
    var summary: String?

    /// Seconds of audio actually captured.
    ///
    /// Distinct from wall-clock duration once pausing exists: a meeting started at
    /// 10:00 and ended at 11:00 with forty minutes paused holds twenty minutes of audio.
    var recordedDuration: TimeInterval = 0

    /// File name of the saved recording, if the audio was kept.
    ///
    /// A name rather than a path: the containing folder moves with the app's container,
    /// and an absolute path stored today would dangle tomorrow.
    var audioFileName: String?

    @Relationship(deleteRule: .cascade, inverse: \Utterance.meeting)
    var utterances: [Utterance]

    @Relationship(deleteRule: .cascade, inverse: \MeetingSpeaker.meeting)
    var speakers: [MeetingSpeaker]

    init(title: String = "", startedAt: Date = Date()) {
        self.title = title.isEmpty ? Meeting.defaultTitle(for: startedAt) : title
        self.startedAt = startedAt
        self.endedAt = nil
        self.rawTranscript = ""
        self.summary = nil
        self.utterances = []
        self.speakers = []
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        return "Meeting \(formatter.string(from: date))"
    }

    /// Wall-clock span from start to finish, including any paused stretches.
    var duration: TimeInterval {
        guard let endedAt else { return Date().timeIntervalSince(startedAt) }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// Whether the user paused at any point, worth showing since the two durations
    /// then disagree.
    ///
    /// False while the meeting is still open. Its recorded length is saved only every
    /// half minute, while the wall clock keeps running, so the two disagree between
    /// saves whether or not anyone paused.
    var wasPaused: Bool {
        guard endedAt != nil else { return false }
        return recordedDuration > 0 && duration - recordedDuration > 1
    }

    /// Utterances in spoken order.
    var orderedUtterances: [Utterance] {
        utterances.sorted { $0.start < $1.start }
    }

    /// Whether the recording is still on disk and playable.
    var hasAudio: Bool {
        MeetingAudioStore.fileExists(named: audioFileName)
    }

    /// Whether diarization produced anything usable.
    var hasSpeakerAttribution: Bool {
        !utterances.isEmpty && !speakers.isEmpty
    }

    /// The label to show for a diarizer id, preferring a name the user has set.
    func displayName(forSpeakerId id: String) -> String {
        speakers.first { $0.speakerId == id }?.resolvedName ?? id
    }
}

/// One speaker's continuous stretch of speech, with the words they said in it.
@Model
final class Utterance {

    /// The diarizer's identifier. Stable within a meeting, meaningless across them.
    var speakerId: String

    var text: String
    var start: TimeInterval
    var end: TimeInterval

    var meeting: Meeting?

    init(speakerId: String, text: String, start: TimeInterval, end: TimeInterval) {
        self.speakerId = speakerId
        self.text = text
        self.start = start
        self.end = end
    }

    /// Position in the meeting, for display, in the same m:ss or h:mm:ss form as every
    /// other time shown for a meeting.
    var timestampLabel: String {
        MeetingExporter.durationLabel(start)
    }
}

/// A speaker the diarizer found, plus whatever the user chose to call them.
@Model
final class MeetingSpeaker {

    /// The diarizer's identifier.
    var speakerId: String

    /// The name the user typed, if any. Empty means fall back to the generated label.
    var name: String

    /// "Speaker 1", "Speaker 2" — assigned in order of first appearance, so the
    /// numbering matches reading order rather than the diarizer's internal ids.
    var generatedLabel: String

    var meeting: Meeting?

    init(speakerId: String, generatedLabel: String, name: String = "") {
        self.speakerId = speakerId
        self.generatedLabel = generatedLabel
        self.name = name
    }

    var resolvedName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? generatedLabel : name
    }
}

extension Meeting {
    /// Speakers in label order, "Speaker 2" before "Speaker 10".
    ///
    /// Labels are compared as Finder compares names, numbers by value. Plain string
    /// order put "Speaker 10" before "Speaker 2".
    var sortedSpeakers: [MeetingSpeaker] {
        speakers.sorted { $0.generatedLabel.localizedStandardCompare($1.generatedLabel) == .orderedAscending }
    }

    /// Turn timed transcript runs plus speaker turns into stored speakers and utterances.
    ///
    /// Recorded and imported meetings both store theirs through this, so a change to how
    /// attribution is stored reaches both.
    ///
    /// - Returns: Whether any utterance was stored.
    @discardableResult
    func applyAttribution(
        timedSegments: [TimedTranscriptSegment],
        turns: [SpeakerTurn],
        vocabulary: [String],
        replacements: [String: String],
        in context: ModelContext
    ) -> Bool {
        // Without timings there is nothing to align against; the raw transcript on the
        // meeting is the whole result.
        guard !timedSegments.isEmpty else {
            Log.meetings.notice("No timed segments — transcript kept without attribution")
            return false
        }

        let aligned = SpeakerAlignment.align(transcript: timedSegments, turns: turns)
        let labels = SpeakerAlignment.generatedLabels(for: aligned)

        for (speakerId, label) in labels {
            let speaker = MeetingSpeaker(speakerId: speakerId, generatedLabel: label)
            speaker.meeting = self
            context.insert(speaker)
        }

        // The same passes `rawTranscript` gets, in the same order: the listed words
        // spelled, then the pause marks and the replacements. Every reader prefers the
        // utterances once there is attribution, so without them the displayed and
        // exported meeting would read "type script" where the raw transcript has
        // "TypeScript", keep the recognizer's pause marks, and skip the user's word
        // replacements.
        for item in aligned {
            let utterance = Utterance(
                speakerId: item.speakerId,
                text: TextProcessor.process(
                    Vocabulary.spell(item.text, terms: vocabulary),
                    replacements: replacements
                ),
                start: item.start,
                end: item.end
            )
            utterance.meeting = self
            context.insert(utterance)
        }
        return !aligned.isEmpty
    }
}
