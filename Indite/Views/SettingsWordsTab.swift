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
                        detail: "Names and unusual words you use. When Indite is unsure what it heard, it chooses these, and spells them your way.",
                        count: settings.vocabularyHints.count, noun: "word")
                listRow(.replacements,
                        title: "Word Replacements",
                        detail: "A word Indite hears, and the word it writes instead.",
                        count: settings.wordReplacements.count, noun: "replacement")
                listRow(.snippets,
                        title: "Snippets",
                        detail: "Text you use often, such as an address. Say its words, and Indite types the text exactly as you saved it.",
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

/// A sheet holding one list: a title and what it is for, a search field, the table, +
/// and − under it, and Done.
private struct ListSheet<Content: View>: View {
    let title: String
    let detail: String
    @Binding var search: String
    var warning: String?
    var canRemove: Bool
    let add: () -> Void
    let remove: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                TextField("Search", text: $search, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
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

            content

            HStack(spacing: 4) {
                Button("Add", systemImage: "plus", action: add)
                    .help("Add")
                Button("Remove", systemImage: "minus", action: remove)
                    .disabled(!canRemove)
                    .help("Remove")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .labelStyle(.titleOnly)
                    .buttonStyle(.borderedProminent)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440, idealHeight: 520)
    }
}

/// Whether a row's text holds the search, ignoring case.
private func matches(_ search: String, _ texts: String...) -> Bool {
    let search = search.trimmingCharacters(in: .whitespaces)
    return search.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(search) }
}

private struct VocabularySheet: View {
    @Binding var rows: [WordsSettingsView.WordRow]
    @State private var selection: Set<WordsSettingsView.WordRow.ID> = []
    @State private var search = ""

    var body: some View {
        ListSheet(
            title: "Vocabulary",
            detail: "Names and unusual words you use. When Indite is unsure what it heard, it chooses these, and spells them the way you write them here.",
            search: $search,
            canRemove: !selection.isEmpty,
            add: {
                search = ""
                let row = WordsSettingsView.WordRow(word: "")
                rows.append(row)
                selection = [row.id]
            },
            remove: {
                rows.removeAll { selection.contains($0.id) }
                selection = []
            }
        ) {
            Table(rows.filter { matches(search, $0.word) }, selection: $selection) {
                TableColumn("Word") { row in
                    TextField("Word", text: binding(row.id), prompt: Text("Name or word"))
                        .labelsHidden()
                }
            }
            .onDeleteCommand {
                rows.removeAll { selection.contains($0.id) }
                selection = []
            }
        }
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
    @State private var selection: Set<WordsSettingsView.ReplacementRow.ID> = []
    @State private var search = ""

    var body: some View {
        ListSheet(
            title: "Word Replacements",
            detail: "When Indite hears the word on the left, it writes the word on the right. Capital letters make no difference, and only whole words are replaced. Leave the right side empty to remove the word.",
            search: $search,
            warning: hasDuplicates ? "Two rows start from the same word. Indite will use only one of them." : nil,
            canRemove: !selection.isEmpty,
            add: {
                search = ""
                let row = WordsSettingsView.ReplacementRow(spoken: "", written: "")
                rows.append(row)
                selection = [row.id]
            },
            remove: {
                rows.removeAll { selection.contains($0.id) }
                selection = []
            }
        ) {
            Table(rows.filter { matches(search, $0.spoken, $0.written) }, selection: $selection) {
                TableColumn("Indite hears") { row in
                    TextField("Indite hears", text: binding(row.id, \.spoken), prompt: Text("gonna"))
                        .labelsHidden()
                }
                TableColumn("Indite writes") { row in
                    TextField("Indite writes", text: binding(row.id, \.written), prompt: Text("going to"))
                        .labelsHidden()
                }
            }
            .onDeleteCommand {
                rows.removeAll { selection.contains($0.id) }
                selection = []
            }
        }
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
    @State private var selection: Set<WordsSettingsView.SnippetRow.ID> = []
    @State private var search = ""

    var body: some View {
        ListSheet(
            title: "Snippets",
            detail: "Say the words on the left in a dictation, and Indite types the text on the right exactly as you saved it, line breaks included.",
            search: $search,
            warning: hasDuplicateCues ? "Two snippets are called up by the same words. Indite types only the first." : nil,
            canRemove: !selection.isEmpty,
            add: {
                search = ""
                let row = WordsSettingsView.SnippetRow(cue: "", text: "")
                rows.append(row)
                selection = [row.id]
            },
            remove: {
                rows.removeAll { selection.contains($0.id) }
                selection = []
            }
        ) {
            Table(rows.filter { matches(search, $0.cue, $0.text) }, selection: $selection) {
                TableColumn("What you say") { row in
                    TextField("What you say", text: binding(row.id, \.cue), prompt: Text("my calendar link"))
                        .labelsHidden()
                }
                .width(min: 140, ideal: 180, max: 260)
                TableColumn("What Indite types") { row in
                    // One line here; the box below holds the whole text.
                    Text(row.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(row.text.isEmpty ? .secondary : .primary)
                }
            }
            .frame(minHeight: 160)
            .onDeleteCommand {
                rows.removeAll { selection.contains($0.id) }
                selection = []
            }

            // Saved text can run to several lines, as an address or a signature does,
            // which a table cell cannot hold. The selected snippet's text is edited here.
            if selection.count == 1, let id = selection.first, rows.contains(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What Indite types")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextEditor(text: binding(id, \.text))
                        .font(.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background, in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            } else {
                Text("Select a snippet to edit the text Indite types.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            }
        }
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
