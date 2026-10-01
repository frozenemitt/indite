import SwiftUI

// MARK: - Words Settings

/// The words Inscribe should know, and the ones it should always write differently.
struct WordsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var vocabularyText = ""
    @State private var replacements: [ReplacementRow] = []

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

                TextEditor(text: $vocabularyText)
                    .font(.system(.body, design: .monospaced))
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

                ForEach($replacements) { $row in
                    HStack {
                        TextField("Heard", text: $row.spoken, prompt: Text("heard"))
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("Written", text: $row.written, prompt: Text("written"))
                        Button("Remove Replacement", systemImage: "minus.circle") {
                            replacements.removeAll { $0.id == row.id }
                            commitReplacements()
                        }
                        .labelStyle(.iconOnly)
                        .help("Remove Replacement")
                        .buttonStyle(.borderless)
                    }
                    // A grouped form shows a field's title as a label beside it; the
                    // arrow already says which side is which.
                    .labelsHidden()
                    .onChange(of: row) { _, _ in commitReplacements() }
                }

                Button {
                    replacements.append(ReplacementRow(spoken: "", written: ""))
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
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
