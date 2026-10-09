import AppKit
import ApplicationServices
import os
import UserNotifications

/// Notices a name the user corrects by hand after Indite typed it, and offers to put
/// it on the Words list.
///
/// For two minutes after each dictation, the field it went into is read every two
/// seconds, whichever app is in front: the field is read directly, not the app the
/// user is looking at. A word of the dictation changed into a name, "Pria" into "Priya", is a
/// mishearing the user fixed; on the Words list the recognizer listens for it next
/// time. Only one or two words swapped for one name count, and the name has to be
/// spelled like what it replaced: rewording a phrase, or typing on after the
/// dictation, is not a correction.
@MainActor
final class CorrectionWatcher {

    static let shared = CorrectionWatcher()

    /// Marks the suggestions, so the notification delegate can hand answers back here.
    nonisolated static let category = "word-correction"
    private static let addAction = "add"

    /// Names the user said no to, lower-cased, so the same one is not offered again.
    private static let declinedKey = "declinedWordSuggestions"

    private static let log = Logger(subsystem: "com.indite.app", category: "Corrections")

    /// The app's settings, whose Words list a name goes on. Set at launch.
    var settings: AppSettings?

    private var watching: Task<Void, Never>?

    private init() {
        let add = UNNotificationAction(identifier: Self.addAction, title: "Add to Words", options: [])
        let category = UNNotificationCategory(
            identifier: Self.category, actions: [add], intentIdentifiers: [], options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Watch the field a dictation just went into. A later dictation takes over.
    func watch(_ insertion: TextInsertionService.LastInsertion) {
        watching?.cancel()
        let field = Field(element: insertion.field)
        let typed = insertion.text
        let app = insertion.appName
        watching = Task { [weak self] in
            // A read can land in the middle of typing, when "Pria" has become "Priy".
            // Only a correction found on two reads in a row is offered.
            var seen = Finding.none
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // Off the main thread: an app slow to answer would otherwise hold Indite.
                guard let now = await Task.detached(priority: .utility, operation: { field.text() }).value else { return }
                let finding = Self.correction(of: typed, in: now)
                switch finding {
                case .none:
                    seen = .none
                case .gone:
                    return
                case .found(let heard, let name):
                    guard finding == seen else { seen = finding; continue }
                    self?.suggest(name, heard: heard, app: app)
                    return
                }
            }
        }
    }

    // MARK: - Spotting

    enum Finding: Equatable {
        case none
        /// Most of the dictation is no longer in the field: sent, cleared or rewritten.
        case gone
        case found(heard: String, name: String)
    }

    /// A name the user put in place of words Indite typed, if the field has one.
    static func correction(of typed: String, in field: String) -> Finding {
        let said = WordGuard.words(in: typed)
        let now = WordGuard.words(in: field)
        guard !said.isEmpty, now.count <= 5000 else { return .gone }

        let steps = WordGuard.alignment(said.map(\.key), now.map(\.key))
        let isSame: (WordGuard.Step) -> Bool = { if case .same = $0 { true } else { false } }
        guard steps.filter(isSame).count * 2 >= said.count else { return .gone }

        for (position, step) in steps.enumerated() {
            guard case .changed(let saidIndexes, let nowIndexes) = step, (1...2).contains(saidIndexes.count) else { continue }
            // At either end of the dictation, the field carries on with text of its
            // own; only the word that took the dictation's place can be the fix.
            let atStart = !steps[..<position].contains(where: isSame)
            let atEnd = !steps[(position + 1)...].contains(where: isSame)
            let replacing = atStart ? Array(nowIndexes.suffix(1)) : atEnd ? Array(nowIndexes.prefix(1)) : nowIndexes
            guard replacing.count == 1 else { continue }

            let heard = saidIndexes.map { said[$0].text.trimmingCharacters(in: .punctuationCharacters) }
                .joined(separator: " ")
            let name = now[replacing[0]].text.trimmingCharacters(in: .punctuationCharacters)
            guard Vocabulary.key(heard) != Vocabulary.key(name),
                  Vocabulary.similarity(heard, name) >= 0.4,
                  !ScreenVocabulary.unusualWords(in: name, limit: 1).isEmpty else { continue }
            return .found(heard: heard, name: name)
        }
        return .none
    }

    // MARK: - Asking

    private func suggest(_ name: String, heard: String, app: String) {
        guard let settings else { return }
        let key = name.lowercased()
        guard !settings.vocabularyHints.contains(where: { $0.lowercased() == key }) else { return }
        let declined = UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []
        guard !declined.contains(key) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Add \u{201C}\(name)\u{201D} to your words?"
        content.body = "You changed \u{201C}\(heard)\u{201D} to \u{201C}\(name)\u{201D} in \(app). On your Words list, Indite listens for it next time."
        content.categoryIdentifier = Self.category
        content.userInfo = ["name": name]
        // One identifier for all of them, so a new suggestion replaces an unanswered one.
        let request = UNNotificationRequest(identifier: Self.category, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
        Self.log.notice("Offered a name corrected by hand in \(app, privacy: .public)")
    }

    /// The answer to a suggestion: the button or a click on it adds the name, closing
    /// it says no for good.
    func respond(name: String?, action: String) {
        guard let name, let settings else { return }
        switch action {
        case Self.addAction, UNNotificationDefaultActionIdentifier:
            guard !settings.vocabularyHints.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
            settings.vocabularyHints.append(name)
            Self.log.notice("Added a corrected name to the Words list")
        case UNNotificationDismissActionIdentifier:
            var declined = UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []
            declined.append(name.lowercased())
            UserDefaults.standard.set(declined, forKey: Self.declinedKey)
            Self.log.notice("A corrected name was declined")
        default:
            break
        }
    }
}

/// A field to read from another thread. Accessibility elements may be used from any
/// thread; the type just does not say so.
private struct Field: @unchecked Sendable {
    let element: AXUIElement

    func text() -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
