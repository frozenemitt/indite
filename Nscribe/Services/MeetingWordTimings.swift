import Foundation
import os

/// When each word of a meeting was spoken, kept in a file beside its recording.
///
/// The recognizer times every word it hears. Those timings used to be dropped when
/// words were joined into a speaker's line, which kept only where the line began and
/// ended, so a click on a word could only guess when it was said.
///
/// A file of its own, not part of the store. The timings are useless without the
/// recording, so they are written with it and deleted with it, and the store's schema
/// does not change for them.
struct MeetingWordTimings: Codable, Sendable {

    /// One timed run from the recognizer: usually a word, sometimes a few.
    struct Word: Codable, Sendable, Equatable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        /// 0 for the microphone, 1 for the other side of a call. The two are timed
        /// separately and overlap, so a line may only look at its own.
        var track: Int
    }

    var words: [Word]

    private static let log = Logger(subsystem: "com.nscribe.app", category: "MeetingAudio")

    /// The timings file for a recording: its name with an extension added, so the two
    /// sit side by side and one name finds both.
    static func fileName(forRecording name: String) -> String {
        name + ".words.json"
    }

    /// Keep the timings for a recording.
    ///
    /// - Parameter tracks: The timed runs of each track, already on the meeting clock,
    ///   which is the recording's own.
    static func save(tracks: [[TimedTranscriptSegment]], forRecording name: String) {
        let words = tracks.enumerated().flatMap { index, segments in
            segments.map { Word(text: $0.text, start: $0.start, end: $0.end, track: index) }
        }
        guard !words.isEmpty else { return }

        do {
            let data = try JSONEncoder().encode(MeetingWordTimings(words: words))
            try data.write(to: MeetingAudioStore.url(forFileNamed: fileName(forRecording: name)), options: .atomic)
        } catch {
            // The meeting is whole without them: clicks fall back to an estimate.
            log.error("Could not save the word timings: \(error, privacy: .public)")
        }
    }

    /// The timings for a recording, or nil for one made before they were kept.
    static func load(forRecording name: String?) -> MeetingWordTimings? {
        guard let name else { return nil }
        let url = MeetingAudioStore.url(forFileNamed: fileName(forRecording: name))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MeetingWordTimings.self, from: data)
    }

    /// When each word of a line was spoken, in the order the words appear in `text`.
    ///
    /// The line knows when it began and ended, and the timed words between those two
    /// moments are its own. On a call there are two tracks in that stretch, and the
    /// line is matched against each; the one that shares more words with it is the
    /// track it came from. Asking the speaker instead would be wrong after a
    /// correction that hands a line to someone on the other track.
    ///
    /// Nil when no timed word falls inside the line.
    func times(forWordsOf text: String, spokenFrom start: TimeInterval, to end: TimeInterval) -> [TimeInterval]? {
        var best: (times: [TimeInterval], matched: Int)?
        for track in Set(words.map(\.track)).sorted() {
            let timed = words.filter { word in
                let middle = word.start + (word.end - word.start) / 2
                return word.track == track && middle >= start && middle <= end
            }
            guard !timed.isEmpty else { continue }
            let candidate = WordAlignment.times(forWordsOf: text, spokenFrom: start, to: end, timed: timed)
            if candidate.matched > (best?.matched ?? -1) { best = candidate }
        }
        return best?.times
    }
}

/// Matches the words on screen to the words the recognizer timed.
///
/// They are not the same words. Vocabulary spelling and word replacements run after
/// timing, so "type script" on the clock is "TypeScript" on the page, and a
/// correction typed by the user changes a word the recognizer never heard. The two
/// run in the same order and mostly agree, so they are walked together, and a word
/// with no partner takes a time between its neighbours'.
enum WordAlignment {

    /// The words of a text, as ranges of UTF-16 units, which is how a text view
    /// counts. A word is a run of anything that is not whitespace.
    static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var wordStart: Int?
        var offset = 0
        for unit in text.unicodeScalars {
            let length = unit.utf16.count
            if unit.properties.isWhitespace {
                if let start = wordStart {
                    ranges.append(NSRange(location: start, length: offset - start))
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = offset
            }
            offset += length
        }
        if let start = wordStart {
            ranges.append(NSRange(location: start, length: offset - start))
        }
        return ranges
    }

    /// A word as it is compared: letters and digits only, in lower case. "Thursday."
    /// and "thursday" are the same word said once.
    static func key(_ word: String) -> String {
        String(String.UnicodeScalarView(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    /// How far ahead either side may look for the next word both have.
    private static let reach = 6

    /// The start time of each word of `text`, and how many of them found a partner
    /// among the timed words.
    static func times(
        forWordsOf text: String,
        spokenFrom start: TimeInterval,
        to end: TimeInterval,
        timed: [MeetingWordTimings.Word]
    ) -> (times: [TimeInterval], matched: Int) {
        let ns = text as NSString
        let shown = wordRanges(in: text).map { key(ns.substring(with: $0)) }
        guard !shown.isEmpty else { return ([], 0) }

        // A timed run can hold more than one word. Its words share its stretch evenly.
        var heard: [(key: String, time: TimeInterval)] = []
        for run in timed.sorted(by: { $0.start < $1.start }) {
            let parts = run.text.split(whereSeparator: \.isWhitespace)
            for (index, part) in parts.enumerated() {
                let time = run.start + (run.end - run.start) * Double(index) / Double(max(parts.count, 1))
                heard.append((key(String(part)), time))
            }
        }

        // Walk both in step. Where they disagree, find the nearest word ahead that
        // both have and carry on from there.
        var times = [TimeInterval?](repeating: nil, count: shown.count)
        var matched = 0
        var i = 0
        var j = 0
        while i < shown.count, j < heard.count {
            if !shown[i].isEmpty, shown[i] == heard[j].key {
                times[i] = heard[j].time
                matched += 1
                i += 1
                j += 1
                continue
            }

            var next: (Int, Int)?
            search: for distance in 1...(2 * reach) {
                for ahead in max(0, distance - reach)...min(distance, reach) {
                    let a = i + ahead
                    let b = j + distance - ahead
                    guard a < shown.count, b < heard.count else { continue }
                    if !shown[a].isEmpty, shown[a] == heard[b].key {
                        next = (a, b)
                        break search
                    }
                }
            }

            if let next {
                // The first word passed over on each side is the same moment said two
                // ways: "TypeScript" on the page where "type script" was heard.
                if next.0 > i, next.1 > j {
                    times[i] = heard[j].time
                }
                i = next.0
                j = next.1
            } else {
                // Nothing in reach agrees. Take this word's time from the one heard in
                // its place, which is close, and move both on.
                times[i] = heard[j].time
                i += 1
                j += 1
            }
        }

        // A word with no partner falls evenly between the nearest two that have one,
        // with the line's own start and end standing in at either edge.
        var result = [TimeInterval](repeating: start, count: shown.count)
        var index = 0
        var previous = start
        while index < shown.count {
            if let time = times[index] {
                previous = max(previous, time)
                result[index] = previous
                index += 1
                continue
            }
            var gapEnd = index
            while gapEnd < shown.count, times[gapEnd] == nil { gapEnd += 1 }
            let following = gapEnd < shown.count ? max(previous, times[gapEnd]!) : max(previous, end)
            let count = Double(gapEnd - index + 1)
            for position in index..<gapEnd {
                result[position] = previous + (following - previous) * Double(position - index + 1) / count
            }
            index = gapEnd
        }
        return (result, matched)
    }
}
