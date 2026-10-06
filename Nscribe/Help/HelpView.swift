import SwiftUI

#if os(macOS)

/// What the Help window shows, set from the menu, Spotlight or Siri.
@MainActor
@Observable
final class HelpNavigator {
    static let shared = HelpNavigator()
    static let windowID = "help"

    /// The article shown under the answer, or chosen from the list. None at first:
    /// the window opens on the question, not on an article.
    var selectedID: HelpArticle.ID?
    var searchText = ""
    /// The article list is there to browse, but asking comes first.
    var columns: NavigationSplitViewVisibility = .detailOnly
    /// Bumped to put the cursor in the question field.
    private(set) var focusRequest = 0

    /// The articles that contain every word searched for, or all of them.
    var visibleArticles: [HelpArticle] {
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return HelpArticle.all }
        return HelpArticle.all.filter { article in
            let text = (article.title + " " + article.body).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Opens the Help window ready for a question.
    func ask() {
        focusRequest += 1
        FamilyWindows.show(Self.windowID)
    }

    /// Opens the Help window at an article.
    func show(_ articleID: HelpArticle.ID) {
        selectedID = articleID
        FamilyWindows.show(Self.windowID)
    }

    /// Opens the Help window with these words asked as a question. Siri's "search
    /// Nscribe for …" arrives here.
    func search(_ term: String) {
        HelpAssistant.shared.ask(term)
        FamilyWindows.show(Self.windowID)
    }
}

struct HelpView: View {
    @Bindable private var navigator = HelpNavigator.shared
    @Bindable private var assistant = HelpAssistant.shared

    private var isLanding: Bool {
        assistant.state == .idle && navigator.selectedID == nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $navigator.columns) {
            List(navigator.visibleArticles, selection: $navigator.selectedID) { article in
                Text(article.title)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .searchable(text: $navigator.searchText, placement: .sidebar, prompt: "Search Articles")
        } detail: {
            if isLanding {
                LandingView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        QuestionField(size: .regular)
                        AnswerView()
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
        }
        .navigationTitle("Nscribe Help")
    }
}

/// What the window opens on: one question, and what to ask.
private struct LandingView: View {
    private static let examples = [
        "How do I change the dictation key?",
        "Why does the Globe key open the emoji picker?",
        "How do I record both sides of a call?"
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("What do you need help with?")
                .font(.title2.bold())
            QuestionField(size: .large)
            Text("Ask a question, or describe what isn't working. Nscribe answers from its help articles, on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) { HelpAssistant.shared.ask(example) }
                        .buttonStyle(.link)
                }
            }
            .padding(.top, 4)
            Button("Browse all articles") { HelpNavigator.shared.columns = .all }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 12)
        }
        .frame(maxWidth: 480)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The question, asked on Return.
private struct QuestionField: View {
    let size: ControlSize
    @Bindable private var assistant = HelpAssistant.shared
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Ask a question about Nscribe", text: $assistant.question)
            .textFieldStyle(.roundedBorder)
            .controlSize(size)
            .focused($focused)
            .onSubmit { assistant.ask(assistant.question) }
            .onAppear { focused = true }
            .onChange(of: HelpNavigator.shared.focusRequest) { focused = true }
    }
}

/// The answer, and the articles it came from.
private struct AnswerView: View {
    @Bindable private var assistant = HelpAssistant.shared

    var body: some View {
        switch assistant.state {
        case .idle:
            EmptyView()
        case .thinking:
            ProgressView("Looking it up…")
                .controlSize(.small)
        case .answered(let answer, let sources):
            VStack(alignment: .leading, spacing: 8) {
                // The model writes Markdown emphasis around setting names.
                Text((try? AttributedString(
                    markdown: answer,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(answer))
                    .textSelection(.enabled)
                if !sources.isEmpty {
                    HStack(spacing: 4) {
                        Text("From")
                            .foregroundStyle(.secondary)
                        ForEach(sources, id: \.self) { id in
                            if let article = HelpArticle.article(id: id) {
                                Button(article.title) { HelpNavigator.shared.selectedID = id }
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

#endif
