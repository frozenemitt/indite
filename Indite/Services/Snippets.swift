import Foundation

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
    /// A cue matches whole words, in any capitals, with any punctuation around it. The
    /// punctuation stays where it is, except a full stop after a cue that ends the
    /// text. That full stop ended the spoken sentence: a dictation of "My address."
    /// types the address and nothing after it. A question mark stays.
    static func expand(_ text: String, snippets: [String: String]) -> (text: String, expanded: Int) {
        guard let cues = Cues(snippets) else { return (text, 0) }
        // The dictation's own spaces at either end go, as a paste fitted to the cursor
        // takes them off. The saved text keeps its own.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = trimmed as NSString
        let matches = cues.pattern.matches(in: trimmed, range: NSRange(location: 0, length: whole.length))
        guard !matches.isEmpty else { return (text, 0) }

        var result = ""
        var position = 0
        for match in matches {
            result += whole.substring(with: NSRange(location: position, length: match.range.location - position))
            let cue = whole.substring(with: match.range(at: 1))
            result += cues.savedText[key(cue)] ?? whole.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        return (result + whole.substring(from: position), matches.count)
    }

    /// Whether `answer` still holds each cue that `said` held, at least as many times.
    ///
    /// For the AI pass. A cue the model reworded cannot be found in its answer, so the
    /// saved text it stands for would be lost.
    static func keepsCues(of said: String, in answer: String, snippets: [String: String]) -> Bool {
        guard let cues = Cues(snippets) else { return true }
        let kept = cues.counts(in: answer)
        return cues.counts(in: said).allSatisfy { kept[$0.key, default: 0] >= $0.value }
    }

    /// One form for the ways a cue can be written: lower case, single spaces and a
    /// straight apostrophe.
    private static func key(_ cue: String) -> String {
        cue.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Every cue in one pattern, and the saved text for each.
    private struct Cues {
        let pattern: NSRegularExpression
        let savedText: [String: String]

        /// Nil when there is no cue to look for.
        init?(_ snippets: [String: String]) {
            // Longest first, so a cue that holds another wins where both match. Equal
            // lengths go alphabetically: a dictionary's own order changes from one
            // launch to the next.
            let ordered = snippets
                .map { (cue: Snippets.key($0.key), text: $0.value) }
                .filter { !$0.cue.isEmpty }
                .sorted { $0.cue.count != $1.cue.count ? $0.cue.count > $1.cue.count : $0.cue < $1.cue }

            // The cue's words may stand apart by any run of spaces. An apostrophe may be
            // straight or curly. The edges are those of word replacements: no letter or
            // digit next to the cue.
            var savedText: [String: String] = [:]
            var alternatives: [String] = []
            for snippet in ordered where savedText[snippet.cue] == nil {
                savedText[snippet.cue] = snippet.text
                alternatives.append(snippet.cue.split(separator: " ").map { word in
                    word.split(separator: "'", omittingEmptySubsequences: false)
                        .map { NSRegularExpression.escapedPattern(for: String($0)) }
                        .joined(separator: "['\u{2019}]")
                }.joined(separator: "\\s+"))
            }
            guard !alternatives.isEmpty, let pattern = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}_])(\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}_])([.…]+$)?",
                options: [.caseInsensitive]
            ) else { return nil }
            self.pattern = pattern
            self.savedText = savedText
        }

        /// How many times each cue appears in `text`, by its key.
        func counts(in text: String) -> [String: Int] {
            let whole = text as NSString
            var counts: [String: Int] = [:]
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
                counts[Snippets.key(whole.substring(with: match.range(at: 1))), default: 0] += 1
            }
            return counts
        }
    }
}
