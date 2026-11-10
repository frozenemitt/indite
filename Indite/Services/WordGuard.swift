import Foundation

/// Keeps the speaker's words when a prompt is meant to correct them, not rewrite them.
///
/// Apple's on-device model drops or rewords words even when told not to. Measured on
/// real dictations with a prompt that forbids it, and under greedy sampling, so every
/// time: "update that yet" came back as "update that", "a reference point" as "a
/// reference", and one version lost the whole end of a dictation. No wording of the
/// prompt stopped it without causing a different loss somewhere else.
///
/// So the rule is enforced here instead. The rewrite is lined up against what was
/// said, word by word, and only what a correction may change gets through:
/// punctuation and capitals, an accidental repeat taken out, and a word swapped
/// one-for-one for another (a misheard word). A word the model dropped is put back; a
/// word it added, or a phrase it reworded, goes back to what was said.
///
/// Lining up 400 words, about two minutes of speech, takes under half a millisecond.
enum WordGuard {

    struct Outcome {
        let text: String
        /// Words put back that the model had dropped or reworded.
        let restored: Int
        /// Words the model added that were taken out.
        let removed: Int
    }

    /// Past this many words the check is skipped: lining up is quadratic, and a
    /// dictation this long is rare enough not to hold the paste up for it.
    static let maximumWords = 2000

    static func apply(said: String, rewrite: String) -> Outcome {
        let saidWords = words(in: said)
        let rewriteWords = words(in: rewrite)
        guard !saidWords.isEmpty, !rewriteWords.isEmpty,
              saidWords.count <= maximumWords, rewriteWords.count <= maximumWords else {
            return Outcome(text: rewrite, restored: 0, removed: 0)
        }

        var output: [Word] = []
        var restored = 0
        var removed = 0

        for step in alignment(saidWords.map(\.key), rewriteWords.map(\.key)) {
            switch step {
            case .same(let j):
                output.append(rewriteWords[j])

            case .changed(let said, let rewritten):
                if !said.isEmpty, said.count == rewritten.count {
                    // One-for-one swaps go back to what was said, unless the model only
                    // wrote the same number another way.
                    for (s, r) in zip(said, rewritten) {
                        if couldBeMisheard(saidWords[s].key, as: rewriteWords[r].key) {
                            output.append(rewriteWords[r])
                        } else {
                            output.append(transplanting(saidWords[s], into: rewriteWords[r]))
                            restored += 1
                            removed += 1
                        }
                    }
                } else if rewritten.isEmpty {
                    // Dropped words come back, except an accidental repeat. Only a
                    // later copy counts as the repeat, because the copy before it was
                    // either kept by the model or is coming back here: "really really
                    // good" returned as "good" gets one "really" back, not none.
                    let back = said.filter { $0 == 0 || saidWords[$0 - 1].key != saidWords[$0].key }
                    output += restoring(back.map { saidWords[$0] }, after: output)
                    restored += back.count
                } else if said.isEmpty {
                    // Words the model added are left out.
                    removed += rewritten.count
                } else {
                    // A phrase reworded into a different number of words goes back to
                    // what was said: "there's" stays "there's", not "there are".
                    output += restoring(said.map { saidWords[$0] }, after: output)
                    restored += said.count
                    removed += rewritten.count
                }
            }
        }

        return Outcome(text: joined(output), restored: restored, removed: removed)
    }

    /// The share of the words said that appear in the rewrite, each counted as often
    /// as it was said.
    ///
    /// Order is ignored and nothing is lined up, so it costs one pass over each text
    /// and has no word limit.
    static func share(of said: String, keptIn rewrite: String) -> Double {
        var available: [String: Int] = [:]
        for word in words(in: rewrite) { available[word.key, default: 0] += 1 }
        let saidKeys = words(in: said).map(\.key)
        guard !saidKeys.isEmpty else { return 1 }
        var kept = 0
        for key in saidKeys where available[key, default: 0] > 0 {
            available[key, default: 0] -= 1
            kept += 1
        }
        return Double(kept) / Double(saidKeys.count)
    }

    // MARK: - Mishearings

    /// Whether the model may put `rewritten` in place of `said`: only the same number
    /// written another way, as "1st" and "first".
    ///
    /// Swaps for misheard words used to pass when the two sounded alike or one was the
    /// other with a prefix or ending added. On 96 dictations from November 2026 the model
    /// made 11 swaps in one week and 1 was right; the version with the sound-alike rule
    /// made 5 and 1 was right. Refusing every swap took wrong words from 47 to 43 and
    /// left every other score as it was, so on 2026-11-10 Jonathan chose punctuation and
    /// capitals only. Another word is a guess the model has no way to check: it once
    /// turned "an inelegant solution" into "an elegant solution".
    static func couldBeMisheard(_ said: String, as rewritten: String) -> Bool {
        guard let a = numberValue(said), let b = numberValue(rewritten) else { return false }
        return a == b
    }

