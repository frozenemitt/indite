import SwiftUI

#if os(macOS)

/// Which article the Help window shows, set from the menu, Spotlight or Siri.
@MainActor
@Observable
final class HelpNavigator {
    static let shared = HelpNavigator()
    static let windowID = "help"

    var selectedID: HelpArticle.ID? = HelpArticle.all.first?.id

    /// Opens the Help window, at this article when one is given.
    func show(_ articleID: HelpArticle.ID?) {
        if let articleID { selectedID = articleID }
        FamilyWindows.show(Self.windowID)
    }
}

struct HelpView: View {
    @Bindable private var navigator = HelpNavigator.shared

    var body: some View {
        NavigationSplitView {
            List(HelpArticle.all, selection: $navigator.selectedID) { article in
                Text(article.title)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
