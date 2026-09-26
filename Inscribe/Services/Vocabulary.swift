import Foundation

/// Makes the vocabulary list count with a recognizer that ignores it.
///
/// Apple's SpeechTranscriber takes no notice of vocabulary hints: two meetings came out
/// identical to the character with and without them. Two things do work, measured on
/// 153 recordings of sentences with known text:
///
/// - When the recognizer is unsure, it also reports its second guesses. Taking one
///   that holds a listed word the first guess lacks turned "Rebase on Maine" into
///   "Rebase on main". It never picks a word the recognizer did not consider.
/// - A listed word whose letters were heard right but spaced or capitalised wrong is
///   spelled as listed: "type script" becomes "TypeScript".
///
/// Together they raised listed words heard right from 30 to 38 of 93, and changed
/// none of the 33 sentences that used a sound-alike correctly ("our cloud bill",
/// "Nora", "Maine"). Matching by sound was tried too and rejected: it turned "cloud"
/// and "could" into "Claude".
enum Vocabulary {

    /// The recognizer's own second guess, when it holds a listed word the first guess
    /// lacks. Otherwise the first guess.
    static func choose(_ top: String, alternatives: [String], terms: [String]) -> String {
        guard !terms.isEmpty else { return top }
        let heard = listed(in: top, terms: terms)
        for alternative in alternatives where alternative != top {
            guard !listed(in: alternative, terms: terms).subtracting(heard).isEmpty else { continue }
            // Results after the first open with a space; keep it, or the words run together.
            let leading = top.prefix { $0.isWhitespace }
            return String(leading) + alternative.drop { $0.isWhitespace }
        }
        return top
    }

    /// Listed words spelled as listed: "type script" → "TypeScript", "em dash" →
    /// "em-dash". Only where the letters already are the listed word, so no word is
    /// ever swapped for another.
    static func spell(_ text: String, terms: [String]) -> String {
        guard !terms.isEmpty else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < tokens.count {
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let window = tokens[index..<(index + length)]
                // A phrase broken by a full stop or comma is not one term.
                if window.dropLast().contains(where: { $0.last.map { ".,?!;:".contains($0) } ?? false }) { continue }
                let joined = window.joined(separator: " ")
                guard let term = terms.first(where: { !key($0).isEmpty && key($0) == key(joined) }) else { continue }
                let startsSentence = tokens[..<index].last(where: { !$0.isEmpty }).map { $0.last.map { ".?!".contains($0) } ?? false } ?? true
                tokens.replaceSubrange(index..<(index + length), with: [spelling(of: term, as: joined, startsSentence: startsSentence)])
                break
            }
            index += 1
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Matching

    /// Letters and digits only, lower-cased: the form two spellings of a word share.
    private static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The listed terms that appear in `text`, as runs of one to three words.
    private static func listed(in text: String, terms: [String]) -> Set<String> {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: Set<String> = []
        for length in 1...3 where length <= words.count {
            for start in 0...(words.count - length) {
                let window = key(words[start..<(start + length)].joined(separator: " "))
                for term in terms where key(term) == window && !window.isEmpty {
                    found.insert(term)
                }
            }
        }
        return found
    }

    /// `term` in place of the words heard as it, keeping the punctuation around them.
    ///
    /// A coined term takes the list's spelling. A plain lower-case one keeps a capital
    /// only where a sentence starts: "Main" opening a sentence stays, "into Main" does not.
    private static func spelling(of term: String, as heard: String, startsSentence: Bool) -> String {
        let lead = heard.prefix { !$0.isLetter && !$0.isNumber }
        let trail = String(heard.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
        let core = heard.dropFirst(lead.count).dropLast(trail.count)
        let coined = term.contains(" ") || term.contains("-") || term.dropFirst().contains(where: \.isUppercase)
        if coined || core.contains(" ") { return lead + term + trail }
        if startsSentence, core.first?.isUppercase == true { return heard }
        return lead + term + trail
    }
}
