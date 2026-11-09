import AppKit
import ApplicationServices
import os
import UserNotifications

/// Learns a name the user corrects by hand after Indite typed it, the way Wispr Flow
/// does, and puts it on the Words list.
///
/// For a minute after each dictation, the field it went into is watched (`FieldWatch`).
/// The field's text on either side of the dictation marks where its words are, and what
/// lies between is the dictation as it stands. The latest version that corrects what
/// was pasted, rather than rewriting it, and stayed unchanged for a second is kept and
/// judged once, when the watch ends.
///
/// A word of the dictation changed into a name, "Pria" into "Priya", is a mishearing the
/// user fixed; on the Words list the recognizer listens for it next time. Only one word
/// swapped for one counts, and the name has to be spelled like the word it replaced and
/// be no ordinary English word. Indite adds it without asking and says so in a
/// notification, whose Undo takes it back for good.
@MainActor
final class CorrectionWatcher {

    static let shared = CorrectionWatcher()

    /// Marks the notifications, so the notification delegate can hand answers back here.
    nonisolated static let category = "word-correction"
    private static let undoAction = "undo"

    /// Names the user turned down, lower-cased, from when Indite asked before adding
    /// one. They are never added.
    private static let declinedKey = "declinedWordSuggestions"

    /// Names Indite added on its own, lower-cased. One that is no longer on the Words
    /// list was taken off by the user, with Undo or by deleting it, and is never added
    /// again.
    private static let addedKey = "addedWordSuggestions"

    private static let log = Logger(subsystem: "com.indite.app", category: "Corrections")

    /// The app's settings, whose Words list a name goes on. Set at launch.
    var settings: AppSettings?

    /// The watch under way. The next dictation ends it.
    private var current: FieldWatch?

