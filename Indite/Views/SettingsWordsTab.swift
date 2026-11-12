import SwiftUI

// MARK: - Words Settings

/// The words Indite should know, the ones it should always write differently, and the
/// saved text a spoken cue stands for.
///
/// Each list is one row here, with a count and an Edit button that opens it in a
/// sheet, as System Settings keeps its Text Replacements under Keyboard. In the tab
/// itself the three lists ran one under another: a text box, a table and a stack of
/// forms, each scrolling inside the page.
struct WordsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var vocabulary: [WordRow] = []
    @State private var replacements: [ReplacementRow] = []
    @State private var snippets: [SnippetRow] = []
    @State private var editing: List?

    enum List: String, Identifiable {
        case vocabulary, replacements, snippets
        var id: String { rawValue }
    }

    /// One editable row. Each carries its own identity so SwiftUI does not reshuffle
    /// text fields as the user types a key that collides with another row.
    struct WordRow: Identifiable, Equatable {
        let id = UUID()
        var word: String
    }

    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
    }

    struct SnippetRow: Identifiable, Equatable {
        let id = UUID()
        var cue: String
        var text: String
    }

    var body: some View {
        Form {
            Section {
                listRow(.vocabulary,
                        title: "Vocabulary",
                        detail: "Names and words Indite should know and spell your way.",
                        count: settings.vocabularyHints.count, noun: "word")
                listRow(.replacements,
                        title: "Word Replacements",
                        detail: "Words Indite should always write another way.",
                        count: settings.wordReplacements.count, noun: "replacement")
                listRow(.snippets,
                        title: "Snippets",
                        detail: "Say a few words, and Indite types saved text.",
                        count: settings.snippets.filter(\.isComplete).count, noun: "snippet")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: vocabulary) { _, _ in commitVocabulary() }
        .onChange(of: replacements) { _, _ in commitReplacements() }
        .onChange(of: snippets) { _, _ in commitSnippets() }
        // A word learned from a correction joins the list at once, open or not.
        // Without this, the next edit wrote the old list back, and the learned word
        // then counted as one the user had taken off for good.
        .onChange(of: settings.vocabularyHints) { _, hints in
            let listed = Self.words(vocabulary)
            guard listed != hints else { return }
            if hints.count > listed.count, hints.starts(with: listed) {
                vocabulary += hints.dropFirst(listed.count).map { WordRow(word: $0) }
            } else {
                vocabulary = hints.map { WordRow(word: $0) }
            }
        }
        .sheet(item: $editing) { list in
            switch list {
            case .vocabulary: VocabularySheet(rows: $vocabulary)
            case .replacements: ReplacementsSheet(rows: $replacements)
            case .snippets: SnippetsSheet(rows: $snippets)
            }
        }
    }

    private func listRow(_ list: List, title: String, detail: String, count: Int, noun: String) -> some View {
        LabeledContent {
            HStack(spacing: 12) {
                Text(count == 1 ? "1 \(noun)" : "\(count) \(noun)s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Edit…") { editing = list }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    // MARK: - Loading and Saving

    private func load() {
        vocabulary = settings.vocabularyHints.map { WordRow(word: $0) }
        replacements = settings.wordReplacements
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ReplacementRow(spoken: $0.key, written: $0.value) }
        // In the order they were added, as they were left.
        snippets = settings.snippets.map { SnippetRow(cue: $0.cue, text: $0.text) }
    }

    /// The Words list as the rows hold it, blank rows left out.
    private static func words(_ rows: [WordRow]) -> [String] {
        rows.map { $0.word.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func commitVocabulary() {
        let words = Self.words(vocabulary)
        if words != settings.vocabularyHints { settings.vocabularyHints = words }
    }

    /// Rebuild the stored dictionary from the rows, dropping only rows with no
    /// heard word to match. A blank written word is kept rather than dropped: it
    /// means "delete this word" rather than "do nothing", and TextProcessor
    /// already treats an empty replacement that way.
    private func commitReplacements() {
        var result: [String: String] = [:]
        for row in replacements {
            let spoken = row.spoken.trimmingCharacters(in: .whitespaces)
            let written = row.written.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { continue }
            result[spoken] = written
        }
        settings.wordReplacements = result
    }

    /// Store every row as it stands, in order. A row is typed once it has a cue and some
    /// text, but one still being filled in is stored too, and so is one whose cue
    /// another row has: a row left out was lost with whatever had been typed into it.
    /// The text is stored exactly as written, with its spaces and line breaks, because
    /// that is how it is typed.
    private func commitSnippets() {
        settings.snippets = snippets.map { Snippet(cue: $0.cue, text: $0.text) }
    }
}

// MARK: - The Sheets

/// A sheet holding one list. New entries are typed into fields at the top and added
/// with Return or the Add button, as Reminders adds a reminder: the + and − under a
/// table were hard to find, and + added an empty row below the last one, out of sight
/// in a long list. A new entry goes to the top, where it is seen, and each row has its
/// own delete button.
private struct ListSheet<AddBar: View, Content: View>: View {
    let title: String
    let detail: String
    @Binding var search: String
    var warning: String?
    @ViewBuilder let addBar: AddBar
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                addBar.padding(4)
            }

            if let warning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search, prompt: Text("Search"))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 2)

            content

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 560)
    }
}

