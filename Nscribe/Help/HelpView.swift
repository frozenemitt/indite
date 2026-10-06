import SwiftUI

#if os(macOS)

/// What the Help window shows, set from the menu, Spotlight or Siri.
@MainActor
@Observable
final class HelpNavigator {
    enum Mode { case ask, browse }

    static let shared = HelpNavigator()
    static let windowID = "help"

    var mode: Mode = .ask
    /// The article open while browsing.
    var browsedArticleID: HelpArticle.ID?
    /// What is being typed in the question box, before it is asked.
    var draft = ""
    /// Bumped to put the cursor in the question box.
    private(set) var focusRequest = 0

    /// Opens the Help window ready for a question.
    func ask() {
        mode = .ask
        focusRequest += 1
        FamilyWindows.show(Self.windowID)
    }

    /// Opens the Help window at an article.
    func show(_ articleID: HelpArticle.ID) {
        mode = .browse
        browsedArticleID = articleID
        FamilyWindows.show(Self.windowID)
    }

    /// Opens the Help window with these words asked as a question. Siri's "search
    /// Nscribe for …" arrives here.
    func search(_ term: String) {
        mode = .ask
        HelpAssistant.shared.ask(term)
        FamilyWindows.show(Self.windowID)
    }

    /// Asks what is in the question box.
    func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        HelpAssistant.shared.ask(question)
    }
}

/// Asking first, as the AI labs' own apps do: a greeting over one question box; an
/// answer under its question, with the box moved to the bottom; and the articles behind
/// a link, where the box collapses into a bar to come back to.
struct HelpView: View {
    @Bindable private var navigator = HelpNavigator.shared
    @Bindable private var assistant = HelpAssistant.shared

    var body: some View {
        Group {
            switch navigator.mode {
            case .ask:
                if assistant.state == .idle {
                    LandingView()
                } else {
                    AnswerView()
                }
            case .browse:
                BrowseView()
            }
        }
        .navigationTitle("Nscribe Help")
        .frame(minWidth: 460, minHeight: 420)
    }
}

// MARK: - Asking

/// The question box, large and rounded, with its send arrow inside.
private struct QuestionBox: View {
    let placeholder: String
    @Bindable private var navigator = HelpNavigator.shared
    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        navigator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $navigator.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { navigator.submit() }
                .padding(.vertical, 3)
            Button { navigator.submit() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .help("Ask")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .onAppear { focused = true }
        .onChange(of: navigator.focusRequest) { focused = true }
    }
}

private struct LandingView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("What can I help you with?")
                .font(.title.weight(.semibold))
            QuestionBox(placeholder: "Ask about Nscribe, or describe what isn't working")
            Button("Browse all articles") { HelpNavigator.shared.mode = .browse }
                .buttonStyle(.link)
                .font(.callout)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

/// The question heads the page and the answer sits under it. The box moves to the
/// bottom for the next question.
private struct AnswerView: View {
    @Bindable private var assistant = HelpAssistant.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(assistant.question)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    content
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Browse all articles") { HelpNavigator.shared.mode = .browse }
                    .buttonStyle(.link)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
            QuestionBox(placeholder: "Ask another question")
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch assistant.state {
        case .idle:
            EmptyView()
        case .thinking:
            ProgressView("Looking it up…")
                .controlSize(.small)
        case .answered(let text, let sources):
            let source = sources.first.flatMap(HelpArticle.article(id:))
            // The model writes Markdown emphasis around setting names.
            Text((try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if let action = source?.action {
                    Button(action.title) { perform(action, openSettings: openSettings) }
                }
                Spacer()
                if let source {
                    Text("From")
                        .foregroundStyle(.secondary)
                    Button(source.title) { HelpNavigator.shared.show(source.id) }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Browsing

/// The articles by topic, under the question box collapsed into a bar.
private struct BrowseView: View {
    @Bindable private var navigator = HelpNavigator.shared

    var body: some View {
        VStack(spacing: 0) {
            Button(action: navigator.ask) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(.secondary)
                    Text("Ask about Nscribe")
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            if let id = navigator.browsedArticleID, let article = HelpArticle.article(id: id) {
                ArticlePage(article: article)
            } else {
                List {
                    ForEach(HelpArticle.Topic.allCases, id: \.self) { topic in
                        let articles = HelpArticle.all.filter { $0.topic == topic }
                        if !articles.isEmpty {
                            Section(topic.rawValue) {
                                ForEach(articles) { article in
                                    Button(article.title) { navigator.browsedArticleID = article.id }
                                        .buttonStyle(.plain)
                                        .listRowSeparator(.hidden)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct ArticlePage: View {
    let article: HelpArticle
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    HelpNavigator.shared.browsedArticleID = nil
                } label: {
                    Label("All Articles", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                .font(.callout)
                Text(article.title)
                    .font(.title3.weight(.semibold))
                Text(article.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = article.action {
                    Button(action.title) { perform(action, openSettings: openSettings) }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Actions

@MainActor
private func perform(_ action: HelpArticle.Action, openSettings: OpenSettingsAction) {
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

#endif