    private init() {
        let undo = UNNotificationAction(identifier: Self.undoAction, title: "Undo", options: [])
        let category = UNNotificationCategory(
            identifier: Self.category, actions: [undo], intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Watch the field a dictation just went into.
    func watch(_ insertion: TextInsertionService.LastInsertion) {
        // Without the text around the words, nothing says where they are later.
        guard let around = insertion.around else {
            Self.log.notice("Not watching \(insertion.appName, privacy: .public) for corrections: it did not report the text around the cursor")
            return
        }
        let app = insertion.appName
        let length = around.before.utf16.count + insertion.pasted.utf16.count + around.after.utf16.count
        guard length <= FieldWatch.longestField else {
            Self.log.notice("Not watching \(app, privacy: .public) for corrections: its field holds \(length, privacy: .public) characters, more than \(FieldWatch.longestField, privacy: .public)")
            return
        }
        let anchors = FieldWatch.Anchors(before: around.before, pasted: insertion.pasted, after: around.after)
        let watch = FieldWatch(field: insertion.field, anchors: anchors) { [weak self] watch, result in
            Task { @MainActor in await self?.judge(watch, result, app: app) }
        }
        current?.end(.nextDictation)
        current = watch
        watch.start()
    }

    /// End the watch under way, because the next dictation has started. Its words may
    /// land in the same field, so the last one's are judged as they stand now.
    func stopWatching() {
        current?.end(.nextDictation)
    }

    // MARK: - Judging

    struct Candidate: Equatable {
        /// The word as pasted.
        let heard: String
        /// The word the user put in its place.
        let word: String
    }

    /// Judge a dictation's last copy once its watch has ended, add the names the user
    /// corrected, and log how the watch went: counts and seconds, never the text.
    private func judge(_ watch: FieldWatch, _ result: FieldWatch.Result, app: String) async {
        if current === watch { current = nil }
        // Asked before the Words list is read, so the wait cannot leave the list stale.
        let permission = result.copy == nil ? nil : await UNUserNotificationCenter.current().notificationSettings()
        var candidates: [Candidate] = []
        var names: [Candidate] = []
        var added = 0
        if let copy = result.copy, let settings, let permission {
            let defaults = UserDefaults.standard
            let known = settings.vocabularyHints + (defaults.stringArray(forKey: Self.declinedKey) ?? [])
                + (defaults.stringArray(forKey: Self.addedKey) ?? [])
            candidates = Self.candidates(pasted: watch.anchors.pasted, copy: copy, excluding: Set(known.map(Vocabulary.key)))
            names = Self.names(among: candidates)
            // A name is added with a notification that says so and offers Undo, or not
            // at all: added unseen, it could not be taken back.
            if !names.isEmpty, let blocked = Self.whyNoNotification(
                status: permission.authorizationStatus, banners: permission.alertStyle != .none,
                notificationCenter: permission.notificationCenterSetting == .enabled
            ) {
                Self.log.notice("Added none of \(names.count, privacy: .public) names, because \(blocked, privacy: .public): a name added without a notification has no Undo")
            } else {
                add(names, app: app)
                added = names.count
            }
        }
        let words = !result.found ? "never found" : result.copy == nil ? "found, none unchanged for a second" : "found"
        Self.log.notice("""
            Watched \(app, privacy: .public) for \(result.seconds, format: .fixed(precision: 1), privacy: .public) s \
            until \(result.ending.rawValue, privacy: .public): \
            \(result.notifications, privacy: .public) notifications, \(result.reads, privacy: .public) reads, \
            words \(words, privacy: .public), \
            \(candidates.count, privacy: .public) candidates, \(names.count, privacy: .public) names, \
            \(added, privacy: .public) added
            """)
    }

    /// Words the user typed in place of single words of the dictation, names first.
    ///
    /// Only one word for one counts, with the words on either side unchanged. Left out
    /// are common words, words in `known` as `Vocabulary.key` writes them, words that
    /// end in a contraction such as 's or 'll, and words with a digit. A word keeps only
    /// its letters, apostrophes and hyphens.
    nonisolated static func candidates(pasted: String, copy: String, excluding known: Set<String>) -> [Candidate] {
        let said = WordGuard.words(in: pasted)
        let now = WordGuard.words(in: copy)
        var found: [Candidate] = []
        for step in WordGuard.alignment(said.map(\.key), now.map(\.key)) {
            // The alignment closes a gap at a word both texts share, or at the text
            // around the dictation, so the words beside a gap are unchanged.
            guard case .changed(let saidIndexes, let nowIndexes) = step,
                  saidIndexes.count == 1, nowIndexes.count == 1 else { continue }
            let typed = now[nowIndexes[0]]
            // "5th", "B13" and "FY25" pass the name test, and on the Words list they would
            // be chosen over the recognizer's first guess. A name has no digits.
            guard !typed.key.contains(where: \.isNumber) else { continue }
            // An emoji or a mark typed onto the name stays off the Words list, which would
            // otherwise type it into every later dictation of the name: "Priya🙏" is Priya.
            // Apostrophes and hyphens stay inside a name such as O'Brien or Jean-Luc.
            let word = String(typed.text.filter { $0.isLetter || "'’-".contains($0) })
                .trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
            guard !word.isEmpty,
                  !WordGuard.commonWords.contains(typed.key),
                  !["'s", "'ll", "'re", "'ve", "'d", "'m", "'t"].contains(where: typed.key.hasSuffix),
                  !known.contains(Vocabulary.key(word)),
                  !found.contains(where: { Vocabulary.key($0.word) == Vocabulary.key(word) }) else { continue }
            let heard = said[saidIndexes[0]].text.trimmingCharacters(in: .punctuationCharacters)
            found.append(Candidate(heard: heard, word: word))
        }
        let capitalized = found.filter { $0.word.first?.isUppercase == true }
        return capitalized + found.filter { $0.word.first?.isUppercase != true }
    }

    /// The candidates that pass `isMisheardName`, at most four. They are tested before
    /// they are cut to four, so that words failing the test cannot crowd a name out.
    static func names(among candidates: [Candidate]) -> [Candidate] {
        Array(candidates.filter { isMisheardName($0.heard, as: $0.word) }.prefix(4))
    }

    /// Whether `word`, typed over `heard`, is a name the recognizer misheard: spelled
    /// like it, and no ordinary English word. This is Indite's own test from when it
    /// asked first; Wispr Flow asks a model on its servers instead.
    static func isMisheardName(_ heard: String, as word: String) -> Bool {
        Vocabulary.key(heard) != Vocabulary.key(word)
            && Vocabulary.similarity(heard, word) >= 0.4
            && !ScreenVocabulary.unusualWords(in: word, limit: 1).isEmpty
    }

    // MARK: - Adding

    /// Why a notification from Indite would not reach the user, or nil when it would:
    /// allowed, and shown as a banner or kept in Notification Center.
    static func whyNoNotification(status: UNAuthorizationStatus, banners: Bool, notificationCenter: Bool) -> String? {
        switch status {
        case .authorized, .provisional:
            return banners || notificationCenter ? nil : "Indite's banners are set to None and Notification Center leaves it out"
        case .denied:
            return "notifications are turned off for Indite"
        case .notDetermined:
            return "Indite has not been allowed notifications yet"
        @unknown default:
            return "Indite's notification permission is of a kind it does not know"
        }
    }

    /// Put the names on the Words list, and say so in a notification with an Undo.
    private func add(_ names: [Candidate], app: String) {
        guard let settings, !names.isEmpty else { return }
        settings.vocabularyHints += names.map(\.word)
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: Self.addedKey) ?? []) + names.map { $0.word.lowercased() },
                     forKey: Self.addedKey)