/// Whether a row's text holds the search, ignoring case.
private func matches(_ search: String, _ texts: String...) -> Bool {
    let search = search.trimmingCharacters(in: .whitespaces)
    return search.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(search) }
}

/// The delete button at the end of a row.
private func deleteButton(_ action: @escaping () -> Void) -> some View {
    Button("Delete", systemImage: "minus.circle.fill", action: action)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Delete")
}

/// What a list shows when it holds nothing, or nothing the search finds.
private func emptyNote(_ text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}

private struct VocabularySheet: View {
    @Binding var rows: [WordsSettingsView.WordRow]
    @State private var search = ""
    @State private var newWord = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        ListSheet(
            title: "Vocabulary",
            detail: "Names and words Indite should know. It spells them the way you type them here.",
            search: $search
        ) {
            HStack {
                TextField("New word", text: $newWord, prompt: Text("Add a word"))
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } content: {
            ScrollViewReader { proxy in
                let shown = rows.filter { matches(search, $0.word) }
                List {
                    ForEach(shown) { row in
                        HStack {
                            TextField("Word", text: binding(row.id))
                                .textFieldStyle(.plain)
                            deleteButton { rows.removeAll { $0.id == row.id } }
                        }
                        .id(row.id)
                    }
                }
                .overlay { if shown.isEmpty { emptyNote(rows.isEmpty ? "No words yet." : "No words match.") } }
                .onChange(of: rows.first?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }
        .onAppear { addFocused = true }
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        search = ""
        if !rows.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            rows.insert(WordsSettingsView.WordRow(word: word), at: 0)
        }
        newWord = ""
        addFocused = true
    }

    private func binding(_ id: WordsSettingsView.WordRow.ID) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == id }?.word ?? "" },
            set: { value in
                if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].word = value }
            }
        )
    }
}

private struct ReplacementsSheet: View {
    @Binding var rows: [WordsSettingsView.ReplacementRow]
    @State private var search = ""
    @State private var heard = ""
    @State private var written = ""
    @FocusState private var focus: Field?

    private enum Field { case heard, written }

