import Foundation
import NaturalLanguage

/// Fits a dictation to the text on either side of the cursor it is pasted at.
///
/// The recognizer writes every dictation as a whole sentence: a capital at the start,
/// a full stop at the end. All 100 dictations in one history began and ended that way,
/// and 96 reached the field exactly as the recognizer wrote them. Dictated onto the end
/// of a sentence already in the field, that gives "the settings window look More
/// similarly to the web app."
///
/// Decided by rules on the characters around the cursor, not by the model. On 22
/// cursor positions these rules placed 20 correctly. Apple's on-device model, shown
/// the text on both sides, placed 5; asked to rewrite the whole passage, it placed 10
/// and reordered the user's own text in 6 others; asked only whether the dictation
/// carried the sentence on, with rules doing the edit, it placed 16.
enum CursorFit {

    /// `text` as it should be pasted between `before` and `after`.
    ///
    /// Spaced before when it lands against a word, and after only when a word follows
    /// straight on. No space is left trailing at the end: the next dictation puts its
    /// own in front. A trailing space at the end of a web text field is not drawn, so
    /// a click at the end put the cursor in front of it, and the next words went in
    /// before the space instead of after it.
    ///
    /// - Parameters:
    ///   - names: Words the user has taught Indite, which keep their capitals.
    ///   - language: The language dictations are transcribed in. German gives every
    ///     noun a capital, so a German first word keeps the one it came with.
    static func fit(_ text: String, before: String, after: String, names: [String], language: Locale.Language?) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if language?.languageCode != .german,
           continuesSentence(before), let first = text.split(separator: " ").first,
           let initial = first.first, initial.isUppercase,
           !keepsCapital(String(first), in: text, before: before, names: names) {
            text = text.prefix(1).lowercased() + text.dropFirst()
        }

        // A sentence the text after the cursor goes on with does not end here.
        if carriesOn(after), text.hasSuffix("."), !text.hasSuffix("..") {
            text.removeLast()
        }

        if endsWord(before), let first = text.first, !",.;:!?)".contains(first),
           !writtenWithoutSpaces(first), let last = before.last, !writtenWithoutSpaces(last) {
            text = " " + text
        }

        if let next = after.first, next.isLetter || next.isNumber, !writtenWithoutSpaces(next),
           let last = text.last, !writtenWithoutSpaces(last) {
            text += " "
        }
        return text
    }

    /// Chinese, Japanese and Thai, which put no spaces between words.
    static func writtenWithoutSpaces(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x0E00...0x0E7F).contains(scalar)      // Thai
            || (0x3000...0x30FF).contains(scalar)      // CJK punctuation, kana
            || (0x3400...0x4DBF).contains(scalar)      // CJK extension A
            || (0x4E00...0x9FFF).contains(scalar)      // CJK ideographs
            || (0xFF00...0xFFEF).contains(scalar)      // full-width forms
    }

    /// Whether the text before the cursor stops in the middle of a sentence.
    ///
    /// Only a letter, digit, comma, semicolon or dash counts, looking past spaces and
    /// past closing quotes and brackets. A new line, a full stop, a colon or an emoji
    /// all leave the dictation's capital alone, and so does a dash that starts its
    /// line, which is a list item in Markdown.
    static func continuesSentence(_ before: String) -> Bool {
        let tail = before.reversed().drop { $0 == " " || $0 == "\t" }
        guard let end = tail.first, !end.isNewline else { return false }
        let rest = tail.drop(while: { "\"”’')]".contains($0) })
        guard let last = rest.first else { return false }
        if "–—-".contains(last) {
            guard let previous = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }).first else { return false }
            return previous.isLetter || previous.isNumber
        }
        return last.isLetter || last.isNumber || ",;".contains(last)
    }

    /// Whether the text before the cursor ends against a word, so the dictation needs a
    /// space to stand apart from it. Not after a space, an opening bracket or quote, a
    /// slash, a hyphen, @ or #: "(", "/path/", "re-", "#" all take the next word directly.
    static func endsWord(_ before: String) -> Bool {
        guard let last = before.last, !last.isWhitespace else { return false }
        if last == "\"" {
            // A straight quote closes when a word comes before it, and opens otherwise.
            guard let previous = before.dropLast().last else { return false }
            return !previous.isWhitespace
        }
        return !"([{“‘/\\-@#_".contains(last)
    }

    /// Whether the text after the cursor goes on with the sentence the dictation is in:
    /// it starts with a lowercase word, a number, or punctuation of its own.
    static func carriesOn(_ after: String) -> Bool {
        guard let next = after.drop(while: { $0 == " " || $0 == "\t" }).first else { return false }
        return next.isLowercase || next.isNumber || ",.;:!?)".contains(next)
    }

    /// Whether the first word keeps its capital in the middle of a sentence.
    ///
    /// The recognizer capitalizes the first word of every dictation, so its capital
    /// says nothing on its own. These say it is a name.
    private static func keepsCapital(_ word: String, in text: String, before: String, names: [String]) -> Bool {
        let bare = word.trimmingCharacters(in: .punctuationCharacters)
        if bare == "I" || bare.hasPrefix("I'") || bare.hasPrefix("I’") { return true }

        // "API", "McKinsey".
        if bare.dropFirst().contains(where: \.isUppercase) { return true }

        if names.contains(where: { $0 == bare || $0.hasPrefix(bare + " ") }) { return true }

        if calendarNames.contains(bare) { return true }

        // "Apple Notes", "New York": the recognizer capitalized the next word too, and
        // it gives a word inside a sentence a capital only when it hears a name.
        let words = text.split(separator: " ")
        if words.count > 1, let end = words[0].last, !".?!,:;".contains(end) {
            let next = words[1].trimmingCharacters(in: .punctuationCharacters)
            if let initial = next.first, initial.isUppercase, next.contains(where: \.isLowercase),
               next != "I", !next.hasPrefix("I'"), !next.hasPrefix("I’") {
                return true
            }
        }

        // The field already writes it with a capital where no sentence starts. Not for
        // a word like "The", which a title gives a capital anywhere.
        if !WordGuard.commonWords.contains(bare.lowercased()), capitalizedInsideSentence(bare, in: before) {
            return true
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }

    private static func capitalizedInsideSentence(_ word: String, in text: String) -> Bool {
        let whole = text as NSString
        var searchRange = NSRange(location: 0, length: whole.length)
        while true {
            let found = whole.range(of: word, options: [], range: searchRange)
            guard found.location != NSNotFound else { return false }
            searchRange = NSRange(location: NSMaxRange(found), length: whole.length - NSMaxRange(found))

            let end = NSMaxRange(found)
            if end < whole.length, let after = Unicode.Scalar(whole.character(at: end)),
               CharacterSet.alphanumerics.contains(after) { continue }

            let lead = whole.substring(to: found.location).reversed().drop { $0 == " " || $0 == "\t" }
            guard let previous = lead.first else { continue }
            if previous.isLetter || previous.isNumber || ",;".contains(previous) { return true }
        }
    }

    /// Days and months, which keep their capitals anywhere.
    private static let calendarNames: Set<String> = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        return Set((formatter.weekdaySymbols ?? []) + (formatter.monthSymbols ?? []))
    }()
}
