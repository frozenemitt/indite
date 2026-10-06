import Foundation
import FoundationModels
import os

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
        it returns. Answer in two to four plain sentences and name the exact settings, \
        switches and buttons the articles name. If the articles do not cover the \
        question, say so in one sentence and do not guess.
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
            let session = LanguageModelSession(tools: [SearchHelpTool()], instructions: Self.instructions)
            do {
                let response = try await session.respond(to: question)
                guard !Task.isCancelled else { return }
                let sources = HelpArticle.search(question).map(\.id)
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

/// The model's way into the help articles.
struct SearchHelpTool: Tool {
    let name = "searchHelp"
    let description = "Searches Nscribe's help articles and returns the ones that match, in full."

    @Generable
    struct Arguments {
        @Guide(description: "Words describing what the person wants to do or fix")
        var query: String
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        HelpArticle.search(arguments.query)
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

    /// The articles that share the most words with a query, best first. With nothing
    /// in common, every article: the model reads them and decides.
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
        let matching = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
        return matching.isEmpty ? all : Array(matching)
    }
}
