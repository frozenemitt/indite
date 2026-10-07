import Foundation
import FoundationModels
import os
import Synchronization

/// Answers questions about Indite from the help articles, on Apple's on-device model.
///
/// Siri finds no help article by meaning (see `Docs/help-and-siri.md`), so answers come
/// from here: the model searches the articles through a tool and answers from what it
/// reads. Siri's "search Indite for …" hands its words to `ask`.
@MainActor
@Observable
final class HelpAssistant {
    enum State: Equatable {
        case idle
        case thinking
        case answered(String, sources: [HelpArticle.ID])
        case failed(String)
    }

    static let shared = HelpAssistant()

    var question = ""
    private(set) var state: State = .idle
    /// The setup as last read: when Help opened or came forward, and at each question.
    ///
    /// Shown by Help beside the answer, never given to the model. Given it as a tool,
    /// before the question, or after the articles, the model in turn skipped it,
    /// stopped searching, recited it, made up problems, and blamed Accessibility on a
    /// Mac where Accessibility was on. Help's own reading was right every time.
    private(set) var setup: HelpSetup?
    private var task: Task<Void, Never>?

    private static let instructions = """
        You answer questions about Indite, a Mac app for dictation and meeting \
        transcription. Always call searchHelp first, then answer only from the articles \
        it returns. Lead with the fix, not with why the problem happens. Answer in two \
        to four plain sentences and name the exact settings, \
        switches and buttons the articles name. Give the fix the articles give for the \
        exact problem asked about, and do not offer other settings as alternatives. Do \
        not mention links or buttons that open settings: Help shows that button itself. If \
        the articles do not cover the question, say so in one sentence and do not guess.
        """

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        self.question = question
        task?.cancel()
        refreshSetup()

        if let reason = FoundationModelsHelper.unavailabilityReason() {
            state = .failed(reason)
            return
        }

