import SwiftUI
import SwiftData

#if os(macOS)

/// Recent dictations, so one that landed in the wrong window is recoverable.
///
/// A list of rows, each the dictation itself. The commands are in the toolbar for
/// the selected row, in its right-click menu and on a swipe, as a list's commands are
/// in Notes and Mail. Every row used to carry a bar of four buttons in small type.
struct DictationHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    /// Read so the list is drawn again when the window comes forward: Insert names
    /// the app it will type into, and that is whichever app was in front before.
    @Environment(\.appearsActive) private var appearsActive

    @Query(sort: \Dictation.createdAt, order: .reverse) private var dictations: [Dictation]

    @State private var selection: PersistentIdentifier?
    @State private var searchText = ""
    @State private var justCopied: CopiedKind?
    @State private var isConfirmingClearAll = false
    /// The dictations shown in full. The rest stop at four lines.
    @State private var expanded: Set<PersistentIdentifier> = []
    /// The dictation deleted last, held for a few seconds so it can be put back.
    @State private var lastDeleted: DeletedDictation?
    @State private var undoTimeout: Task<Void, Never>?

    /// What it takes to put a deleted dictation back as it was.
    private struct DeletedDictation {
        let text: String
        let rawText: String?
        let destination: String?
        let promptName: String?
        let createdAt: Date
    }

    /// Which copy last completed, so only that button's own symbol changes.
    private enum CopiedKind: Equatable {
        case cleaned(PersistentIdentifier)
        case original(PersistentIdentifier)
    }

    /// Matches the original transcript as well as the delivered text: the user
    /// remembers the words they said, which the AI may have rewritten.
    private var filtered: [Dictation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return dictations }
        return dictations.filter {
            $0.text.localizedStandardContains(query)
                || ($0.rawText?.localizedStandardContains(query) ?? false)
        }
    }

    /// The selected dictation, when it is in the list as searched.
    private var selected: Dictation? {
        filtered.first { $0.persistentModelID == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The banner shows only while older entries are still listed. With none
            // left, the empty state below already says that history is off.
            if !settings.keepDictationHistory && !dictations.isEmpty {
                Label("History is switched off in Settings, so nothing new is being kept.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
            }

            if dictations.isEmpty {
                if settings.keepDictationHistory {
                    ContentUnavailableView(
                        "No Dictations Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Finished dictations appear here.")
                    )
                } else {
                    ContentUnavailableView {
                        Label("History Is Off", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Turn on \u{201C}Keep recent dictations\u{201D} in Settings.")
                    } actions: {
                        SettingsLink {
                            Text("Open Settings\u{2026}")
                        }
                    }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                list
            }

            // Delete acts at once, as it should for one row among a hundred, and
            // this is the way back.
            if lastDeleted != nil {
                HStack {
                    Text("Dictation deleted.")
                    Spacer()
                    Button("Undo") { undoDelete() }
                        .keyboardShortcut("z")
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .frame(minWidth: 600, minHeight: 320)
        .navigationTitle("Dictation History")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search dictations")
        .toolbar {
            // For the selected dictation. Insert first: it is the reason the window
            // exists, so it carries its title.
            ToolbarItemGroup {
                Button {
                    if let selected { insert(selected) }
                } label: {
                    Label(insertTitle, systemImage: "text.cursor")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(selected == nil)
                .help("Type the selected dictation where the cursor is in the app you came from")

                Button {
                    if let selected { copy(selected.text, as: .cleaned(selected.persistentModelID)) }
                } label: {
                    Label("Copy", systemImage: copiedCleaned ? "checkmark" : "doc.on.doc")
                }
                .disabled(selected == nil)
                .help("Copy the selected dictation")

                Button(role: .destructive) {
                    if let selected { delete(selected) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selected == nil)
                .help("Delete the selected dictation")
            }

            // The rarer two, behind the toolbar's own More menu as Notes keeps its
            // own. Laid out as buttons they overflowed the toolbar at the window's
            // usual width.
            ToolbarItem {
                Menu {
                    Button("Copy Original") {
                        if let selected, let raw = selected.rawText {
                            copy(raw, as: .original(selected.persistentModelID))
                        }
                    }
                    .disabled(selected?.wasEditedByAI != true || selected?.rawText == nil)

                    Divider()

                    Button("Clear All\u{2026}", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                    .disabled(dictations.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Copy the words as they were heard, or clear the history")
                .confirmationDialog(
                    dictations.count == 1 ? "Delete 1 dictation?" : "Delete all \(dictations.count) dictations?",
                    isPresented: $isConfirmingClearAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        DictationHistory.clear(in: modelContext)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This cannot be undone.")
                }
            }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filtered) { dictation in
                let isExpanded = expanded.contains(dictation.persistentModelID)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        timestamp(for: dictation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if let destination = dictation.destination {
                            Text("→ \(destination)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let prompt = dictation.promptName {
                            Text(prompt)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }

                    // Not selectable as text: a click on the words selects the row,
                    // and Copy is a command.
                    Text(dictation.text)
                        .lineLimit(isExpanded ? nil : 4)

                    // A long dictation stopped at four lines with no way to read on.
                    if Self.isLong(dictation.text) {
                        Button(isExpanded ? "Show less" : "Show all") {
                            if isExpanded {
                                expanded.remove(dictation.persistentModelID)
                            } else {
                                expanded.insert(dictation.persistentModelID)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
                .tag(dictation.persistentModelID)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(dictation)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(insertTitle) { insert(dictation) }
                    Button("Copy") { copy(dictation.text, as: .cleaned(dictation.persistentModelID)) }
                    if dictation.wasEditedByAI, let raw = dictation.rawText {
                        Button("Copy Original") { copy(raw, as: .original(dictation.persistentModelID)) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { delete(dictation) }
                }
            }
        }
        // The Delete key.
        .onDeleteCommand {
            if let selected { delete(selected) }
        }
    }

    /// Whether a dictation is likely to run past four lines: by its length, or by its
    /// own line breaks. A guess, since the lines depend on the window's width; a
    /// "Show all" on text that already fits costs nothing.
    private static func isLong(_ text: String) -> Bool {
        text.count > 280 || text.filter(\.isNewline).count > 3
    }

    /// "Insert into Mail", naming the app the text will be typed into.
    private var insertTitle: String {
        _ = appearsActive
        guard let name = coordinator.appInFront?.localizedName else { return "Insert" }
        return "Insert into \(name)"
    }

    /// Whether the selected dictation was just copied, one way or the other.
    private var copiedCleaned: Bool {
        selected.map { justCopied == .cleaned($0.persistentModelID) } ?? false
    }

    private var copiedOriginal: Bool {
        selected.map { justCopied == .original($0.persistentModelID) } ?? false
    }

    private func copy(_ text: String, as kind: CopiedKind) {
        ClipboardService.copy(text)
        confirmCopy(kind)
    }

    /// Take the dictation out at once, and select the one below it, or the one above
    /// when it was last, as Notes and Mail do.
    private func delete(_ dictation: Dictation) {
        let listed = filtered
        if selection == dictation.persistentModelID,
           let index = listed.firstIndex(where: { $0.persistentModelID == dictation.persistentModelID }) {
            let next = index + 1 < listed.count ? listed[index + 1] : (index > 0 ? listed[index - 1] : nil)
            selection = next?.persistentModelID
        }

        lastDeleted = DeletedDictation(
            text: dictation.text,
            rawText: dictation.rawText,
            destination: dictation.destination,
            promptName: dictation.promptName,
            createdAt: dictation.createdAt
        )
        modelContext.delete(dictation)
        modelContext.saveOrLog()

        undoTimeout?.cancel()
        undoTimeout = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            lastDeleted = nil
        }
    }

    /// Put the dictation deleted last back where it was, by its own date.
    private func undoDelete() {
        guard let deleted = lastDeleted else { return }
        modelContext.insert(Dictation(
            text: deleted.text,
            rawText: deleted.rawText,
            destination: deleted.destination,
            promptName: deleted.promptName,
            createdAt: deleted.createdAt
        ))
        modelContext.saveOrLog()
        undoTimeout?.cancel()
        lastDeleted = nil
    }

    /// The time alone for something dictated today; the date and time otherwise, so
    /// a week-old entry does not read as though it just happened.
    private func timestamp(for dictation: Dictation) -> Text {
        if Calendar.current.isDateInToday(dictation.createdAt) {
            return Text(dictation.createdAt, style: .time)
        }
        return Text(dictation.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Show the checkmark, then take it back.
    ///
    /// Nothing else in the toolbar ever clears it, so a button left showing the
    /// checkmark would still claim a copy that happened an hour ago.
    private func confirmCopy(_ kind: CopiedKind) {
        justCopied = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if justCopied == kind {
                justCopied = nil
            }
        }
    }

    /// Send it to the app the user was in before coming to this window.
    ///
    /// Deliberately not the app it originally went to: the point is usually that the
    /// first destination was wrong. Not the frontmost app either, which is Inscribe
    /// itself, whose focused field is this window's search box.
    private func insert(_ dictation: Dictation) {
        Task {
            // deliver brings the target in front of this window and waits until it is
            // there. Hiding Inscribe first, as this used to, also hid the meeting
            // indicator and guessed at how long the next app took to come forward.
            let outcome = await TextInsertionService.deliver(
                dictation.text,
                targetApp: coordinator.appInFront,
                restoreClipboard: settings.restoreClipboardAfterPaste,
                autoSubmit: false
            )

            // Reported as a notification rather than in-window text: the target app
            // is now in front of this window, so a banner drawn here would report the
            // outcome somewhere the user is no longer looking. "Clipboard" makes the
            // notification say the text was copied, so the user knows to paste it.
            let destination = switch outcome {
            case .inserted(let appName): appName
            case .copiedToClipboard, .pastedUnconfirmed: "Clipboard"
            }
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: dictation.text.count,
                destination: destination,
                settings: settings
            )
        }
    }
}
#endif
