import Foundation

/// Saved text and the spoken cue that stands for it, as one row of the Words settings.
struct Snippet: Equatable {
    var cue: String
    var text: String

    /// Whether it is typed: it has a cue to listen for and text to type. A row still
    /// being filled in is kept, and passed over.
    var isComplete: Bool { !Snippets.key(cue).isEmpty && !text.isEmpty }
}

/// Saved text that a spoken cue stands for: say "my calendar link", and the link is
/// typed.
///
/// Kept apart from word replacements. A replacement runs before the AI pass, so the
/// model reads the corrected word. A snippet is expanded after the AI pass, so the
/// model never sees the saved text and cannot edit it. The text reaches the field as
/// it was written, line breaks included.
enum Snippets {

    /// `text` with each cue in it replaced by its saved text, and the number of cues
    /// replaced.
    ///
    /// A cue matches whole words, in any capitals, with any punctuation around it and
    /// the recognizer's marks for a pause between its words. The punctuation stays
    /// where it is, with two exceptions for the mark the recognizer put right after a
    /// cue. A full stop there that ends the text goes: it ended the spoken sentence, and
    /// a dictation of "My address." types the address and nothing after it. And any
    /// mark there goes when the saved text ends in punctuation, a space or a line break
    /// of its own, so that "My closing line. Talk soon." types one full stop, not two.
    /// What follows keeps the capital the recognizer gave it.
    static func expand(_ text: String, snippets: [Snippet]) -> (text: String, expanded: Int) {
        guard let cues = Cues(snippets) else { return (text, 0) }
        return expand(text, cues: cues, limits: nil)
    }

    /// `answer` with the cues that `said` held replaced by their saved text, each no
    /// more times than `said` held it, or nil when `answer` holds one of them fewer
    /// times.
    ///
    /// For the AI pass, so that whether a snippet is typed depends on what was said and
    /// not on the rewrite: a cue that first appears in the model's answer stays as
    /// words. A cue the model reworded cannot be found in its answer, so the saved text
    /// it stands for would be lost.
    static func expand(_ answer: String, cuesOf said: String, snippets: [Snippet]) -> (text: String, expanded: Int)? {
        guard let cues = Cues(snippets) else { return (answer, 0) }
        let held = cues.counts(in: said)
        let kept = cues.counts(in: answer)
        guard held.allSatisfy({ kept[$0.key, default: 0] >= $0.value }) else { return nil }
        return expand(answer, cues: cues, limits: held)
    }

    /// `text` with its cues replaced, the first ones of each up to the number `limits`
    /// gives it, or all of them when there are no limits.
    private static func expand(_ text: String, cues: Cues, limits: [Int: Int]?) -> (text: String, expanded: Int) {
        // The dictation's own spaces at either end go, as a paste fitted to the cursor
        // takes them off. The saved text keeps its own.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = trimmed as NSString
        var remaining = limits
        var result = ""
        var position = 0
        var expanded = 0
        for match in cues.pattern.matches(in: trimmed, range: NSRange(location: 0, length: whole.length)) {
            let cue = cues.cue(of: match)
            if let left = remaining?[cue, default: 0] {
                guard left > 0 else { continue }
                remaining?[cue] = left - 1
            }
            let saved = cues.savedTexts[cue]
            result += whole.substring(with: NSRange(location: position, length: match.range.location - position))
            result += saved
            let markRange = match.range(at: cues.savedTexts.count + 1)
            if markRange.location != NSNotFound {
                let mark = whole.substring(with: markRange)
                let endsDictation = NSMaxRange(markRange) == whole.length && mark.allSatisfy { ".…".contains($0) }
                if !endsDictation, !endsInMark(saved) { result += mark }
            }
            position = NSMaxRange(match.range)
            expanded += 1
        }
        guard expanded > 0 else { return (text, 0) }
        return (result + whole.substring(from: position), expanded)
    }

    /// Whether `text` holds the saved text of one of `snippets`, so that it is typed as
    /// it stands. For a dictation typed again from the history, which keeps only the
    /// text that was delivered.
    static func holdsSavedText(_ text: String, snippets: [Snippet]) -> Bool {
        snippets.contains { $0.isComplete && text.contains($0.text) }
    }

    /// Whether saved text ends where a mark after it would be one too many: in a full
    /// stop, comma, semicolon, colon, question or exclamation mark, an ellipsis, a space
    /// or a line break. Not a closing bracket or quote, which a full stop can follow.
    private static func endsInMark(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.isWhitespace || ".,;:!?…".contains(last)
    }

    /// One form for the ways a cue can be written: lower case, single spaces and a
    /// straight apostrophe. Two cues with the same form are the same cue to a dictation.
    static func key(_ cue: String) -> String {
        cue.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Every cue in one pattern, and the saved text for each.
    private struct Cues {
        let pattern: NSRegularExpression
        /// The saved text of each cue, in the order of the pattern's groups: the cue
        /// that group 1 matches stands for the first.
        let savedTexts: [String]

        /// Nil when there is no cue to look for.
        init?(_ snippets: [Snippet]) {
            // Longest first, so a cue that holds another wins where both match. Equal
            // lengths go alphabetically. Of cues that differ only in capitals, spaces or
            // apostrophes, the first in the list wins, as the Words settings say: the
            // winner was left to a dictionary's order, which changes from one launch to
            // the next.
            let ordered = snippets.enumerated()
                .filter { $0.element.isComplete }
                .map { (place: $0.offset, cue: Snippets.key($0.element.cue), text: $0.element.text) }
                .sorted {
                    if $0.cue.count != $1.cue.count { return $0.cue.count > $1.cue.count }
                    return $0.cue != $1.cue ? $0.cue < $1.cue : $0.place < $1.place
                }

            // The cue's words may stand apart by any run of spaces, and by the mark the
            // recognizer writes where the speaker paused, with a capital after it: a full
            // stop, comma, ellipsis, question or exclamation mark, as in "my calendar.
            // Link" or "my calendar, link". An apostrophe may be straight or curly. The
            // edges are those of word replacements: no letter or digit next to the cue.
            //
            // Each cue is a group of its own, so that a match says which cue it found
            // whatever the recognizer wrote between the words.
            var seen: Set<String> = []
            var savedTexts: [String] = []
            var alternatives: [String] = []
            for snippet in ordered where !seen.contains(snippet.cue) {
                seen.insert(snippet.cue)
                savedTexts.append(snippet.text)
                alternatives.append("(" + snippet.cue.split(separator: " ").map { word in
                    word.split(separator: "'", omittingEmptySubsequences: false)
                        .map { NSRegularExpression.escapedPattern(for: String($0)) }
                        .joined(separator: "['\u{2019}]")
                }.joined(separator: "[.,?!…]*\\s+") + ")")
            }
            // The last group is the mark the recognizer put right after the cue, which
            // `expand` keeps or drops.
            guard !alternatives.isEmpty, let pattern = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}_])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}_])([.…]+|[,?!])?",
                options: [.caseInsensitive]
            ) else { return nil }
            self.pattern = pattern
            self.savedTexts = savedTexts
        }

        /// Which cue `match` found, as its place in `savedTexts`. Exactly one cue's group
        /// takes part in every match.
        func cue(of match: NSTextCheckingResult) -> Int {
            savedTexts.indices.first { match.range(at: $0 + 1).location != NSNotFound }!
        }

        /// How many times each cue appears in `text`, by its place in `savedTexts`.
        func counts(in text: String) -> [Int: Int] {
            var counts: [Int: Int] = [:]
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                counts[cue(of: match), default: 0] += 1
            }
            return counts
        }
    }
}