        let quoted = { (text: String) in "\u{201C}\(text)\u{201D}" }
        let changes = names.map { "\(quoted($0.heard)) to \(quoted($0.word))" }
        let content = UNMutableNotificationContent()
        content.title = "Added \(ListFormatter.localizedString(byJoining: names.map { quoted($0.word) })) to your words"
        content.body = """
            You changed \(ListFormatter.localizedString(byJoining: changes)) in \(app). \
            On your Words list, Indite listens for \(names.count == 1 ? "it" : "them") next time.
            """
        content.categoryIdentifier = Self.category
        content.userInfo = ["names": names.map(\.word)]
        // One identifier for all of them, so a new notification replaces the last.
        let request = UNNotificationRequest(identifier: Self.category, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    /// The answer to a notification. Undo takes the names off the Words list. They stay
    /// among the names added before, which keeps them from being added again.
    func respond(names: [String], action: String) {
        guard action == Self.undoAction, let settings else { return }
        let keys = Set(names.map(Vocabulary.key))
        settings.vocabularyHints.removeAll { keys.contains(Vocabulary.key($0)) }
        Self.log.notice("Took \(names.count, privacy: .public) added names back off the Words list")
    }
}

// MARK: - Watching a Field

/// One dictation's field, watched for a minute on a thread of its own, so that an app
/// slow to answer holds up that thread and never Indite.
///
/// The field is read whenever it posts a change, and once a second besides for apps
/// that post nothing, as Wispr Flow does. The field is read directly, so moving the
/// focus or switching apps does not end the watch.
///
/// Unchecked: the watch's state belongs to its thread, apart from what `end` touches,
/// which the lock guards. Accessibility elements may be used from any thread.
final class FieldWatch: @unchecked Sendable {

    /// The words as pasted, and the field's text on either side of them then.
    struct Anchors: Sendable {
        let before: String
        let pasted: String
        let after: String

        /// Kept with plain spaces for no-break ones, as every read of the field is.
        init(before: String, pasted: String, after: String) {
            self.before = FieldWatch.plainSpaces(before)
            self.pasted = FieldWatch.plainSpaces(pasted)
            self.after = FieldWatch.plainSpaces(after)
        }
    }

    /// Why a watch ended, as the log says it.
    enum Ending: String, Sendable {
        case emptied = "the field emptied"
        case newLine = "a new line followed the words"
        case anchorsChanged = "the text around the words changed"
        case wordsDeleted = "the words were deleted"
        case closed = "the field closed"
        case tooLong = "the field grew past 20,000 characters"
        case nextDictation = "the next dictation started"
        case timeUp = "the minute was up"
    }

