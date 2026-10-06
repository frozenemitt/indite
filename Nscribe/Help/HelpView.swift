import SwiftUI

#if os(macOS)

/// What the Help window shows, set from the menu, Spotlight or Siri.
@MainActor
@Observable
final class HelpNavigator {
    static let shared = HelpNavigator()
    static let windowID = "help"

    /// The article opened in the list, under the answer or chosen by hand.
    var openArticleID: HelpArticle.ID?
    /// Bumped to put the cursor in the field.
    private(set) var focusRequest = 0

    /// Opens the Help window ready for a question.
    func ask() {
        focusRequest += 1
        FamilyWindows.show(Self.windowID)
    }

    /// Opens the Help window at an article, with the whole list around it.
    func show(_ articleID: HelpArticle.ID) {
        HelpAssistant.shared.clear()
        openArticleID = articleID
        FamilyWindows.show(Self.windowID)
    }

    /// Opens the Help window with these words asked as a question. Siri's "search
    /// Nscribe for …" arrives here.
    func search(_ term: String) {
        HelpAssistant.shared.ask(term)
        FamilyWindows.show(Self.windowID)
    }
}

/// One field: typing narrows the articles beneath it, Return asks the assistant, and
/// the answer sits above the articles that match. The Help menu's search in any Mac
/// app works the same way.
struct HelpView: View {
    @Bindable private var assistant = HelpAssistant.shared
    @Bindable private var navigator = HelpNavigator.shared
    @FocusState private var fieldFocused: Bool
    @Environment(\.openSettings) private var openSettings

    private static let examples = [
        "How do I change the dictation key?",
        "Why does the Globe key open the emoji picker?",
        "How do I record both sides of a call?"
    ]

    private var query: String {
        assistant.question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An answer, or the question being answered, belongs to the words in the field
    /// only while they are the words that were asked.
    private var showsAnswer: Bool {
        assistant.state != .idle && query == assistant.askedQuestion
    }

    private var articles: [HelpArticle] {
        query.isEmpty ? HelpArticle.all : HelpArticle.matches(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            List {
                if query.isEmpty, !showsAnswer {
                    Section("Try Asking") {
                        ForEach(Self.examples, id: \.self) { example in
                            Button(example) { assistant.ask(example) }
                                .buttonStyle(.link)
                                .listRowSeparator(.hidden)
                        }
                    }
                } else if showsAnswer {
                    Section("Answer") {
                        answer.listRowSeparator(.hidden)
                    }
                } else {
                    Section {
                        Button { assistant.ask(query) } label: {
                            Label("Ask “\(query)”", systemImage: "sparkle")
                        }
                        .buttonStyle(.borderless)
                        .listRowSeparator(.hidden)
                    }
                }

                Section("Articles") {
                    if articles.isEmpty {
                        Text("No article matches. Press Return to ask.")
                            .foregroundStyle(.secondary)
                    }
                    // Space between sections, not a rule between every row.
                    ForEach(articles) { article in
                        ArticleRow(article: article)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle("Nscribe Help")
        .frame(minWidth: 520, minHeight: 400)
        .onAppear { fieldFocused = true }
        .onChange(of: navigator.focusRequest) { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Ask a question, or describe what isn't working", text: $assistant.question)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit { assistant.ask(assistant.question) }
            if !assistant.question.isEmpty {
                Button {
                    assistant.clear()
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var answer: some View {
        switch assistant.state {
        case .idle:
            EmptyView()
        case .thinking:
            ProgressView("Looking it up…")
                .controlSize(.small)
                .padding(.vertical, 4)
        case .answered(let text, let sources):
            let source = sources.first.flatMap(HelpArticle.article(id:))
            VStack(alignment: .leading, spacing: 10) {
                // The model writes Markdown emphasis around setting names.
                Text((try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(text))
                    .font(.title3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = source?.action {
                    Button(action.title) { perform(action) }
                        .controlSize(.large)
                }
                if let source {
                    HStack(spacing: 4) {
                        Text("Answered from")
                            .foregroundStyle(.secondary)
                        Button(source.title) { navigator.openArticleID = source.id }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 4)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
        }
    }
}

extension HelpView {
    private func perform(_ action: HelpArticle.Action) {
        switch action {
        case .nscribeSettings:
            openSettings()
            WindowFronting.bringForward("com_apple_SwiftUI_Settings")
        case .keyboardSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        case .screenRecordingSettings:
            SystemAudioCapture.openSystemSettings()
        }
    }
}

/// An article in the list, opened in place.
private struct ArticleRow: View {
    let article: HelpArticle
    @Bindable private var navigator = HelpNavigator.shared

    private var isOpen: Binding<Bool> {
        Binding(
            get: { navigator.openArticleID == article.id },
            set: { navigator.openArticleID = $0 ? article.id : nil }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isOpen) {
            Text(article.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        } label: {
            Label(article.title, systemImage: "doc.text")
        }
    }
}

#endif
