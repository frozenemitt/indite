import Foundation
import SwiftData
import os

/// Records finished dictations and keeps the list from growing without bound.
///
/// Everything dictated is stored on disk in plain text, which is a real privacy
/// consideration even for an app that never sends anything anywhere. The user can turn
/// it off, and the number kept is theirs to choose.
@MainActor
enum DictationHistory {

    private static let log = Logger(subsystem: "com.indite.app", category: "History")

    /// Store a dictation and trim anything past the limit.
    ///
    /// Returns the stored entry, so a caller that keeps the words before delivering
    /// them can fill in where they went afterwards.
    ///
    /// - Parameter recordingFileName: The dictation's recording in
    ///   `DictationAudioStore`. It is deleted when the dictation is not kept, since a
    ///   recording is kept only with its entry.
    @discardableResult
    static func record(
        text: String,
        rawText: String?,
        destination: String?,
        promptName: String?,
        spokenDuration: TimeInterval?,
        recordingFileName: String? = nil,
        settings: AppSettings,
        in context: ModelContext
    ) -> Dictation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.keepDictationHistory, !trimmed.isEmpty else {
            DictationAudioStore.delete(fileNamed: recordingFileName)
            return nil
        }

        let entry = Dictation(
            text: text,
            rawText: rawText == text ? nil : rawText,
            destination: destination,
            promptName: promptName,
            spokenDuration: spokenDuration,
            recordingFileName: recordingFileName
        )
        context.insert(entry)
        noteDay(of: entry.createdAt, in: context)