    struct Result: Sendable {
        let ending: Ending
        let seconds: Double
        /// The dictation's last copy that corrects what was pasted rather than
        /// rewriting it and stayed unchanged for a second. Nil when none did.
        let copy: String?
        /// Whether any read found the dictation, as pasted or corrected.
        let found: Bool
        let notifications: Int
        let reads: Int
    }

    /// How long a watch lasts, in seconds, as Wispr Flow's does.
    static let duration: Double = 60

    /// The longest field watched, in characters as accessibility counts them. Every
    /// change in the field is a read and a comparison of all of its text.
    static let longestField = 20_000

    /// How long a copy has to stay unchanged to be judged, in seconds: a second, less
    /// the slack of the timer that reads the field once a second. A copy that changed
    /// sooner may be a word caught halfway through being typed, "Priy" on its way to
    /// "Priya".
    static let steady: Double = 0.9

    let anchors: Anchors
    private let field: AXUIElement
    private let finish: @Sendable (FieldWatch, Result) -> Void

    // Shared with whoever ends the watch early, under the lock.
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var requested: Ending?
    private var isOver = false

    // The watch thread's own.
    private var ending: Ending?
    private var copies: Copies
    private var notifications = 0
    private var reads = 0
    private var pendingRead: CFRunLoopTimer?
    /// When the field posted the first change not read yet.
    private var changedAt: Double?

