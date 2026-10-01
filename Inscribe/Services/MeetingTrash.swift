import Foundation
import Observation
import SwiftData
import os

/// The meetings deleted in the last thirty days, kept so a delete can be taken back.
///
/// Deleting used to stop for a confirmation every time and was then final. As in
/// Voice Memos and Notes, a deleted meeting now leaves the list at once and waits in
/// Recently Deleted, from where it can be recovered until its thirty days are up.
///
/// All this keeps is the date each meeting was deleted, by the meeting's identifier,
/// in preferences. It is not a property of the meeting: adding one would change the
/// shape of the meeting store, and nothing about a meeting changes when it is
/// deleted except that it is waiting to go.
@MainActor
@Observable
final class MeetingTrash {
    static let shared = MeetingTrash()

    /// How long a deleted meeting waits before it is erased.
    static let daysKept = 30

    /// When each deleted meeting was deleted, by `key(for:)`.
    private(set) var deletedAt: [String: Date]

    private static let storageKey = "recentlyDeletedMeetings"

    private init() {
        deletedAt = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Date] ?? [:]
    }

    // MARK: - Reading

    func contains(_ meeting: Meeting) -> Bool {
        guard !deletedAt.isEmpty, let key = Self.key(for: meeting) else { return false }
        return deletedAt[key] != nil
    }

    func date(for meeting: Meeting) -> Date? {
        Self.key(for: meeting).flatMap { deletedAt[$0] }
    }

    /// Whole days until the meeting is erased, never less than one while it waits.
    func daysLeft(for meeting: Meeting, now: Date = .now) -> Int {
        guard let date = date(for: meeting) else { return Self.daysKept }
        let gone = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        return max(1, Self.daysKept - gone)
    }

    // MARK: - Changing

    func add(_ meetings: [Meeting], now: Date = .now) {
        for meeting in meetings {
            if let key = Self.key(for: meeting) { deletedAt[key] = now }
        }
        save()
    }

    func recover(_ meetings: [Meeting]) {
        for meeting in meetings {
            if let key = Self.key(for: meeting) { deletedAt[key] = nil }
        }
        save()
    }

    /// Erase meetings for good: the recording, its word timings, and the meeting.
    func erase(_ meetings: [Meeting], in context: ModelContext) {
        for meeting in meetings {
            if let key = Self.key(for: meeting) { deletedAt[key] = nil }
            // The recording is not owned by SwiftData, so cascade delete does not
            // reach it.
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            context.delete(meeting)
        }
        save()
        context.saveOrLog()
    }

    /// Erase the meetings whose thirty days are up, and forget dates whose meeting is
    /// no longer in the store.
    func eraseExpired(among meetings: [Meeting], in context: ModelContext, now: Date = .now) {
        // With no meetings to compare against, every date would look like one whose
        // meeting is gone. An empty list is more likely a list not loaded yet.
        guard !deletedAt.isEmpty, !meetings.isEmpty else { return }

        // Dates saved before the key carried the meeting's start are moved to it.
        var moved = false
        for meeting in meetings {
            guard let old = Self.identifierKey(for: meeting), let date = deletedAt[old],
                  let key = Self.key(for: meeting) else { continue }
            deletedAt[old] = nil
            deletedAt[key] = date
            moved = true
        }
        if moved { save() }

        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.daysKept, to: now) ?? now
        let expired = meetings.filter { meeting in
            date(for: meeting).map { $0 < cutoff } ?? false
        }
        if !expired.isEmpty {
            Log.meetings.notice("Erasing \(expired.count, privacy: .public) meetings deleted more than \(Self.daysKept, privacy: .public) days ago")
            erase(expired, in: context)
        }

        let present = Set(meetings.compactMap(Self.key))
        let orphans = deletedAt.keys.filter { !present.contains($0) }
        if !orphans.isEmpty {
            for key in orphans { deletedAt[key] = nil }
            save()
        }
    }

    // MARK: - Storage

    private func save() {
        UserDefaults.standard.set(deletedAt, forKey: Self.storageKey)
    }

    /// What a deleted meeting is found by: its identifier in the store, and the
    /// moment it started.
    ///
    /// The identifier alone is the store's name and a row number. A store put back
    /// from an older backup hands those row numbers out again, and a meeting recorded
    /// afterwards could take the number of one deleted before: it would vanish into
    /// Recently Deleted as it was saved, and be erased when the other's days ran out.
    /// No two meetings share a row number and a start.
    private static func key(for meeting: Meeting) -> String? {
        identifierKey(for: meeting).map { "\($0)|\(Int(meeting.startedAt.timeIntervalSinceReferenceDate))" }
    }

    /// A meeting's identifier as a string that is the same on every launch: encoded
    /// with its keys in a fixed order, since the same identifier encoded twice must
    /// give the same string.
    private static func identifierKey(for meeting: Meeting) -> String? {
        let id = meeting.persistentModelID
        if let known = keys[id] { return known }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = (try? encoder.encode(id))?.base64EncodedString()
        keys[id] = key
        return key
    }

    /// Identifier keys already worked out. The list asks for every meeting's on
    /// every redraw.
    private static var keys: [PersistentIdentifier: String] = [:]
}
