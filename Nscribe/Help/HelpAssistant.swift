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
    /// The question the current answer belongs to. Editing the field past it shows the
    /// articles for the new words instead of an answer to the old ones.
    private(set) var askedQuestion = ""
    private var task: Task<Void, Never>?

    private static let instructions = """
        You answer questions about Nscribe, a Mac app for dictation and meeting \
        transcription. Always call searchHelp first, then answer only from the articles \
        it returns. Lead with the fix, not with why the problem happens. Answer in two \
        to four plain sentences and name the exact settings, \
        switches and buttons the articles name. Give the fix the articles give for the \
        exact problem asked about, and do not offer other settings as alternatives. If \
        the articles do not cover the question, say so in one sentence and do not guess.
        """

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        self.question = question
        askedQuestion = question
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
        askedQuestion = ""
        state = .idle
        #if os(macOS)
        HelpNavigator.shared.openArticleID = nil
        #endif
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
        return articles
            .map { "# \($0.title)\n\n\($0.body)" }
            .joined(separator: "\n\n")
    }
}

extension HelpArticle {
    /// Words too common to say which article a question is about.
    private static let stopWords: Set<String> = [
        "the", "and", "how", "can", "you", "does", "what", "why", "with", "for", "from",
        "into", "when", "where", "this", "that", "are", "its", "nscribe"
    ]

    /// The articles that share the most words with a query, best first: the best one,
    /// and any that come close to it. With nothing in common, every article, and the
    /// model reads them and decides.
    ///
    /// Close means three quarters of the best score. Asked why the Globe key opens the
    /// emoji picker, a search that also returned "Change the dictation key", which
    /// shares only "Globe" and "key", led the small model to answer with that article's
    /// fix instead.
    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// The articles sharing any word with what is typed, best first, for the list
    /// under the field. Unlike `search`, nothing when nothing matches.
    static func matches(_ query: String) -> [HelpArticle] {
        let wanted = words(in: query).filter { $0.count > 2 && !stopWords.contains($0) }
        guard !wanted.isEmpty else { return [] }
        return all
            .map { ($0, wanted.intersection(words(in: $0.title + " " + $0.body)).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func search(_ query: String) -> [HelpArticle] {
        let words = Set(query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) })
        let scored = all.map { article -> (HelpArticle, Int) in
            let text = Set((article.title + " " + article.body).lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init))
            return (article, words.intersection(text).count)
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return all }
        let threshold = max(1, Int((Double(best) * 0.75).rounded(.up)))
        return scored.filter { $0.1 >= threshold }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }
}
