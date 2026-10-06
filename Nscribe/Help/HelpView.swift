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

    /// Opens the Help window searching for these words, at the first article found.
    func search(_ term: String) {
        searchText = term
        selectedID = visibleArticles.first?.id ?? selectedID
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
            if let id = navigator.selectedID, let article = HelpArticle.article(id: id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(article.title)
                            .font(.title2.bold())
                        Text(article.body)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(24)
                }
            } else {
                ContentUnavailableView("Choose an article", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Nscribe Help")
    }
}

#endif
