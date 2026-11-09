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
    @discardableResult
    static func record(
        text: String,
        rawText: String?,
        destination: String?,
        promptName: String?,
        spokenDuration: TimeInterval?,
        settings: AppSettings,
        in context: ModelContext
    ) -> Dictation? {
        guard settings.keepDictationHistory else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let entry = Dictation(
            text: text,
            rawText: rawText == text ? nil : rawText,
            destination: destination,
            promptName: promptName,
            spokenDuration: spokenDuration
        )
        context.insert(entry)

        prune(to: settings.dictationHistoryLimit, in: context)
        context.saveOrLog()
        return entry
    }

    /// Drop the oldest entries beyond `limit`.
    static func prune(to limit: Int, in context: ModelContext) {
        guard limit > 0 else { return }

        // Uncapped on purpose: a fetch limited to N entries can never contain an
        // entry past N, so the highest limit the user can pick would never prune.
        let descriptor = FetchDescriptor<Dictation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        guard let entries = try? context.fetch(descriptor), entries.count > limit else { return }

        for entry in entries.dropFirst(limit) {
            context.delete(entry)
        }
        log.debug("Pruned history to \(limit)")
    }

    /// Remove everything.
    static func clear(in context: ModelContext) {
        guard let entries = try? context.fetch(FetchDescriptor<Dictation>()) else { return }
        for entry in entries {
            context.delete(entry)
        }
        context.saveOrLog()
    }

    // MARK: - Totals

    /// What the dictations kept add up to, for the line at the top of Recent Dictations.
    ///
    /// Only the dictations still kept are counted. A history trimmed to its limit has
    /// dropped the words and the days of everything older, so the words are given with
    /// the date they are counted from.
    struct Totals {
        /// Words in every dictation kept.
        var words: Int
        /// When the oldest dictation kept was made.
        var since: Date
        /// Words in the dictations kept from this week.
        var wordsThisWeek: Int
        /// When this week began, by the Mac's calendar and its first day of the week.
        var weekBegan: Date
        /// Words a minute over the dictations that know how long they were spoken, or
        /// nil while none does.
        var wordsPerMinute: Int?
        /// Days in a row with a dictation, counted back from today. A day with none yet
        /// does not end the run until it is over.
        var daysInARow: Int
    }

    /// Add up the dictations, or nil when there are none.
    ///
    /// Words are counted as they were heard, before any AI pass and before snippets are
    /// expanded, because the speed is the speaker's, and neither the rewrite nor a
    /// snippet's saved text is.
    static func totals(of dictations: [Dictation], now: Date = .now, calendar: Calendar = .current) -> Totals? {
        guard let since = dictations.map(\.createdAt).min() else { return nil }
        let today = calendar.startOfDay(for: now)
        let weekBegan = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today

        var words = 0
        var wordsThisWeek = 0
        var timedWords = 0
        var timedSeconds: TimeInterval = 0
        var daysAgo: Set<Int> = []
        for dictation in dictations {
            let count = wordCount(dictation.rawText ?? dictation.text)
            words += count
            if dictation.createdAt >= weekBegan {
                wordsThisWeek += count
            }
            if let seconds = dictation.spokenDuration {
                timedWords += count
                timedSeconds += seconds
            }
            let day = calendar.startOfDay(for: dictation.createdAt)
            if let days = calendar.dateComponents([.day], from: day, to: today).day {
                daysAgo.insert(days)
            }
        }

        // Back from today, or from yesterday while today has none yet.
        var daysInARow = 0
        var day = daysAgo.contains(0) ? 0 : 1
        while daysAgo.contains(day) {
            daysInARow += 1
            day += 1
        }

        return Totals(
            words: words,
            since: since,
            wordsThisWeek: wordsThisWeek,
            weekBegan: weekBegan,
            wordsPerMinute: timedSeconds > 0 ? Int((Double(timedWords) * 60 / timedSeconds).rounded()) : nil,
            daysInARow: daysInARow
        )
    }

    /// Words in a text, by the spaces between them. A mark of punctuation standing
    /// alone, such as a dash, is not a word.
    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count { $0.contains { $0.isLetter || $0.isNumber } }
    }
}
