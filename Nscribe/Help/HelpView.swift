import SwiftUI

#if os(macOS)

/// Which article the Help window shows, set from the menu, Spotlight or Siri.
@MainActor
@Observable
final class HelpNavigator {
    static let shared = HelpNavigator()
    static let windowID = "help"

    var selectedID: HelpArticle.ID? = HelpArticle.all.first?.id
    var searchText = ""

    /// The articles that contain every word searched for, or all of them.
    var visibleArticles: [HelpArticle] {
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return HelpArticle.all }
        return HelpArticle.all.filter { article in
            let text = (article.title + " " + article.body).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Opens the Help window, at this article when one is given.
    func show(_ articleID: HelpArticle.ID?) {
        if let articleID { selectedID = articleID }
        FamilyWindows.show(Self.windowID)
    }

    /// Opens the Help window with these words asked as a question. Siri's "search
    /// Nscribe for …" arrives here.
    func search(_ term: String) {
        HelpAssistant.shared.ask(term)
        if let first = HelpArticle.search(term).first { selectedID = first.id }
        FamilyWindows.show(Self.windowID)
    }
}

struct HelpView: View {
    @Bindable private var navigator = HelpNavigator.shared

    var body: some View {
        NavigationSplitView {
            List(navigator.visibleArticles, selection: $navigator.selectedID) { article in
                Text(article.title)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .searchable(text: $navigator.searchText, placement: .sidebar, prompt: "Search Help")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AskView()
                    if let id = navigator.selectedID, let article = HelpArticle.article(id: id) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(article.title)
                                .font(.title2.bold())
                            Text(article.body)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
            }
        }
        .navigationTitle("Nscribe Help")
    }
}

/// A question, and the answer the assistant gives from the articles.
private struct AskView: View {
    @Bindable private var assistant = HelpAssistant.shared
    @Bindable private var navigator = HelpNavigator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask a question about Nscribe", text: $assistant.question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { assistant.ask(assistant.question) }

            switch assistant.state {
            case .idle:
                EmptyView()
            case .thinking:
                ProgressView("Looking it up…")
                    .controlSize(.small)
            case .answered(let answer, let sources):
                VStack(alignment: .leading, spacing: 8) {
                    Text(answer)
                        .textSelection(.enabled)
                    if !sources.isEmpty {
                        HStack(spacing: 4) {
                            Text("From")
                                .foregroundStyle(.secondary)
                            ForEach(sources, id: \.self) { id in
                                if let article = HelpArticle.article(id: id) {
                                    Button(article.title) { navigator.selectedID = id }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#endif
