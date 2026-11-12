import SwiftUI

// MARK: - Words Settings

/// The words Indite should know, each with an optional replacement, and the saved
/// text a spoken cue stands for.
///
/// Each list is one row here, with a count and an Edit button that opens it in a
/// sheet, as System Settings keeps its Text Replacements under Keyboard. In the tab
/// itself the three lists ran one under another: a text box, a table and a stack of
/// forms, each scrolling inside the page.
struct WordsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var vocabulary: [WordRow] = []
    @State private var snippets: [SnippetRow] = []
    @State private var editing: List?

    enum List: String, Identifiable {
        case vocabulary, snippets
        var id: String { rawValue }
    }

    /// One editable row. Each carries its own identity so SwiftUI does not reshuffle
    /// text fields as the user types a key that collides with another row.
    /// A word, and what to write instead when it is heard. With no replacement it is
    /// a Vocabulary word; with one, a word replacement. The two are still stored apart,
    /// because they act at different points: a Vocabulary word steers what the
    /// recognizer hears, and a replacement changes the words once heard.
    struct WordRow: Identifiable, Equatable {
        let id = UUID()
        var word: String
        var replacement = ""
        /// A replacement stored with nothing to write, which deletes the word. The
        /// editor no longer makes these, but one stored before keeps working.
        var removes = false

        var isReplacement: Bool { removes || !replacement.trimmingCharacters(in: .whitespaces).isEmpty }
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
                        detail: "Names and words Indite should know, and words to write another way.",
                        count: settings.vocabularyHints.count + settings.wordReplacements.count, noun: "word")
                listRow(.snippets,
                        title: "Snippets",
                        detail: "Say a few words, and Indite types saved text.",
                        count: settings.snippets.filter(\.isComplete).count, noun: "snippet")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: vocabulary) { _, _ in commitVocabulary() }
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
                vocabulary = hints.map { WordRow(word: $0) } + vocabulary.filter(\.isReplacement)
            }
        }
        .sheet(item: $editing) { list in
            switch list {
            case .vocabulary: VocabularySheet(rows: $vocabulary)
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
            + settings.wordReplacements
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { WordRow(word: $0.key, replacement: $0.value, removes: $0.value.isEmpty) }
        // In the order they were added, as they were left.
        snippets = settings.snippets.map { SnippetRow(cue: $0.cue, text: $0.text) }
    }

    /// The Vocabulary words as the rows hold them: rows with no replacement, blank
    /// ones left out.
    private static func words(_ rows: [WordRow]) -> [String] {
        rows.filter { !$0.isReplacement }
            .map { $0.word.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Store the rows apart again: words with no replacement as Vocabulary, the rest as
    /// word replacements. A replacement with nothing to write deletes the word, as
    /// TextProcessor treats it.
    private func commitVocabulary() {
        let words = Self.words(vocabulary)
        if words != settings.vocabularyHints { settings.vocabularyHints = words }
        var replacements: [String: String] = [:]
        for row in vocabulary where row.isReplacement {
            let word = row.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            replacements[word] = row.replacement.trimmingCharacters(in: .whitespaces)
        }
        if replacements != settings.wordReplacements { settings.wordReplacements = replacements }
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

/// Words Indite should know, each with an optional replacement, as Wispr Flow keeps
/// both in one Dictionary. A word alone helps Indite hear it and spell it your way; a
/// word with a replacement is written as the replacement whenever it is heard. They
/// were two lists side by side, and nobody could say how a replacement differed from
/// a snippet.
private struct VocabularySheet: View {
    @Binding var rows: [WordsSettingsView.WordRow]
    @State private var search = ""
    @State private var newWord = ""
    @State private var newReplacement = ""
    @FocusState private var focus: Field?

    private enum Field { case word, replacement }

    var body: some View {
        ListSheet(
            title: "Vocabulary",
            detail: "Names and words Indite should know, spelled your way. Give a word a replacement, and Indite writes that instead whenever it hears the word.",
            search: $search,
            warning: hasDuplicates ? "A word has two replacements. Only one will be used." : nil
        ) {
            HStack {
                TextField("Word", text: $newWord, prompt: Text("Add a word"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .word)
                    .onSubmit(add)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                TextField("Replace with", text: $newReplacement, prompt: Text("Replace with (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .replacement)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } content: {
            ScrollViewReader { proxy in
                let shown = rows.filter { matches(search, $0.word, $0.replacement) }
                List {
                    ForEach(shown) { row in
                        HStack {
                            TextField("Word", text: binding(row.id, \.word))
                                .textFieldStyle(.plain)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(row.isReplacement ? .secondary : .quaternary)
                            TextField("Replace with", text: binding(row.id, \.replacement),
                                      prompt: Text(row.removes ? "(removed)" : ""))
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
        .onAppear { focus = .word }
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
        search = ""
        let duplicate = replacement.isEmpty
            && rows.contains { !$0.isReplacement && $0.word.caseInsensitiveCompare(word) == .orderedSame }
        if !duplicate {
            rows.insert(WordsSettingsView.WordRow(word: word, replacement: replacement), at: 0)
        }
        newWord = ""
        newReplacement = ""
        focus = .word
    }

    /// Whether two replacements start from the same word, ignoring case the way
    /// matching does. The stored list keeps one per word, so the other is not saved.
    private var hasDuplicates: Bool {
        let words = rows.filter(\.isReplacement)
            .map { $0.word.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Set(words).count != words.count
    }

    private func binding(_ id: WordsSettingsView.WordRow.ID,
                         _ field: WritableKeyPath<WordsSettingsView.WordRow, String>) -> Binding<String> {
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
