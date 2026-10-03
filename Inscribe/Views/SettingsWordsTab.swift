import SwiftUI

// MARK: - Words Settings

/// The words Inscribe should know, and the ones it should always write differently.
struct WordsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var vocabularyText = ""
    @State private var replacements: [ReplacementRow] = []
    @State private var selectedReplacement: ReplacementRow.ID?

    /// One editable row. Carries its own identity so SwiftUI does not reshuffle
    /// text fields as the user types a key that collides with another row.
    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
    }

    var body: some View {
        Form {
            Section("Vocabulary") {
                Text("Names and jargon you use, one per line. Inscribe prefers these when it is unsure, and spells them the way you write them here.")
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
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
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
}
