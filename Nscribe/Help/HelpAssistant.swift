import Foundation
import FoundationModels
import os
import Synchronization

/// Answers questions about Nscribe from the help articles, on Apple's on-device model.
///
/// Siri finds no help article by meaning (see `Docs/help-and-siri.md`), so answers come
/// from here: the model searches the articles through a tool and answers from what it
/// reads. Siri's "search Nscribe for …" hands its words to `ask`.
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
    private var task: Task<Void, Never>?

    private static let instructions = """
        You answer questions about Nscribe, a Mac app for dictation and meeting \
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

        if let reason = FoundationModelsHelper.unavailabilityReason() {
            state = .failed(reason)
            return
        }

        state = .thinking
        task = Task {
            // A fresh session for every question: each one stands alone, and a long
            // conversation would only crowd the small model's context.
            let tool = SearchHelpTool()
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
                state = .failed("Nscribe couldn't answer that: \(error.localizedDescription)")
                Log.app.error("Help assistant failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension HelpAssistant {
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
    let name = "searchHelp"
    let description = "Searches Nscribe's help articles and returns the ones that match, in full."

    @Generable
    struct Arguments {
        @Guide(description: "Words describing what the person wants to do or fix")
        var query: String
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        let articles = HelpArticle.search(arguments.query)
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
        "use", "using", "used", "mine", "our", "their", "they", "them", "nscribe"
    ]

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The articles that share the most telling words with a query, best first: the
    /// best one, and any that come close to it. None when nothing is shared.
    ///
    /// Close means three quarters of the best score. Asked why the Globe key opens the
    /// emoji picker, a search that also returned "Change the dictation key", which
    /// shares only "Globe" and "key", led the small model to answer with that article's
    /// fix instead.
    static func search(_ query: String) -> [HelpArticle] {
        let wanted = words(in: query).filter { $0.count > 2 && !stopWords.contains($0) }
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