        state = .thinking
        let setup = self.setup
        task = Task {
            // A fresh session for every question: each one stands alone, and a long
            // conversation would only crowd the small model's context.
            let pick = await Self.route(question)
            // The fix article itself, not the model's account of it. Given the Globe
            // article first, the model still wrote from "The dictation key does nothing"
            // after it; given the Globe article alone, it answered "my key does nothing"
            // with "no specific fix". Help already knows the problem and its fix.
            if let fix = Self.fixArticle(for: question, picked: pick, setup: setup),
               let article = HelpArticle.article(id: fix) {
                guard !Task.isCancelled else { return }
                state = .answered(article.body, sources: [fix])
                Log.app.notice("Help assistant answered from the fix for a problem it found: \(fix, privacy: .public)")
                return
            }
            let tool = SearchHelpTool(question: question, pick: pick)
            let session = LanguageModelSession(tools: [tool], instructions: Self.instructions)
            do {
                let response = try await session.respond(to: question)
                guard !Task.isCancelled else { return }
                // The articles the model actually read, in the order the search ranked
                // them; the question's own words only if it never searched.
                // The articles the model read, the one the answer draws on most first:
                // a search can return two, and the answer may use only the second.
                var sources = tool.found.all
                if sources.isEmpty { sources = HelpArticle.search(question).map(\.id) }
                let answerWords = HelpArticle.words(in: response.content)
                sources.sort { a, b in
                    let overlap = { (id: HelpArticle.ID) in
                        HelpArticle.article(id: id).map { answerWords.intersection(HelpArticle.words(in: $0.title + " " + $0.body)).count } ?? 0
                    }
                    return overlap(a) > overlap(b)
                }
                sources = Array(sources.prefix(2))
                state = .answered(response.content, sources: sources)

                Log.app.notice("Help assistant answered in \(response.content.count, privacy: .public) characters")
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed("Indite couldn't answer that: \(error.localizedDescription)")
                Log.app.error("Help assistant failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension HelpAssistant {
    /// The article whose title best answers the question, chosen by the model from the
    /// list of titles, or nil when none fits.
    ///
    /// Matching words cannot see that "upload a voice memo" means "Transcribe a
    /// recording or video"; the model can. It misses where words do not, so the two run
    /// together: on fresh questions each was right about seven times in ten, on
    /// different questions.
    private static func route(_ question: String) async -> HelpArticle.ID? {
        let catalog = HelpArticle.all.map { "\($0.id): \($0.title)" }.joined(separator: "\n")
        let choices = HelpArticle.all.map(\.id) + ["none"]
        guard let schema = try? GenerationSchema(
            root: DynamicGenerationSchema(name: "Article", anyOf: choices), dependencies: []
        ) else { return nil }
        let session = LanguageModelSession(instructions: """
            You pick the one help article that best answers a question about Indite, a \
            Mac app for dictation and meeting transcription. These are the articles, one \
            per line as id: title:

            \(catalog)

            Reply with the id of the best article, or none if no article fits.
            """)
        guard let response = try? await session.respond(
            to: question, schema: schema, options: GenerationOptions(sampling: .greedy)
        ), let id = try? response.content.value(String.self), id != "none" else { return nil }
        return id
    }

    /// The article that fixes an urgent problem Help found, when the question is about
    /// something not working and the problem bears on it; nil otherwise.
    ///
    /// Asked "my dictation key does nothing" with the Globe key setting wrong, the
    /// model answered from the Accessibility article, under a warning about the Globe
    /// key. Only for troubleshooting: asked how to change the key while Accessibility
    /// was off, the person wants the steps, and the warning above says what is off.
    ///
    /// Troubleshooting if either the model's pick or the closest match by words is a
    /// troubleshooting article. Asked "my dictation key isn't working", the model
    /// picked "Change the dictation key" every time; the words found "The dictation
    /// key does nothing".
    static func fixArticle(for question: String, picked: HelpArticle.ID?, setup: HelpSetup?) -> HelpArticle.ID? {
        let byWords = HelpArticle.search(question).map(\.id)
        guard let setup,
              let base = [picked, byWords.first].compactMap({ $0 })
                .first(where: { HelpArticle.article(id: $0)?.topic == .troubleshooting })
        else { return nil }
        let bearing = Set([base] + byWords)
        return setup.checks(for: bearing).first { !$0.isFine && $0.isUrgent && $0.fixArticle != nil }?.fixArticle
    }

    /// Read the setup again. Permissions change in System Settings while Help is open.
    func refreshSetup() {
        let now = HelpSetup.current()
        guard now != setup else { return }
        setup = now
        let problems = now.problems.map(\.id).joined(separator: ", ")
        Log.app.notice("Help: setup read, problems: \(problems.isEmpty ? "none" : problems, privacy: .public)")
    }

    /// Back to an empty field, with no answer.
    func clear() {
        task?.cancel()
        question = ""
        state = .idle
    }
}

/// The model's way into the help articles.
struct SearchHelpTool: Tool {
    /// What each search returned, first search first, so the answer can name the
    /// articles it came from.
    final class Found: Sendable {
        private let ids = Mutex<[HelpArticle.ID]>([])
        func record(_ new: [HelpArticle.ID]) {
            ids.withLock { ids in ids += new.filter { !ids.contains($0) } }
        }
        var all: [HelpArticle.ID] {
            ids.withLock { $0 }
        }
    }

    let found = Found()
    /// The person's own words. The model writes its own search, and its words can lead
    /// elsewhere: asked "my microphone isn't picking anything up", it searched for
    /// recording audio and found the articles about recording calls.
    let question: String
    /// The article the model chose from the titles, before any words were matched.
    let pick: HelpArticle.ID?
    let name = "searchHelp"
    let description = "Searches Indite's help articles and returns the ones that match, in full."

    @Generable
    struct Arguments {
        @Guide(description: "Words describing what the person wants to do or fix")
        var query: String
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        // The article chosen by meaning first, then the question as the person put it,
        // then the model's own search.
        var articles = pick.flatMap(HelpArticle.article(id:)).map { [$0] } ?? []
        for article in HelpArticle.search(question) where !articles.contains(article) {
            articles.append(article)
        }
        for article in HelpArticle.search(arguments.query) where !articles.contains(article) {
            articles.append(article)
        }
        articles = Array(articles.prefix(3))
        found.record(articles.map(\.id))
        // With fifty articles, handing the model all of them when none matched led it
        // to answer from whichever it read first.
        guard !articles.isEmpty else { return "No help article matches that." }
        return articles
            .map { "# \($0.title)\n\n\($0.body)" }
            .joined(separator: "\n\n")
    }
}

extension HelpArticle {
    /// Words too common to say which article a question is about.
    private static let stopWords: Set<String> = [
        "the", "and", "how", "can", "you", "your", "does", "doesn", "did", "didn", "what",
        "why", "who", "which", "when", "where", "with", "for", "from", "into", "onto",
        "this", "that", "these", "those", "are", "was", "were", "been", "being", "have",
        "has", "had", "its", "isn", "aren", "wasn", "won", "don", "not", "any", "all",
        "anything", "something", "get", "got", "just", "keep", "keeps", "make",
        "makes", "made", "then", "there", "here", "will", "would", "should", "could",
        "about", "after", "before", "over", "under", "more", "most", "some", "such",
        "than", "too", "very", "also", "only", "still", "even", "want", "need", "way",
        "use", "using", "used", "mine", "our", "their", "they", "them",
        // The app's name, and its first name, which people still type.
        "indite", "nscribe"
    ]

    /// The telling words of a text: common words left out before endings are cut, so
    /// "notes" cannot turn into the left-out "not".
    static func words(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .map(stem))
    }

    /// A word without its common English ending, so "wiping" finds "wipes" and
    /// "copied" finds "copy". Rough, and the same on both sides of a comparison, which
    /// is all a match needs.
    private static func stem(_ word: String) -> String {
        var word = word
        if word.count >= 5, word.hasSuffix("ies") || word.hasSuffix("ied") {
            word = String(word.dropLast(3)) + "y"
        } else if word.count >= 6, word.hasSuffix("ing") {
            word.removeLast(3)
        } else if word.count >= 5, word.hasSuffix("ed") {
            word.removeLast(2)
        } else if word.count >= 5, ["sses", "xes", "zes", "ches", "shes"].contains(where: word.hasSuffix) {
            word.removeLast(2)
        } else if word.count >= 4, word.hasSuffix("s"), !word.hasSuffix("ss") {
            word.removeLast()
        }
        // "wipe" and "wip", from "wipes" and "wiping", become one.
        if word.count > 3, word.hasSuffix("e") { word.removeLast() }
        return word
    }

    /// The articles that share the most telling words with a query, best first: the
    /// best one, and any that come close to it. None when nothing is shared.
    ///
    /// Close means three quarters of the best score. Asked why the Globe key opens the
    /// emoji picker, a search that also returned "Change the dictation key", which
    /// shares only "Globe" and "key", led the small model to answer with that article's
    /// fix instead.
    static func search(_ query: String) -> [HelpArticle] {
        let wanted = words(in: query)
        // A word in the title says more about what the article is for than the same
        // word in its body, so it counts twice.
        let scored = all.map { article in
            let titleWords = words(in: article.title)
            let score = wanted.intersection(articleWords[article.id] ?? []).reduce(0.0) { total, word in
                total + (weight[word] ?? 0) * (titleWords.contains(word) ? 2 : 1)
            }
            return (article, score)
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return [] }
        return scored.filter { $0.1 >= best * 0.75 }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }

    /// Each article's words, worked out once.
    private static let articleWords: [HelpArticle.ID: Set<String>] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, words(in: $0.title + " " + $0.body)) }
    )

    /// How much a shared word says about which article is meant: a word in one article
    /// says a lot, a word in half of them very little. Counting every word as one made
    /// "use" tie with "offline", and a tie is a coin toss between two articles.
    private static let weight: [String: Double] = {
        var counts: [String: Int] = [:]
        for words in articleWords.values {
            for word in words { counts[word, default: 0] += 1 }
        }
        let total = Double(all.count)
        return counts.mapValues { log(1 + total / Double($0)) }
    }()
}