    /// The said word, in the place and punctuation the model gave the word it swapped
    /// in. The model may change punctuation; only the word itself goes back.
    private static func transplanting(_ said: Word, into rewritten: Word) -> Word {
        let core = { (text: String) -> Range<String.Index>? in
            guard let start = text.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let end = text.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return start..<text.index(after: end)
        }
        guard let saidCore = core(said.text), let rewrittenCore = core(rewritten.text) else {
            return Word(text: said.text, spaceAfter: rewritten.spaceAfter, key: said.key, isRestored: true)
        }
        var word = String(said.text[saidCore])
        // A capital the model gave the place, because a sentence starts there.
        if let first = rewritten.text[rewrittenCore].first, first.isUppercase,
           let own = word.first, own.isLowercase {
            word = word.prefix(1).uppercased() + word.dropFirst()
        }
        let text = String(rewritten.text[..<rewrittenCore.lowerBound]) + word
            + String(rewritten.text[rewrittenCore.upperBound...])
        return Word(text: text, spaceAfter: rewritten.spaceAfter, key: said.key, isRestored: true)
    }

    /// The number a word names: its digits, or the number written out ("four",
    /// "first"). Nil when it names none.
    private static func numberValue(_ key: String) -> Int? {
        if key.contains(where: \.isNumber) {
            // "1st", "2,500", "10:30": the digits, in order. Too long for an Int is
            // not a number this check can compare.
            let digits = key.filter(\.isNumber)
            let ending = key.filter(\.isLetter)
            guard ["", "st", "nd", "rd", "th", "s"].contains(ending) else { return nil }
            return Int(digits)
        }
        return numberWords[key]
    }

    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100, "thousand": 1000, "million": 1_000_000,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "twentieth": 20, "thirtieth": 30
    ]

    // MARK: - Words

    /// A word as written, the space that followed it, and the form compared.
    struct Word {
        var text: String
        var spaceAfter: String
        let key: String
        /// Put back from what was said. Seams are mended only next to these, never
        /// inside the model's own text.
        var isRestored = false
    }

    static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            let end = index
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            let token = String(text[start..<end])
            let key = token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
                .replacingOccurrences(of: "’", with: "'")
            if key.isEmpty {
                // Punctuation standing alone, such as a dash: kept with the word before.
                if !result.isEmpty {
                    result[result.count - 1].spaceAfter += token + String(text[end..<index])
                }
                continue
            }
            result.append(Word(text: token, spaceAfter: String(text[end..<index]), key: key))
        }
        return result
    }

    /// Said words put back into the rewrite, fitted to where they land.
    ///
    /// A pause ellipsis on a said word is dropped. At the very start, the first word
    /// takes a capital.
    private static func restoring(_ said: [Word], after output: [Word]) -> [Word] {
        var back = said.map { word -> Word in
            var word = word
            word.text = word.text.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            word.spaceAfter = " "
            word.isRestored = true
            return word
        }
        guard !back.isEmpty else { return back }

        if output.isEmpty {
            back[0].text = capitalizingFirst(back[0].text)
        }
        return back
    }

    /// The words joined, with the seams around restored words mended.
    private static func joined(_ words: [Word]) -> String {
        var words = words
        for i in words.indices.dropFirst() {
            let previous = words[i - 1].text
            let current = words[i].text
            // A full stop the model put before a restored word that carries the
            // sentence on.
            if words[i].isRestored, !words[i - 1].isRestored,
               let last = previous.last, ".?!".contains(last),
               let first = current.first, first.isLowercase {
                words[i - 1].text.removeLast()
            }
            // A capital on a common word that no longer starts a sentence, now that
            // the words before it are back. Either the model gave it one, having made
            // the word start a sentence, or it is a restored word with the capital the
            // recognizer gave it for coming after a pause.
            if words[i - 1].isRestored || words[i].isRestored,
               let last = previous.last, !".?!:".contains(last),
               commonWords.contains(current.lowercased().trimmingCharacters(in: .punctuationCharacters)),
               let first = current.first, first.isUppercase {
                words[i].text = current.prefix(1).lowercased() + current.dropFirst()
            }
        }
        var text = ""
        for (i, word) in words.enumerated() {
            text += word.text
            if i < words.count - 1 { text += word.spaceAfter.isEmpty ? " " : word.spaceAfter }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizingFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Words that take a capital only at the start of a sentence.
    static let commonWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "of", "to", "in", "on", "at", "for",
        "with", "it", "its", "it's", "this", "that", "these", "those", "we", "you",
        "they", "he", "she", "is", "are", "was", "were", "be", "let's", "let", "there",
        "their", "then", "just", "not", "no", "if", "as", "by", "from", "my", "our",
        "your", "what", "which", "who", "when", "where", "how", "why", "can", "could",
        "would", "should", "will", "do", "does", "did", "have", "has", "had", "all",
        "some", "any"
    ]

    // MARK: - Alignment

    enum Step {
        /// The word at this index of the rewrite matches what was said.
        case same(Int)
        /// Said words and rewrite words between two matches.
        case changed(said: [Int], rewritten: [Int])
    }

    /// The longest common run of words, as matches and the gaps between them.
    static func alignment(_ a: [String], _ b: [String]) -> [Step] {
        let n = a.count, m = b.count
        var lengths = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * (m + 1) + j] = a[i] == b[j]
                    ? lengths[(i + 1) * (m + 1) + j + 1] + 1
                    : max(lengths[(i + 1) * (m + 1) + j], lengths[i * (m + 1) + j + 1])
            }
        }

        var steps: [Step] = []
        var said: [Int] = [], rewritten: [Int] = []
        func closeGap() {
            if !said.isEmpty || !rewritten.isEmpty {
                steps.append(.changed(said: said, rewritten: rewritten))
                said = []; rewritten = []
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                closeGap()
                steps.append(.same(j))
                i += 1; j += 1
            } else if lengths[(i + 1) * (m + 1) + j] >= lengths[i * (m + 1) + j + 1] {
                said.append(i); i += 1
            } else {
                rewritten.append(j); j += 1
            }
        }
        said += Array(i..<n)
        rewritten += Array(j..<m)
        closeGap()
        return steps
    }
}

