import SwiftUI

// MARK: - Words Settings

/// The words Indite should know, the ones it should always write differently, and the
/// saved text a spoken cue stands for.
struct WordsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var vocabularyText = ""
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
                Text("Names and jargon you use, one per line. Indite prefers these when it is unsure, and spells them the way you write them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Names and jargon, in the system font. In monospaced type they read
                // as code.
                TextEditor(text: $vocabularyText)
                    .font(.body)
                    .frame(minHeight: 120)
                    .onChange(of: vocabularyText) { _, text in
                        settings.vocabularyHints = text
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }

            Section("Word Replacements") {
                Text("Whole words only, ignoring case. Leave the written word empty to delete the heard one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasDuplicateReplacements {
                    Label {
                        Text("Two rows have the same heard word. Only one of them will be applied.")
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
                Text("Say the cue in a dictation, and Indite types the text exactly as you wrote it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasDuplicateCues {
                    Label {
                        Text("Two snippets have the same cue. Only the first of them is typed.")
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
                    TextField("Cue", text: $snippet.cue, prompt: Text("my calendar link"))

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