    /// - Parameter finish: Called once on the watch's thread when it ends.
    init(field: AXUIElement, anchors: Anchors, finish: @escaping @Sendable (FieldWatch, Result) -> Void) {
        self.field = field
        self.anchors = anchors
        self.copies = Copies(anchors: anchors)
        self.finish = finish
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Correction watch"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// End the watch now, from any thread. Its copy is judged as at any ending.
    func end(_ reason: Ending) {
        lock.withLock {
            guard !isOver else { return }
            guard let runLoop else { requested = reason; return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in stopUnread(reason) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func run() {
        let started = ProcessInfo.processInfo.systemUptime
        let loop = CFRunLoopGetCurrent()

        // The changes the field posts. An app may post none, or refuse to; the reads
        // once a second cover both.
        var observer: AXObserver?
        var pid: pid_t = 0
        var registered: [String] = []
        let me = Unmanaged.passUnretained(self).toOpaque()
        if AXUIElementGetPid(field, &pid) == .success,
           AXObserverCreate(pid, { _, _, notification, me in
               guard let me else { return }
               Unmanaged<FieldWatch>.fromOpaque(me).takeUnretainedValue().posted(notification as String)
           }, &observer) == .success, let observer {
            registered = [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXUIElementDestroyedNotification]
                .filter { AXObserverAddNotification(observer, field, $0 as CFString, me) == .success }
            CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        let ticker = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0) { [self] _ in read() }
        CFRunLoopAddTimer(loop, ticker, .defaultMode)

        lock.withLock {
            runLoop = loop
            ending = requested
        }
        read()
        while ending == nil {
            let left = Self.duration - (ProcessInfo.processInfo.systemUptime - started)
            guard left > 0 else { stopUnread(.timeUp); break }
            CFRunLoopRunInMode(.defaultMode, left, true)
        }

        CFRunLoopTimerInvalidate(ticker)
        if let pendingRead {
            CFRunLoopTimerInvalidate(pendingRead)
            self.pendingRead = nil
        }
        if let observer {
            for name in registered { AXObserverRemoveNotification(observer, field, name as CFString) }
            CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        lock.withLock {
            runLoop = nil
            isOver = true
        }
        finish(self, Result(ending: ending ?? .timeUp, seconds: ProcessInfo.processInfo.systemUptime - started,
                            copy: copies.settled, found: copies.found, notifications: notifications, reads: reads))
    }

    private func posted(_ notification: String) {
        notifications += 1
        if notification == kAXUIElementDestroyedNotification {
            stopUnread(.closed)
            return
        }
        changedAt = changedAt ?? ProcessInfo.processInfo.systemUptime
        // One read for a burst of changes, since the app answers every read on its main
        // thread. A letter put into a text view the way typing puts it, with the cursor
        // placed first, posted three changes in a test; one read answered all three.
        guard pendingRead == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.05, 0, 0, 0) { [self] _ in
            pendingRead = nil
            read()
        }
        pendingRead = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    }

    private func read() {
        guard ending == nil else { return }
        reads += 1
        // Taken as the read is asked for, so the reads once a second stay a second apart
        // however long the app takes to answer each.
        let time = ProcessInfo.processInfo.systemUptime
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        // Gone with its window or its app.
        if status == .invalidUIElement {
            stop(.closed)
            return
        }
        // Busy, or no text this time; the next read will tell.
        guard status == .success, let text = value as? String else { return }
        let changed = changedAt
        changedAt = nil
        if let ending = copies.read(text, at: time, changedAt: changed) { stop(ending) }
    }

    private func stop(_ reason: Ending) {
        guard ending == nil else { return }
        ending = reason
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    /// End the watch with no read to show how the field stands. A field that posts its
    /// changes has posted none since its last read, or one not read yet, so the copy
    /// that read found stayed until now, or until that change. A field that posts
    /// nothing tells nothing.
    private func stopUnread(_ reason: Ending) {
        guard ending == nil else { return }
        if notifications > 0 { copies.stayed(until: changedAt ?? ProcessInfo.processInfo.systemUptime) }
        stop(reason)
    }

    // MARK: - Reading

    /// The copies of the dictation that the reads of its field find, and the one to
    /// judge. Apart from the field, so it can be run on sample texts.
    ///
    /// Only a copy that stayed unchanged for a second is judged. In an app read once a
    /// second, "Pria" retyped as "Priya" and sent straight after could otherwise be
    /// judged as "Priy", the copy the last read caught. A copy is known to have stayed
    /// from the read that found it until a later read that still finds it, or, in a
    /// field that posts its changes, until the field posts the next one. When the last
    /// copy stayed too briefly, the one before it that stayed is judged.
    struct Copies {
        let anchors: Anchors

        /// The latest copy that corrects what was pasted, rather than rewriting it, and
        /// stayed unchanged for a second. A fix followed by a rewrite keeps the fix.
        private(set) var settled: String?
        /// Whether a read has found the dictation, as pasted or corrected.
        private(set) var found = false

        /// What the last read found between the anchors, when a read first found it,
        /// and until when it is known to have stayed.
        private var shown: String?
        private var shownIsClose = false
        private var since = 0.0
        private var until = 0.0

        init(anchors: Anchors) {
            self.anchors = anchors
        }

        /// Take in a read of the field's text, made at `time`, and say why the watch
        /// ends, if it ends here.
        ///
        /// - Parameter changedAt: When the field posted the change this read answers,
        ///   if it posted one.
        mutating func read(_ text: String, at time: Double, changedAt: Double?) -> Ending? {
            guard text.utf16.count <= FieldWatch.longestField else { return .tooLong }
            let reading = FieldWatch.reading(text, around: anchors, found: found)
            if reading.words == shown {
                stayed(until: time)
            } else {
                // A field that posts its changes had the last copy until it posted this one.
                if let changedAt { stayed(until: changedAt) }
                shown = reading.words
                shownIsClose = reading.words.map { FieldWatch.isClose($0, to: anchors.pasted) } ?? false
                since = time
                until = time
                found = found || shownIsClose
            }
            // The words before a new line are finished: the user has gone on past them.
            if reading.ending == .newLine, shownIsClose { settled = shown }
            return reading.ending
        }

        /// The copy the last read found stayed until `time`, as far as the watch knows.
        mutating func stayed(until time: Double) {
            until = max(until, time)
            if shownIsClose, until - since >= FieldWatch.steady { settled = shown }
        }
    }

    /// What one read of the field finds: the dictation as it stands there, and the
    /// reason the watch ends, if it ends here.
    ///
    /// The field has to start with the text that was before the dictation and end with
    /// the text that was after it; what lies between is the dictation as it stands. Nil
    /// when the read does not find it.
    ///
    /// Until a read has found the dictation, a read without it is a field that has not
    /// caught up with the paste, and the watch goes on: Electron fields report their
    /// text late (see `TextInsertionService.pasteLanded`), and an empty chat box read
    /// too soon would otherwise look sent.
    static func reading(_ field: String, around anchors: Anchors, found: Bool) -> (words: String?, ending: Ending?) {
        let field = plainSpaces(field)
        // Sent, or cleared.
        guard field.contains(where: { !$0.isWhitespace }) else { return (nil, found ? .emptied : nil) }
        guard field.hasPrefix(anchors.before), field.hasSuffix(anchors.after) else {
            return (nil, found ? .anchorsChanged : nil)
        }
        var words = String(field.dropFirst(anchors.before.count).dropLast(anchors.after.count))
        guard words.contains(where: { $0.isLetter || $0.isNumber }) else { return (nil, found ? .wordsDeleted : nil) }

        // A line break the dictation did not have: the user went on to a new line. What
        // comes before it is still the dictation.
        var ending: Ending?
        let breaks = anchors.pasted.filter(\.isNewline).count
        if let cut = words.indices.filter({ words[$0].isNewline }).dropFirst(breaks).first {
            words = String(words[..<cut])
            ending = .newLine
        }
        return (words, ending)
    }

    /// `text` with each no-break space made a plain one, so that the two match. An
    /// editor may turn one into the other at the edge of the words: a space before the
    /// cursor shown as a no-break one, so that it does not collapse, becomes a plain one
    /// once the words follow it, and the text before them no longer matches.
    static func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Whether `words` is the dictation corrected rather than rewritten, by Wispr Flow's
    /// limit on the edits between the two over the longer. A short dictation may change
    /// more than a long one: the limit is 0.5 for 10 characters pasted, 0.4 for 30 and
    /// 0.24 for 300.
    static func isClose(_ words: String, to pasted: String) -> Bool {
        let a = Array(words), b = Array(pasted)
        let longer = max(a.count, b.count)
        guard longer > 0 else { return true }
        let limit = 0.4 / (1 + Double(b.count) / 30) + 0.2
        // Words typed on after the dictation pass the limit on length alone.
        guard Double(abs(a.count - b.count)) / Double(longer) < limit else { return false }
        // Counted no further than the most edits the limit allows: past that, the answer
        // is no.
        guard let edits = edits(a, b, atMost: Int(limit * Double(longer)) + 1) else { return false }
        return Double(edits) / Double(longer) < limit
    }

    /// The insertions, deletions and substitutions that turn `a` into `b`, or nil when
    /// there are more than `most`.
    ///
    /// The work grows with the edits found, not with the lengths multiplied: each count of
    /// edits takes every diagonal of the edit table as far as that count reaches, and
    /// runs along it while the two texts agree. In a dictation of 1,500 words with a name
    /// fixed at each end, a read took 0.1 ms; the whole table, counted between the ends
    /// the two texts share, took 0.27 s. The same words shuffled, far past the limit,
    /// took 18 ms.
    private static func edits(_ a: [Character], _ b: [Character], atMost most: Int) -> Int? {
        let n = a.count, m = b.count
        // The table ends on the diagonal of the difference in length.
        let last = m - n
        guard abs(last) <= most else { return nil }
        // For each diagonal d, where b's position less a's is d, the furthest position in
        // `a` reached with the edits counted so far, at index d + offset.
        let offset = most + 1
        let unreached = Int.min / 2
        var furthest = [Int](repeating: unreached, count: 2 * most + 3)
        var previous = furthest
        for count in 0...most {
            swap(&furthest, &previous)
            for d in max(-count, -n)...min(count, m) {
                // One more edit than `previous` counted: a substitution along the same
                // diagonal, a deletion from the one above, an insertion from the one below.
                var i = count == 0 ? 0 : max(previous[offset + d] + 1, previous[offset + d + 1] + 1, previous[offset + d - 1])
                i = min(i, n, m - d)
                while i < n, i + d < m, a[i] == b[i + d] { i += 1 }
                furthest[offset + d] = i
            }
            if furthest[offset + last] >= n { return count }
        }
        return nil
    }
}