// MARK: - Sentence Breaks

extension WordGuard {

    /// Words that can carry a sentence on after a comma.
    static let continuingWords: Set<String> = [
        "and", "but", "so", "or", "nor", "yet", "because", "whereas", "which",
        "although", "though", "unless", "while",
    ]

    /// Put back a full stop that the model turned into a comma between two sentences.
    ///
    /// The recognizer ends a sentence at every pause and capitalizes the next word, so
    /// some of its full stops cut one sentence in two, and a prompt that keeps the
    /// speaker's words is told to join those pieces. Apple's model joins too eagerly.
    /// On Jonathan's last 100 dictations, which two labelers agreed held 40 such cuts
    /// among 207 breaks, told to join them it mended 33 of 80 over two runs but also
    /// ran 28 of 330 real sentence ends together, 21 of them with a bare comma: "I
    /// tweaked it myself, can you please take a look?"
    ///
    /// A comma join stays only before a word that carries the sentence on, such as
    /// "and", "but" or "because". A join with no punctuation stays, since that is how a
    /// fragment rejoins its sentence: "articulate the width of that uncertainty". With
    /// this check the same runs mended 24 of 80 and joined 7 real ends, each with a
    /// comma before "and", "but", "so" or "or".
    ///
    /// - Returns: The rewrite with those full stops back, and how many were put back.
    static func keepingSentenceBreaks(said: String, rewrite: String) -> (text: String, putBack: Int) {
        let saidWords = words(in: said)
        var output = words(in: rewrite)
        guard saidWords.count > 1, output.count > 1,
              saidWords.count <= maximumWords, output.count <= maximumWords else { return (rewrite, 0) }

        // Where each said word landed in the rewrite, for the words it kept.
        var landed: [Int: Int] = [:]
        var next = 0
        for step in alignment(saidWords.map(\.key), output.map(\.key)) {
            switch step {
            case .same(let j):
                landed[next] = j
                next += 1
            case .changed(let said, _):
                if let last = said.last { next = last + 1 }
            }
        }

        var putBack = 0
        for i in 0..<(saidWords.count - 1) {
            guard let mark = saidWords[i].text.last, ".?!".contains(mark),
                  let first = saidWords[i + 1].text.first, first.isUppercase,
                  let j = landed[i], landed[i + 1] == j + 1,
                  output[j].text.hasSuffix(","),
                  !continuingWords.contains(saidWords[i + 1].key) else { continue }
            output[j].text.removeLast()
            output[j].text.append(mark)
            if let start = output[j + 1].text.first, start.isLowercase {
                output[j + 1].text = start.uppercased() + output[j + 1].text.dropFirst()
            }
            putBack += 1
        }
        return putBack == 0 ? (rewrite, 0) : (joined(output), putBack)
    }
}