    var body: some View {
        ListSheet(
            title: "Word Replacements",
            detail: "When Indite hears the first word, it writes the second. Leave the second empty to drop the word.",
            search: $search,
            warning: hasDuplicates ? "A word is listed twice. Only one will be used." : nil
        ) {
            HStack {
                TextField("Indite hears", text: $heard, prompt: Text("Heard"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .heard)
                    .onSubmit { focus = .written }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Indite writes", text: $written, prompt: Text("Write as"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .written)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } content: {
            ScrollViewReader { proxy in
                let shown = rows.filter { matches(search, $0.spoken, $0.written) }
                List {
                    ForEach(shown) { row in
                        HStack {
                            TextField("Heard", text: binding(row.id, \.spoken))
                                .textFieldStyle(.plain)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            TextField("Write as", text: binding(row.id, \.written), prompt: Text("(drop it)"))
                                .textFieldStyle(.plain)
                            deleteButton { rows.removeAll { $0.id == row.id } }
                        }
                        .id(row.id)
                    }
                }
                .overlay { if shown.isEmpty { emptyNote(rows.isEmpty ? "No replacements yet." : "No replacements match.") } }
                .onChange(of: rows.first?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }
        .onAppear { focus = .heard }
    }

    private func add() {
        let spoken = heard.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty else { return }
        search = ""
        rows.insert(WordsSettingsView.ReplacementRow(spoken: spoken, written: written.trimmingCharacters(in: .whitespaces)), at: 0)
        heard = ""
        written = ""
        focus = .heard
    }

    /// Whether two rows share a heard word, ignoring case the way matching itself does.
    /// The stored list keeps one value per word, so the other row is not saved, and
    /// nothing else says so.
    private var hasDuplicates: Bool {
        let words = rows
            .map { $0.spoken.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Set(words).count != words.count
    }

    private func binding(_ id: WordsSettingsView.ReplacementRow.ID,
                         _ field: WritableKeyPath<WordsSettingsView.ReplacementRow, String>) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { value in
                if let index = rows.firstIndex(where: { $0.id == id }) { rows[index][keyPath: field] = value }
            }
        )
    }
}

private struct SnippetsSheet: View {
    @Binding var rows: [WordsSettingsView.SnippetRow]
    @State private var search = ""
    @State private var selection: WordsSettingsView.SnippetRow.ID?
    @State private var newCue = ""
    @FocusState private var focus: Field?

    private enum Field { case cue, text }

    var body: some View {
        ListSheet(
            title: "Snippets",
            detail: "Say the words, and Indite types the text, exactly as saved.",
            search: $search,
            warning: hasDuplicateCues ? "Two snippets use the same words. Only the first is typed." : nil
        ) {
            HStack {
                TextField("What you say", text: $newCue, prompt: Text("What you say"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .cue)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newCue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } content: {
            HStack(alignment: .top, spacing: 12) {
                ScrollViewReader { proxy in
                    let shown = rows.filter { matches(search, $0.cue, $0.text) }
                    List(selection: $selection) {
                        ForEach(shown) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.cue.isEmpty ? "Untitled" : row.cue)
                                    Text(row.text.isEmpty ? "No text yet" : row.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                deleteButton {
                                    if selection == row.id { selection = nil }
                                    rows.removeAll { $0.id == row.id }
                                }
                            }
                            .tag(row.id)
                            .id(row.id)
                        }
                    }
                    .overlay { if shown.isEmpty { emptyNote(rows.isEmpty ? "No snippets yet." : "No snippets match.") } }
                    .onChange(of: rows.first?.id) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                    }
                }
                .frame(width: 220)

                // Saved text can run to several lines, as an address or a signature does,
                // so the selected snippet is edited beside the list, not in a row.
                Group {
                    if let id = selection, rows.contains(where: { $0.id == id }) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What you say").font(.callout).foregroundStyle(.secondary)
                            TextField("What you say", text: binding(id, \.cue))
                                .textFieldStyle(.roundedBorder)
                            Text("Text to type").font(.callout).foregroundStyle(.secondary)
                            TextEditor(text: binding(id, \.text))
                                .font(.body)
                                .focused($focus, equals: .text)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(.background, in: .rect(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        }
                    } else {
                        emptyNote("Select a snippet.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { focus = .cue }
    }

    /// A new snippet goes to the top and is selected, with the cursor in its text, the
    /// part still to be written.
    private func add() {
        let cue = newCue.trimmingCharacters(in: .whitespaces)
        guard !cue.isEmpty else { return }
        search = ""
        let row = WordsSettingsView.SnippetRow(cue: cue, text: "")
        rows.insert(row, at: 0)
        selection = row.id
        newCue = ""
        focus = .text
    }

    /// Whether two snippets that are typed share a cue, as matching sees it: in any
    /// capitals, with any spaces between the words and either apostrophe. Only the
    /// first of them is typed, and nothing else says so.
    private var hasDuplicateCues: Bool {
        let cues = rows
            .map { Snippet(cue: $0.cue, text: $0.text) }
            .filter(\.isComplete)
            .map { Snippets.key($0.cue) }
        return Set(cues).count != cues.count
    }

    private func binding(_ id: WordsSettingsView.SnippetRow.ID,
                         _ field: WritableKeyPath<WordsSettingsView.SnippetRow, String>) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { value in
                if let index = rows.firstIndex(where: { $0.id == id }) { rows[index][keyPath: field] = value }
            }
        )
    }
}