        prune(to: settings.dictationHistoryLimit, in: context)
        expireRecordings(settings: settings, in: context)
        context.saveOrLog()
        return entry
    }

    /// Drop the oldest entries beyond `limit`, with their recordings.
    static func prune(to limit: Int, in context: ModelContext) {
        guard limit > 0 else { return }

        // Uncapped on purpose: a fetch limited to N entries can never contain an
        // entry past N, so the highest limit the user can pick would never prune.
        let descriptor = FetchDescriptor<Dictation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        guard let entries = try? context.fetch(descriptor), entries.count > limit else { return }

        // Their days are noted before they go, in case no day has been noted yet: a
        // lower limit picked in Settings can prune before this build keeps a dictation.
        _ = days(seedingFrom: entries)

        for entry in entries.dropFirst(limit) {
            // The recording is not owned by SwiftData, so deleting the entry does not
            // reach it.
            DictationAudioStore.delete(fileNamed: entry.recordingFileName)
            context.delete(entry)
        }
        log.debug("Pruned history to \(limit)")
    }

    /// Remove everything, recordings included, and the days with a dictation too:
    /// whoever clears the history means to leave nothing of it behind.
    static func clear(in context: ModelContext) {
        guard let entries = try? context.fetch(FetchDescriptor<Dictation>()) else { return }
        for entry in entries {
            DictationAudioStore.delete(fileNamed: entry.recordingFileName)
            context.delete(entry)
        }
        context.saveOrLog()
        // Emptied, not removed. A removed list is filled again from the dictations
        // kept, and a list on screen may not have let go of them yet.
        save(days: [])
    }

    // MARK: - Recordings

    /// Delete the recordings older than the days chosen in Settings. Their dictations
    /// keep their text. Nothing is deleted while "Keep forever" is on.
    ///
    /// Run at launch and after each dictation. Not when the number of days changes:
    /// typing 30 over 14 passes through 3 on the way, and the recordings deleted at 3
    /// would be gone for good.
    static func expireRecordings(settings: AppSettings, in context: ModelContext, now: Date = .now) {
        guard !settings.keepDictationRecordingsForever else { return }
        let recordingDays = max(1, settings.dictationRecordingDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -recordingDays, to: now) ?? now
        let expired = FetchDescriptor<Dictation>(predicate: #Predicate { dictation in
            dictation.recordingFileName != nil && dictation.createdAt < cutoff
        })
        do {
            let entries = try context.fetch(expired)
            guard !entries.isEmpty else { return }
            for entry in entries {
                DictationAudioStore.delete(fileNamed: entry.recordingFileName)
                entry.recordingFileName = nil
            }
            log.notice("Deleted \(entries.count, privacy: .public) recordings older than \(recordingDays, privacy: .public) days")
        } catch {
            log.error("Could not look for recordings to delete: \(error, privacy: .public)")
        }
    }

    /// Put the recordings in order at launch: delete those past their days, and those no
    /// dictation names that have not been written for ten minutes.
    ///
    /// A recording no dictation names belongs to one that ended in a crash before it
    /// reached the history, whose file never closed and cannot be read, or to a
    /// dictation deleted while Indite was quitting. Run before the dictation key is
    /// armed, so no recording of this copy's can be under way. Another copy of Indite
    /// may be running, though, and a recording it is writing, or holds for Undo with a
    /// deleted dictation, is named by no dictation yet. Such a recording was written in
    /// the last ten minutes, so it is left alone.
    static func tidyRecordings(settings: AppSettings, in context: ModelContext) {
        expireRecordings(settings: settings, in: context)
        context.saveOrLog()

        // A store that fell back to memory holds no dictations, and every recording
        // would look like one nobody names.
        guard MeetingStoreStatus.shared.isPersistent else { return }
        let named = FetchDescriptor<Dictation>(predicate: #Predicate { $0.recordingFileName != nil })
        do {
            let kept = Set(try context.fetch(named).compactMap(\.recordingFileName))
            let deleted = DictationAudioStore.deleteRecordings(notNamedIn: kept, writtenBefore: Date.now.addingTimeInterval(-10 * 60))
            if deleted > 0 {
                log.notice("Deleted \(deleted, privacy: .public) recordings no dictation names")
            }
        } catch {
            // Without the names, every recording would look unnamed. Leave them all.
            log.error("Could not list the recordings dictations name: \(error, privacy: .public)")
        }
    }

    // MARK: - Totals

    /// What the dictations kept add up to, for the line at the top of Recent Dictations.
    ///
    /// The words and the speed count only the dictations still kept. A history trimmed
    /// to its limit has dropped the words of everything older, so the words are given
    /// with the date they are counted from. The days in a row are counted from the days
    /// noted apart from the history, which trimming leaves alone.
    struct Totals {
        /// Words in every dictation kept.
        var words: Int
        /// When the oldest dictation kept was made.
        var since: Date
        /// Words in the dictations kept from this week.
        var wordsThisWeek: Int
        /// When this week began, by the Mac's calendar and its first day of the week.
        var weekBegan: Date
        /// The median of the words a minute of each dictation that knows how long it
        /// was spoken and holds at least `fewestTimedWords` words, or nil while none
        /// does.
        var wordsPerMinute: Int?
        /// Days in a row with a dictation, counted back from today. A day with none yet
        /// does not end the run until it is over.
        var daysInARow: Int
    }

    /// The fewest words a dictation needs for its speed to count. In a dictation of a
    /// word or two, the moments before speaking and after it take up most of the time.
    static let fewestTimedWords = 5

    /// Add up the dictations, or nil when there are none.
    ///
    /// Words are counted as they were heard, before any AI pass, because the speed is
    /// the speaker's and the rewrite is not.
    ///
    /// - Parameter days: The days with a dictation, as `days(seedingFrom:)` gives them.
    static func totals(
        of dictations: [Dictation],
        days: Set<String>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Totals? {
        guard let since = dictations.map(\.createdAt).min() else { return nil }
        let today = calendar.startOfDay(for: now)
        let weekBegan = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today

        var words = 0
        var wordsThisWeek = 0
        var wordsPerMinute: [Double] = []
        for dictation in dictations {
            let count = wordCount(dictation.rawText ?? dictation.text)
            words += count
            if dictation.createdAt >= weekBegan {
                wordsThisWeek += count
            }
            if let seconds = dictation.spokenDuration, seconds > 0, count >= fewestTimedWords {
                wordsPerMinute.append(Double(count) * 60 / seconds)
            }
        }

        return Totals(
            words: words,
            since: since,
            wordsThisWeek: wordsThisWeek,
            weekBegan: weekBegan,
            // The median rather than all the words over all the time. One dictation
            // left listening until the length limit would otherwise drag the speed down
            // for as long as it is kept.
            wordsPerMinute: median(wordsPerMinute).map { Int($0.rounded()) },
            daysInARow: daysInARow(days, today: day(of: now, in: calendar.timeZone))
        )
    }

    /// Words in a text, by the spaces between them. A mark of punctuation standing
    /// alone, such as a dash, is not a word.
    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count { $0.contains { $0.isLetter || $0.isNumber } }
    }

    /// The middle value, or the mean of the middle two, or nil when there are none.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: - Days with a dictation

    /// Where the days with a dictation kept are noted, for the days in a row, as the
    /// date where each dictation was made: "2026-11-08". Nothing else about a
    /// dictation is noted.
    ///
    /// Kept apart from the history, which keeps the last 100 dictations by default. On
    /// a real Mac those reached back five days, and one busy day can trim away every
    /// day before it, so a run counted from the history alone could not reach past the
    /// oldest dictation kept.
    private static let daysKey = "dictationDays"

    /// The most days noted, a little over a year. A longer run is counted as this long.
    private static let daysKept = 400

    /// The days with a dictation kept. The first time, before any day has been noted,
    /// they are noted from `dictations`, the dictations kept then.
    static func days(seedingFrom dictations: @autoclosure () -> [Dictation]) -> Set<String> {
        if UserDefaults.standard.stringArray(forKey: daysKey) == nil {
            // Dated where the Mac is now: the history does not say where it was when
            // each dictation was made.
            save(days: Set(dictations().map { day(of: $0.createdAt, in: .current) }))
        }
        return Set(UserDefaults.standard.stringArray(forKey: daysKey) ?? [])
    }

    /// Note the day of a dictation just kept, where it was made.
    private static func noteDay(of date: Date, in context: ModelContext) {
        var noted = days(seedingFrom: (try? context.fetch(FetchDescriptor<Dictation>())) ?? [])
        noted.insert(day(of: date, in: .current))
        save(days: noted)
    }

    private static func save(days: Set<String>) {
        // The dates sort as text, oldest first, so the newest are kept.
        UserDefaults.standard.set(Array(days.sorted().suffix(daysKept)), forKey: daysKey)
    }

    /// The date of a moment in a time zone, as "2026-11-08".
    static func day(of date: Date, in timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }

    /// How many days in a row `days` holds, back from `today`, or from the day before
    /// while today has none yet.
    ///
    /// The dates are stepped back one at a time in GMT, where every day is 24 hours
    /// long. Counting the hours between the starts of two days broke the run in a zone
    /// whose clocks jump at midnight: in Santiago, 6 September 2026 begins at 1:00,
    /// 23 hours before 7 September, and so counted as no days before it.
    static func daysInARow(_ days: Set<String>, today: String) -> Int {
        let style = Date.ISO8601FormatStyle().year().month().day()
        var gmt = Calendar(identifier: .gregorian)
        gmt.timeZone = .gmt
        guard var day = try? style.parse(today) else { return 0 }

        if !days.contains(today), let yesterday = gmt.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var run = 0
        while days.contains(style.format(day)), let before = gmt.date(byAdding: .day, value: -1, to: day) {
            run += 1
            day = before
        }
        return run
    }
}
