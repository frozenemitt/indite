import Foundation
import SwiftData
import os

/// Recently Deleted: the meetings deleted in the last thirty days, kept so a delete
/// can be taken back.
///
/// Deleting used to stop for a confirmation every time and was then final. As in
/// Voice Memos and Notes, a deleted meeting now leaves the list at once and waits
/// here, from where it can be recovered until its thirty days are up.
///
/// The date it was deleted is a property of the meeting, `Meeting.deletedAt`. For
/// its first hour it was kept in preferences, to leave the store's shape alone. That
/// put one fact about a meeting in a second file: lose or reset the preferences and
/// every deleted meeting came back, and anything else that ever lists meetings would
/// have had to know to ask.
@MainActor
enum MeetingTrash {

    /// How long a deleted meeting waits before it is erased.
    nonisolated static let daysKept = 30

    /// Move meetings to Recently Deleted.
    static func delete(_ meetings: [Meeting], in context: ModelContext, now: Date = .now) {
        for meeting in meetings { meeting.deletedAt = now }
        context.saveOrLog()
    }

    static func recover(_ meetings: [Meeting], in context: ModelContext) {
        // Not one erased since: Undo can arrive after its meeting has gone for good.
        for meeting in meetings where !meeting.isDeleted && meeting.modelContext != nil {
            meeting.deletedAt = nil
        }
        context.saveOrLog()
    }

    /// Erase meetings for good: the recording, its word timings, and the meeting.
    static func erase(_ meetings: [Meeting], in context: ModelContext) {
        for meeting in meetings {
            // The recording is not owned by SwiftData, so cascade delete does not
            // reach it.
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            context.delete(meeting)
        }
        context.saveOrLog()
    }

    /// Erase the meetings whose thirty days are up.
    static func eraseExpired(in context: ModelContext, now: Date = .now) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -daysKept, to: now) ?? now
        let expired = FetchDescriptor<Meeting>(predicate: #Predicate { meeting in
            meeting.deletedAt != nil && meeting.deletedAt! < cutoff
        })
        do {
            let meetings = try context.fetch(expired)
            guard !meetings.isEmpty else { return }
            Log.meetings.notice("Erasing \(meetings.count, privacy: .public) meetings deleted more than \(daysKept, privacy: .public) days ago")
            erase(meetings, in: context)
        } catch {
            Log.meetings.error("Could not look for meetings to erase: \(error, privacy: .public)")
        }
    }
}

extension Meeting {
    /// Whole days until a deleted meeting is erased, never less than one while it
    /// waits.
    func daysUntilErased(now: Date = .now) -> Int {
        guard let deletedAt else { return MeetingTrash.daysKept }
        let gone = Calendar.current.dateComponents([.day], from: deletedAt, to: now).day ?? 0
        return max(1, MeetingTrash.daysKept - gone)
    }
}
