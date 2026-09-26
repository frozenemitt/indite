import AppKit
import ApplicationServices

/// Names and jargon on screen in the app being dictated into, read through the same
/// Accessibility access that pastes the text.
///
/// Replying to a thread about Coursera and Reframe It, those names are in the window
/// even when they are not on the vocabulary list. Only unusual words are kept: every
/// extra word the spotter listens for is another chance to swap in a wrong one.
///
/// The text is read, reduced to those words, and dropped. Nothing is stored.
enum ScreenVocabulary {

    struct Reading: Sendable {
        let terms: [String]
        let characters: Int
        let elements: Int
        let milliseconds: Int
    }

    /// Unusual words in the focused window of the app with this process identifier.
    ///
    /// Bounded three ways, so a large or slow window cannot hold anything up: elements
    /// visited, characters read and time spent.
    static func read(processIdentifier: pid_t, maxElements: Int = 4000, maxCharacters: Int = 40_000,
                     budget: Duration = .milliseconds(400), maxTerms: Int = 40) -> Reading {
        let clock = ContinuousClock()
        let start = clock.now
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)

        var texts: [String] = []
        var characters = 0
        var visited = 0
        var queue: [AXUIElement] = []
        if let window = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            queue.append(window as! AXUIElement)
        }
        var head = 0
        while head < queue.count, visited < maxElements, characters < maxCharacters, clock.now - start < budget {
            let element = queue[head]
            head += 1
            visited += 1
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = attribute(element, name) as? String, !text.isEmpty {
                    texts.append(text)
                    characters += text.count
                }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        let terms = unusualWords(in: texts.joined(separator: "\n"), limit: maxTerms)
        return Reading(terms: terms, characters: characters, elements: visited,
                       milliseconds: Int((clock.now - start) / .milliseconds(1)))
    }

    // MARK: - Picking the words

    /// Words that look like names or jargon, most frequent first.
    ///
    /// Kept: mixed case (TypeScript, NorAI), letters with digits (B2B), and capitalised
    /// words whose lower-case form is not an ordinary English word (Lilia, Coursera,
    /// Claude). A run of capitalised words holding one of those is kept as one name as
    /// well (Drishti Quest). Days and months are left out: they are capitalised
    /// everywhere and never misheard.
    static func unusualWords(in text: String, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for line in text.split(whereSeparator: { ".?!\n".contains($0) }) {
            let words = line.split(whereSeparator: { $0.isWhitespace || ",;:()[]{}\"“”".contains($0) })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'’-")) }
                .filter { !$0.isEmpty }
            var run: [String] = []
            var runHasUnusual = false
            func closeRun() {
                // "The B2B pilot", "Hi Jonathan": a capital that only opens the sentence.
                while let first = run.first, commonWords.contains(first.lowercased()) { run.removeFirst() }
                if run.count > 1, run.count <= 3, runHasUnusual { counts[run.joined(separator: " "), default: 0] += 1 }
                run = []; runHasUnusual = false
            }
            for word in words {
                let unusual = isUnusual(word)
                if unusual { counts[word, default: 0] += 1 }
                if word.first?.isUppercase == true {
                    run.append(word)
                    runHasUnusual = runHasUnusual || unusual
                } else {
                    closeRun()
                }
            }
            closeRun()
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    private static func isUnusual(_ word: String) -> Bool {
        guard word.count >= 3, word.contains(where: \.isLetter) else { return false }
        if word.contains(where: \.isNumber) { return true }
        if word.dropFirst().contains(where: \.isUppercase), word.contains(where: \.isLowercase) { return true }
        guard word.first?.isUppercase == true else { return false }
        let lower = word.lowercased()
        return !commonWords.contains(lower) && !calendarWords.contains(lower)
    }

    private static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]

    /// Ordinary English words: the lower-case entries of the system word list. Proper
    /// nouns are listed there with a capital, so "Claude" and "Maine" are not in it.
    private static let commonWords: Set<String> = {
        guard let list = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(list.split(separator: "\n").lazy.filter { $0.first?.isLowercase == true }.map(String.init))
    }()

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
