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
    ///
    /// `terms` may include names read from the screen; `keeping` are the user's own list.
    /// A second guess never drops one of those: the screen held "Dristy Quest", an
    /// earlier mishearing, and taking it undid a correct "Drishti Quest".
    static func choose(_ top: String, alternatives: [String], terms: [String], keeping: [String] = []) -> String {
        guard !terms.isEmpty else { return top }
        let heard = listed(in: top, terms: terms)
        let kept = listed(in: top, terms: keeping)
        for alternative in alternatives where alternative != top {
            let found = listed(in: alternative, terms: terms)
            guard !found.subtracting(heard).isEmpty, kept.isSubset(of: found) else { continue }
            // Results after the first open with a space; keep it, or the words run together.
            let leading = top.prefix { $0.isWhitespace }
            return String(leading) + alternative.drop { $0.isWhitespace }
        }
        return top
    }

    // MARK: - Spotted words

    /// A finished result: what the transcript holds for it, and the runs the recognizer
    /// timed, which the spotter's findings are matched against.
    struct Segment: Sendable {
        let text: String
        /// Replaced by a second guess, so its runs no longer match its text.
        let tookSecondGuess: Bool
        let runs: [Run]
    }

    struct Run: Sendable {
        let text: String
        let start: Double?
        let end: Double?
        let confidence: Double?
    }

    /// Settled on 153 recordings of known sentences, then confirmed unchanged on 32 in
    /// the user's own voice. Without the confidence rule it put in dozens of wrong
    /// words, "it" as "Git" among them.
    private static let minimumSpotScore: Float = -12
    private static let minimumSimilarity = 0.7
    private static let maximumConfidence = 0.9
    private static let timePadding = 0.15

    /// The transcript with the words the spotter heard put in where they belong.
    ///
    /// A listed word replaces up to three words the recognizer wrote at the same moment
    /// only when all of these hold: the spotter is confident enough; what was written
    /// already looks like the word ("Dristy Quest" for Drishti Quest); the recognizer
    /// itself was unsure of it; and what was written is not already a word from the
    /// user's list ("NorAI" is never turned into a screen name "Nora").
    static func applySpotted(_ detections: [VocabularySpotter.Detection], to segments: [Segment],
                             listed: [String]) -> (text: String, replaced: Int) {
        struct Slot { let segment: Int; let run: Int }
        var texts = segments.map { $0.runs.map(\.text) }
        var timed: [Slot] = []
        for (s, segment) in segments.enumerated() where !segment.tookSecondGuess {
            for (r, run) in segment.runs.enumerated() where run.start != nil && run.end != nil {
                timed.append(Slot(segment: s, run: r))
            }
        }
        func run(_ slot: Slot) -> Run { segments[slot.segment].runs[slot.run] }

        var taken = Set<Int>()
        var replaced = 0
        for detection in detections.sorted(by: { $0.score > $1.score }) where detection.score >= minimumSpotScore {
            let overlapping = timed.indices.filter {
                run(timed[$0]).end! > detection.start - timePadding && run(timed[$0]).start! < detection.end + timePadding
            }
            guard let low = overlapping.first, let high = overlapping.last else { continue }
            var best: (similarity: Double, first: Int, last: Int, heard: String)?
            for first in low...high {
                for last in first...min(first + 2, high) {
                    // A name can span two results, as "Dristy" and "Quest" did, but not a
                    // result the second guess replaced, whose runs are not in `timed`.
                    guard (first..<last).allSatisfy({ timed[$0 + 1].segment - timed[$0].segment <= 1 }) else { continue }
                    let heard = (first...last).map { run(timed[$0]).text }.joined()
                    let score = similarity(withoutPossessive(heard), detection.term)
                    if best == nil || score > best!.similarity { best = (score, first, last, heard) }
                }
            }
            guard let best, best.similarity >= minimumSimilarity else { continue }
            let span = best.first...best.last
            let core = withoutPossessive(best.heard)
            guard key(core) != key(detection.term),
                  !listed.contains(where: { key($0) == key(core) }),
                  taken.isDisjoint(with: span),
                  span.allSatisfy({ (run(timed[$0]).confidence ?? 1) <= maximumConfidence }) else { continue }

            let firstText = run(timed[best.first]).text
            let lastText = run(timed[best.last]).text
            let lead = firstText.prefix { $0.isWhitespace }
            let trail = possessive(of: best.heard) + String(lastText.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            texts[timed[best.first].segment][timed[best.first].run] = lead + detection.term + trail
            for index in span.dropFirst() { texts[timed[index].segment][timed[index].run] = "" }
            taken.formUnion(span)
            replaced += 1
        }
        let rebuilt = segments.indices.map { segments[$0].tookSecondGuess ? segments[$0].text : texts[$0].joined() }
        return (rebuilt.joined(), replaced)
    }

    /// Letters in common, from 0 to 1: one less the edits between them over the longer.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(key(a)), b = Array(key(b))
        guard !a.isEmpty, !b.isEmpty else { return a.count == b.count ? 1 : 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// "Lilia's" is Lilia with an "'s", which stays when the name goes in.
    private static func possessive(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: CharacterSet.letters.inverted)
        for suffix in ["'s", "’s"] where trimmed.hasSuffix(suffix) { return suffix }
        return ""
    }

    private static func withoutPossessive(_ text: String) -> String {
        let suffix = possessive(of: text)
        guard !suffix.isEmpty, let range = text.range(of: suffix, options: .backwards) else { return text }
        return text.replacingCharacters(in: range, with: "")
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

    /// Every run of one to three words in `text`, in the form `key` gives: what
    /// Inscribe typed, to tell names on screen apart from its own earlier guesses.
    static func phrases(in text: String) -> Set<String> {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: Set<String> = []
        for length in 1...3 where length <= words.count {
            for start in 0...(words.count - length) {
                found.insert(key(words[start..<(start + length)].joined(separator: " ")))
            }
        }
        return found
    }

    /// Letters and digits only, lower-cased: the form two spellings of a word share.
    static func key(_ text: String) -> String {
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
