import SwiftUI

// MARK: - Words Settings

/// The words Indite should know, the ones it should always write differently, and the
/// saved text a spoken cue stands for.
struct WordsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var vocabularyText = ""
    /// The cursor in the Vocabulary editor, kept where it is when a learned word is added.
    @State private var vocabularySelection: TextSelection?
    @State private var replacements: [ReplacementRow] = []
    @State private var selectedReplacement: ReplacementRow.ID?
    @State private var snippets: [SnippetRow] = []

    /// One editable row. Carries its own identity so SwiftUI does not reshuffle
    /// text fields as the user types a key that collides with another row.
    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
    }

    /// One editable snippet, with an identity of its own for the same reason.
    struct SnippetRow: Identifiable, Equatable {
        let id = UUID()
        var cue: String
        var text: String
    }

    var body: some View {
        Form {
            Section("Vocabulary") {
                Text("Names and unusual words you use, one per line. When Indite is unsure what it heard, it chooses these, and spells them the way you write them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Names and jargon, in the system font. In monospaced type they read
                // as code.
                TextEditor(text: $vocabularyText, selection: $vocabularySelection)
                    .font(.body)
                    .frame(minHeight: 120)
                    .onChange(of: vocabularyText) { _, text in
                        settings.vocabularyHints = Self.words(in: text)
                    }
                    // A word learned from a correction while this tab is open shows up at
                    // once. Without this, the next edit here wrote the old list back, and
                    // the learned word then counted as one the user had taken off for good.
                    // The editor's text is replaced only when words were taken off
                    // elsewhere, by Undo: replaced while the user types, the cursor jumped
                    // to the end, and the next keystrokes ran into the learned word.
                    .onChange(of: settings.vocabularyHints) { _, hints in
                        let listed = Self.words(in: vocabularyText)
                        guard listed != hints else { return }
                        if hints.count > listed.count, hints.starts(with: listed) {
                            addLines(hints.dropFirst(listed.count))
                        } else {
                            vocabularyText = hints.joined(separator: "\n")
                        }
                    }
            }

            Section("Word Replacements") {
                Text("When Indite hears the word on the left, it writes the word on the right. Capital letters make no difference, and only whole words are replaced. Leave the right side empty to remove the word.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasDuplicateReplacements {
                    Label {
                        Text("Two rows start from the same word. Indite will use only one of them.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }

                // A table with + and − under it, as System Settings keeps its Text
                // Replacements. It was a row of two fields and a minus for each pair.
                Table($replacements, selection: $selectedReplacement) {
                    TableColumn("Heard") { $row in
                        TextField("Heard", text: $row.spoken, prompt: Text("heard"))
                            .labelsHidden()
                    }
                    TableColumn("Written") { $row in
                        TextField("Written", text: $row.written, prompt: Text("written"))
                            .labelsHidden()
                    }
                }
                .frame(minHeight: 160)
                .onChange(of: replacements) { _, _ in commitReplacements() }
                .onDeleteCommand { removeSelectedReplacement() }

                HStack(spacing: 4) {
                    Button("Add Replacement", systemImage: "plus") {
                        let row = ReplacementRow(spoken: "", written: "")
                        replacements.append(row)
                        selectedReplacement = row.id
                    }
                    .help("Add Replacement")

                    Button("Remove Replacement", systemImage: "minus") {
                        removeSelectedReplacement()
                    }
                    .disabled(selectedReplacement == nil)
                    .help("Remove Replacement")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }

            Section("Snippets") {
                Text("Text you use often, such as an address or a link. Say its words in a dictation, and Indite types the saved text exactly as you wrote it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasDuplicateCues {
                    Label {
                        Text("Two snippets are called up by the same words. Indite types only the first.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            // A section for each, as the Apps tab gives each profile one. A table's
            // text field holds a single line, while saved text can run to several, as an
            // address or a signature does. In the editor, Return starts a new line.
            ForEach($snippets) { $snippet in
                Section {
                    TextField("What you say", text: $snippet.cue, prompt: Text("my calendar link"))

                    TextEditor(text: $snippet.text)
                        .font(.body)
                        .frame(minHeight: 60)

                    Button("Remove Snippet", role: .destructive) {
                        snippets.removeAll { $0.id == snippet.id }
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                Button("Add Snippet", systemImage: "plus") {
                    snippets.append(SnippetRow(cue: "", text: ""))
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: snippets) { _, _ in commitSnippets() }
    }

    private func removeSelectedReplacement() {
        guard let selectedReplacement else { return }
        replacements.removeAll { $0.id == selectedReplacement }
        self.selectedReplacement = nil
    }

    /// The Words list as the editor's text holds it: one entry per line, blank lines left out.
    private static func words(in text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Put words learned while the tab is open on lines of their own at the end of the
    /// editor, leaving the user's text and cursor as they are.
    private func addLines(_ learned: ArraySlice<String>) {
        let lines = learned.joined(separator: "\n")
        let text = vocabularyText
        let endsLine = text.isEmpty || text.hasSuffix("\n")
        if endsLine, case .selection(let range) = vocabularySelection?.indices, range.isEmpty, range.lowerBound == text.endIndex {
            // The cursor waits on an empty last line for the user's next word, so the
            // learned words go above it.
            vocabularyText = text + lines + "\n"
            vocabularySelection = TextSelection(insertionPoint: vocabularyText.endIndex)
        } else {
            vocabularyText = text + (endsLine ? "" : "\n") + lines
        }
    }

    private func load() {
        vocabularyText = settings.vocabularyHints.joined(separator: "\n")
        replacements = settings.wordReplacements
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ReplacementRow(spoken: $0.key, written: $0.value) }
        // In the order they were added, as they were left.
        snippets = settings.snippets.map { SnippetRow(cue: $0.cue, text: $0.text) }
    }

    /// Whether two rows share a heard word, ignoring case the way matching itself
    /// does. `commitReplacements` below can only keep one value per key, so this is
    /// the one thing about the list a row-by-row glance would not show: the other
    /// row is not saved, and nothing else says so.
    private var hasDuplicateReplacements: Bool {
        let spokenWords = replacements
            .map { $0.spoken.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Set(spokenWords).count != spokenWords.count
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

    /// Whether two snippets that are typed share a cue, as matching sees it: in any
    /// capitals, with any spaces between the words and either apostrophe. Only the
    /// first of them is typed, and nothing else says so.
    private var hasDuplicateCues: Bool {
        let cues = snippets
            .map { Snippet(cue: $0.cue, text: $0.text) }
            .filter(\.isComplete)
            .map { Snippets.key($0.cue) }
        return Set(cues).count != cues.count
    }

    /// Store every row as it stands, in order. A row is typed once it has a cue and some
    /// text, but one still being filled in is stored too, and so is one whose cue
    /// another row has: the tab is drawn again from what is stored each time it is
    /// shown, and a row left out was lost with whatever had been typed into it. The
    /// text is stored exactly as written, with its spaces and line breaks, because that
    /// is how it is typed.
    private func commitSnippets() {
        settings.snippets = snippets.map { Snippet(cue: $0.cue, text: $0.text) }
    }
}
