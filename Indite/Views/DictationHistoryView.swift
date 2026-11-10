import Combine
import SwiftUI
import SwiftData

#if os(macOS)

/// Recent dictations, so one that landed in the wrong window is recoverable.
///
/// A list of rows grouped by day, each the dictation itself. Each row carries its own
/// buttons, shown under the pointer and on the selected row: Insert, Copy, Transcribe
/// Again and the switch between the AI's version and the words as heard. They used to
/// sit in the toolbar and act on the selected row, and Jonathan could not find them
/// there. The toolbar keeps Delete and Clear All.
struct DictationHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    /// Read so the list is drawn again when the window comes forward: Insert names
    /// the app it will type into, and that is whichever app was in front before.
    @Environment(\.appearsActive) private var appearsActive

    @Query(sort: \Dictation.createdAt, order: .reverse) private var dictations: [Dictation]

    @State private var selection: PersistentIdentifier?
    /// The row under the pointer, which shows its buttons.
    @State private var hovered: PersistentIdentifier?
    @State private var searchText = ""
    /// The dictation copied last, so its Copy button alone shows the checkmark.
    @State private var justCopied: PersistentIdentifier?
    @State private var isConfirmingClearAll = false
    /// The dictations shown in full. The rest stop at four lines.
    @State private var expanded: Set<PersistentIdentifier> = []
    /// The dictations the AI changed that are shown as heard. Insert and Copy take
    /// the version shown. Nothing in the store changes.
    @State private var showingHeard: Set<PersistentIdentifier> = []
    /// The last change Undo can take back: a dictation deleted, or one transcribed again.
    @State private var undo = DictationUndo()
    /// The start of today, for the line above the list and the day headings. Set again
    /// whenever the day changes, since "Today", the week and the days in a row depend
    /// on it.
    @State private var today = Calendar.current.startOfDay(for: .now)
    /// Why the last Transcribe Again left its dictation as it was.
    @State private var transcribeAgainFailure: String?

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

    /// The dictations of one day, newest first.
    private struct Day: Identifiable {
        let start: Date
        var dictations: [Dictation]
        var id: Date { start }
    }

    /// The list as searched, split by the day each dictation was made. The list is
    /// newest first, so each day's dictations are next to each other.
    private var days: [Day] {
        var days: [Day] = []
        for dictation in filtered {
            let start = Calendar.current.startOfDay(for: dictation.createdAt)
            if days.last?.start == start {
                days[days.count - 1].dictations.append(dictation)
            } else {
                days.append(Day(start: start, dictations: [dictation]))
            }
        }
        return days
    }

    var body: some View {
        VStack(spacing: 0) {
            // The banner shows only while older entries are still listed. With none
            // left, the empty state below already says that history is off.
            if !settings.keepDictationHistory && !dictations.isEmpty {
                Label("Keeping recent dictations is switched off in Settings, so nothing new is kept.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
            }

            HistoryTotals(
                limit: settings.keepDictationHistory ? settings.dictationHistoryLimit : nil,
                today: today
            )

            if dictations.isEmpty {
                if settings.keepDictationHistory {
                    ContentUnavailableView(
                        "No Dictations Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Finished dictations appear here.")
                    )
                } else {
                    ContentUnavailableView {
                        Label("Dictations Are Not Kept", systemImage: "clock.arrow.circlepath")
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

            // Delete and Transcribe Again act at once, as they should for one row among
            // a hundred, and this is the way back.
            if let message = undo.message {
                HStack {
                    Text(message)
                    Spacer()
                    Button("Undo") { undo.undo(in: modelContext) }
                        .keyboardShortcut("z")
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .frame(minWidth: 600, minHeight: 320)
        // The day changes at midnight, which the system reports on waking when the Mac
        // slept through it, and when the Mac moves to another time zone. Either may be
        // posted from another thread.
        .onReceive(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
                .receive(on: DispatchQueue.main)
        ) { _ in
            today = Calendar.current.startOfDay(for: .now)
        }
        .navigationTitle("Recent Dictations")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search dictations")
        .toolbar {
            // Insert, Copy, Transcribe Again and the switch to the words as heard are
            // on the rows. Delete stays here as well as on the Delete key, since a
            // button on every row would put it a click away from Insert.
            ToolbarItem {
                Button(role: .destructive) {
                    if let selected { delete(selected) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selected == nil)
                .help("Delete the selected dictation")
            }

            // Behind a menu, as Notes keeps its rarer commands, so a stray click on
            // the toolbar never starts the one command that cannot be undone.
            ToolbarItem {
                Menu {
                    Button("Clear All\u{2026}", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                    .disabled(dictations.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Clear the history")
                .confirmationDialog(
                    dictations.count == 1 ? "Delete 1 dictation?" : "Delete all \(dictations.count) dictations?",
                    isPresented: $isConfirmingClearAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        // The dialog says this cannot be undone, so the Undo of a
                        // dictation deleted just before ends too, and its recording goes.
                        undo.end()
                        DictationHistory.clear(in: modelContext)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This cannot be undone.")
                }
            }
        }
        .alert(
            "Indite could not transcribe this dictation again.",
            isPresented: Binding(
                get: { transcribeAgainFailure != nil },
                set: { if !$0 { transcribeAgainFailure = nil } }
            ),
            presenting: transcribeAgainFailure
        ) { _ in
            Button("OK") { }
        } message: { reason in
            Text(reason)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(days) { day in
                Section(heading(for: day.start)) {
                    ForEach(day.dictations) { dictation in
                        row(for: dictation)
                    }
                }
            }
        }
        // Return inserts the selected dictation, and so does a double click, as
        // Return opens the selected file in the Finder.
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            if let id = ids.first, let dictation = filtered.first(where: { $0.persistentModelID == id }) {
                menu(for: dictation)
            }
        } primaryAction: { ids in
            if let id = ids.first, let dictation = filtered.first(where: { $0.persistentModelID == id }),
               !dictation.recognitionFailed {
                insert(dictation)
            }
        }
        // The Delete key.
        .onDeleteCommand {
            if let selected { delete(selected) }
        }
    }

    /// "Today", "Yesterday", then the day's date: "Saturday, November 8", with the
    /// year when it is not this one.
    private func heading(for day: Date) -> String {
        if day == today { return "Today" }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        if !Calendar.current.isDate(day, equalTo: today, toGranularity: .year) {
            style = style.year()
        }
        return day.formatted(style)
    }

    // MARK: - Row

    private func row(for dictation: Dictation) -> some View {
        let id = dictation.persistentModelID
        let isExpanded = expanded.contains(id)
        let text = shownText(of: dictation)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The day is in the heading above.
                Text(dictation.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if let destination = dictation.destination {
                    Text("→ \(destination)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Which version the row shows, while it shows the words as heard: the
                // prompt's name would claim the AI's version.
                if let version = showingHeard.contains(id) ? "As heard" : dictation.promptName {
                    Text(version)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }

                if coordinator.transcribingAgain == id {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Transcribing again\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                buttons(for: dictation)
            }

            // Not selectable as text: a click on the words selects the row,
            // and Copy is a command.
            if dictation.recognitionFailed {
                // Kept for its recording alone, which may still hold the words.
                Text(dictation.hasRecording
                     ? "Recognition failed, and no words were heard. Transcribe Again can read the recording."
                     : "Recognition failed, and no words were heard.")
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .lineLimit(isExpanded ? nil : 4)
            }

            // A long dictation stopped at four lines with no way to read on.
            // In gray, not the link blue: blue all but vanished on the azure
            // of a selected row, where gray turns white with the rest.
            if Self.isLong(text) {
                Button(isExpanded ? "Show less" : "Show all") {
                    if isExpanded {
                        expanded.remove(id)
                    } else {
                        expanded.insert(id)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // The whole row, gaps included, so the buttons do not blink out on the way
        // from the words to them.
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = id
            } else if hovered == id {
                hovered = nil
            }
        }
        .tag(id)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                delete(dictation)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The row's own buttons, shown under the pointer and on the selected row.
    ///
    /// Always laid out and only hidden, so a row keeps its height when the pointer
    /// crosses it. A failed row always shows Transcribe Again, the one thing it is
    /// kept for.
    private func buttons(for dictation: Dictation) -> some View {
        let id = dictation.persistentModelID
        let isShown = hovered == id || selection == id
        let isHeard = showingHeard.contains(id)

        return HStack(spacing: 6) {
            if !dictation.recognitionFailed {
                Button {
                    insert(dictation)
                } label: {
                    Label("Insert", systemImage: "text.cursor")
                }
                .help(insertHelp)
                .opacity(isShown ? 1 : 0)

                Button {
                    copy(dictation)
                } label: {
                    Label("Copy", systemImage: justCopied == id ? "checkmark" : "doc.on.doc")
                }
                .help(isHeard ? "Copy the words as heard" : "Copy the dictation")
                .opacity(isShown ? 1 : 0)
            }

            // Wispr Flow calls this "Undo AI edit". A switch, so the AI's version is
            // one click away again.
            if dictation.wasEditedByAI {
                Button {
                    if isHeard {
                        showingHeard.remove(id)
                    } else {
                        showingHeard.insert(id)
                    }
                } label: {
                    Label(isHeard ? "AI Version" : "As Heard", systemImage: isHeard ? "sparkles" : "waveform")
                }
                .help(isHeard ? "Show the AI\u{2019}s version" : "Show the words as they were heard, before the AI changed them")
                .opacity(isShown ? 1 : 0)
            }

            if dictation.hasRecording {
                Button {
                    transcribeAgain(dictation)
                } label: {
                    Label("Transcribe Again", systemImage: "arrow.clockwise")
                }
                .disabled(!coordinator.canTranscribeAgain)
                .help("Read this dictation\u{2019}s recording again with your current words and prompt")
                .opacity(isShown || dictation.recognitionFailed ? 1 : 0)
            }
        }
        .buttonStyle(RowButtonStyle())
        // The style draws its own ring; see `RowButtonStyle`.
        .focusEffectDisabled()
        // Hidden buttons take no clicks, and VoiceOver reaches the same commands in
        // the row's menu.
        .allowsHitTesting(isShown || dictation.recognitionFailed)
        .accessibilityHidden(!isShown && !dictation.recognitionFailed)
    }

    /// The row's right-click menu: the row's buttons, and Delete.
    @ViewBuilder
    private func menu(for dictation: Dictation) -> some View {
        let id = dictation.persistentModelID
        if !dictation.recognitionFailed {
            Button(insertTitle) { insert(dictation) }
            Button("Copy") { copy(dictation) }
        }
        if dictation.wasEditedByAI {
            if showingHeard.contains(id) {
                Button("Show AI Version") { showingHeard.remove(id) }
            } else {
                Button("Show as Heard") { showingHeard.insert(id) }
            }
        }
        if dictation.hasRecording {
            Button("Transcribe Again") { transcribeAgain(dictation) }
                .disabled(!coordinator.canTranscribeAgain)
        }
        Divider()
        Button("Delete", role: .destructive) { delete(dictation) }
    }

    /// The version the row shows: the AI's, or the words as heard when the user
    /// switched to them.
    private func shownText(of dictation: Dictation) -> String {
        if showingHeard.contains(dictation.persistentModelID), let raw = dictation.rawText {
            return raw
        }
        return dictation.text
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

    /// The row's Insert button is too narrow for the app's name, so its tooltip says it.
    private var insertHelp: String {
        _ = appearsActive
        guard let name = coordinator.appInFront?.localizedName else {
            return "Type this dictation where the cursor is in the app you came from"
        }
        return "Type this dictation where the cursor is in \(name)"
    }

    /// Copy the version the row shows, and show the checkmark on its button.
    private func copy(_ dictation: Dictation) {
        ClipboardService.copy(shownText(of: dictation))
        confirmCopy(dictation.persistentModelID)
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
        undo.delete(dictation, in: modelContext)
    }

    /// Transcribe the dictation again from its recording, and offer Undo once its words
    /// have changed, with a note on anything that fell short, or say why they were left
    /// as they were.
    ///
    /// The words it held are kept for Undo before it is read: a second reading can be
    /// worse than the first, and the first is otherwise lost.
    private func transcribeAgain(_ dictation: Dictation) {
        let earlier = DictationUndo.EarlierWords(of: dictation)
        // New words replace both versions, so the row shows the new AI version.
        showingHeard.remove(dictation.persistentModelID)
        Task {
            switch await coordinator.transcribeAgain(dictation) {
            case .replaced(let note):
                undo.transcribedAgain(earlier, note: note)
            case .failed(let reason):
                transcribeAgainFailure = reason
            }
        }
    }

    /// Show the checkmark, then take it back.
    ///
    /// Nothing else ever clears it, so a button left showing the checkmark would still
    /// claim a copy that happened an hour ago.
    private func confirmCopy(_ id: PersistentIdentifier) {
        justCopied = id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if justCopied == id {
                justCopied = nil
            }
        }
    }

    /// Send the version the row shows to the app the user was in before coming to this
    /// window.
    ///
    /// Deliberately not the app it originally went to: the point is usually that the
    /// first destination was wrong. Not the frontmost app either, which is Indite
    /// itself, whose focused field is this window's search box.
    private func insert(_ dictation: Dictation) {
        let text = shownText(of: dictation)
        Task {
            // deliver brings the target in front of this window and waits until it is
            // there. Hiding Indite first, as this used to, also hid the meeting
            // indicator and guessed at how long the next app took to come forward.
            let outcome = await TextInsertionService.deliver(
                text,
                targetApp: coordinator.appInFront,
                restoreClipboard: settings.restoreClipboardAfterPaste,
                autoSubmit: false,
                // A snippet's saved text goes in as it was written, as it did the
                // first time.
                keepsText: Snippets.holdsSavedText(text, snippets: settings.snippets),
                names: settings.vocabularyHints
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
                characterCount: text.count,
                destination: destination,
                settings: settings
            )
        }
    }
}

/// The look of a row's buttons: a solid pill in the window's own colors.
///
/// Drawn here because the system's bordered button all but vanished on a selected row.
/// A selected row is azure at full strength, and the bordered button's translucent gray
/// and its text turned white with the row, so Transcribe Again was "practically
/// invisible". This pill keeps its own fill and text whatever the row behind it is: white
/// with dark text in light mode, dark gray with white text in dark mode.
///
/// The keyboard focus ring is drawn in the text's color for the same reason: the
/// system's ring is the accent color, which is the selected row's own azure.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }

    /// The pill's fill: white in light mode; in dark mode, a gray a step lighter than
    /// the list, as a pop-up button's, so an unselected row's pill stands off it.
    private static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.25, alpha: 1) : .white
    })

    private struct RowButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Color(nsColor: .controlTextColor))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(RowButtonStyle.fill)
                    if configuration.isPressed {
                        Capsule().fill(Color(nsColor: .labelColor).opacity(0.12))
                    }
                }
                .overlay {
                    if isFocused {
                        Capsule().strokeBorder(Color(nsColor: .controlTextColor), lineWidth: 2)
                    } else {
                        Capsule().strokeBorder(Color(nsColor: .separatorColor))
                    }
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
        }
    }
}

/// What Undo in Recent Dictations takes back: the dictation deleted last, or the words a
/// dictation held before Transcribe Again replaced them.
///
/// One change at a time, offered for eight seconds; the next change ends the one before,
/// and so does Clear All. A deleted dictation's recording stays on disk while Undo can
/// bring it back, and goes when the offer ends.
@MainActor
@Observable
final class DictationUndo {

    /// What it takes to put a deleted dictation back as it was.
    struct DeletedDictation {
        let text: String
        let rawText: String?
        let destination: String?
        let promptName: String?
        let spokenDuration: TimeInterval?
        let recordingFileName: String?
        let createdAt: Date
    }

    /// The words a dictation held before Transcribe Again replaced them: the text, the
    /// words as heard, and the prompt that wrote the text.
    struct EarlierWords {
        let dictation: Dictation
        let text: String
        let rawText: String?
        let promptName: String?

        init(of dictation: Dictation) {
            self.dictation = dictation
            text = dictation.text
            rawText = dictation.rawText
            promptName = dictation.promptName
        }
    }

    private enum Change {
        case deleted(DeletedDictation)
        case transcribedAgain(EarlierWords)
    }

    /// What the bar beside Undo says, while a change can be taken back.
    private(set) var message: String?

    @ObservationIgnored private var change: Change?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// Delete a dictation at once, and offer to put it back.
    func delete(_ dictation: Dictation, in context: ModelContext) {
        let deleted = DeletedDictation(
            text: dictation.text,
            rawText: dictation.rawText,
            destination: dictation.destination,
            promptName: dictation.promptName,
            spokenDuration: dictation.spokenDuration,
            recordingFileName: dictation.recordingFileName,
            createdAt: dictation.createdAt
        )
        context.delete(dictation)
        context.saveOrLog()
        // No dictation names the recording until Undo puts it back. Marked as just
        // written, it is not taken for a leftover by another copy of Indite launching
        // meanwhile.
        DictationAudioStore.markHeldForUndo(fileNamed: deleted.recordingFileName)
        offer(.deleted(deleted), saying: "Dictation deleted.")
    }

    /// Offer to put back the words a dictation held before it was transcribed again,
    /// with what fell short on the way, such as a rewrite that failed.
    func transcribedAgain(_ earlier: EarlierWords, note: String?) {
        offer(.transcribedAgain(earlier), saying: ["Dictation transcribed again.", note].compactMap { $0 }.joined(separator: " "))
    }

    /// Take the change back: the deleted dictation goes back where it was, by its own
    /// date and with its recording, or the dictation transcribed again gets its earlier
    /// words back.
    func undo(in context: ModelContext) {
        switch change {
        case .deleted(let deleted):
            context.insert(Dictation(
                text: deleted.text,
                rawText: deleted.rawText,
                destination: deleted.destination,
                promptName: deleted.promptName,
                spokenDuration: deleted.spokenDuration,
                recordingFileName: deleted.recordingFileName,
                createdAt: deleted.createdAt
            ))
            context.saveOrLog()
        case .transcribedAgain(let earlier):
            // One the history's limit has deleted since has nothing to put them back into.
            if !earlier.dictation.isDeleted, earlier.dictation.modelContext != nil {
                earlier.dictation.text = earlier.text
                earlier.dictation.rawText = earlier.rawText
                earlier.dictation.promptName = earlier.promptName
                context.saveOrLog()
            }
        case nil:
            break
        }
        // Taken back, so nothing is left to end: a recording put back with its
        // dictation stays.
        expiry?.cancel()
        change = nil
        message = nil
    }

    /// End the offer. A dictation deleted is then gone for good, and its recording
    /// with it.
    func end() {
        expiry?.cancel()
        expiry = nil
        if case .deleted(let deleted) = change {
            DictationAudioStore.delete(fileNamed: deleted.recordingFileName)
        }
        change = nil
        message = nil
    }

    /// Offer Undo for a change, and end the offer before it: Undo takes back only the
    /// change made last.
    private func offer(_ change: Change, saying message: String) {
        end()
        self.change = change
        self.message = message
        // Held strongly, so the offer still ends, and a deleted dictation's recording
        // still goes, when the window closes before the eight seconds are up.
        expiry = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self.end()
        }
    }
}

/// The line at the top of Recent Dictations: the words, the speaking speed and the days
/// in a row.
///
/// A view of its own with its own query, so that a click in the list does not add the
/// history up again. In an optimized build, adding up 100 dictations took 2 ms and 500
/// took 12 ms, about half of it counting words.
private struct HistoryTotals: View {
    /// How many dictations the history keeps, for the tooltip, or nil while keeping
    /// them is switched off.
    let limit: Int?
    /// The start of today. The line is drawn again when the day changes, since the week
    /// and the days in a row depend on it.
    let today: Date

    @Query private var dictations: [Dictation]

    var body: some View {
        let days = DictationHistory.days(seedingFrom: dictations)
        if let totals = DictationHistory.totals(of: dictations, days: days, now: today) {
            // Inset to the left edge of the rows' text below it.
            Text(Self.line(for: totals))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(tooltip)
        }
    }

    /// What the line is counted from, whether or not new dictations are kept.
    private var tooltip: String {
        guard let limit else {
            return "The words and the speed are counted from the dictations kept here. Keeping recent dictations is switched off in Settings, so nothing new is counted."
        }
        return "The words and the speed are counted from the dictations kept here. Indite keeps the last \(limit), as set in Settings. The days in a row also count days whose dictations are no longer kept."
    }

    /// The totals as one line: "620 words this week · 4,100 since Nov 4 · 151 words a
    /// minute · 6 days in a row".
    ///
    /// The week is left out while every dictation kept is from this week. The history
    /// may then have dropped the week's first days, and the words since the oldest
    /// dictation kept are the week's as far back as it goes.
    private static func line(for totals: DictationHistory.Totals) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if !Calendar.current.isDate(totals.since, equalTo: .now, toGranularity: .year) {
            style = style.year()
        }
        let since = "since \(totals.since.formatted(style))"

        var parts: [String] = []
        if totals.since < totals.weekBegan {
            parts.append("\(words(totals.wordsThisWeek)) this week")
            parts.append("\(totals.words.formatted()) \(since)")
        } else {
            parts.append("\(words(totals.words)) \(since)")
        }
        if let wordsPerMinute = totals.wordsPerMinute {
            parts.append("\(words(wordsPerMinute)) a minute")
        }
        // A single day is not yet a run.
        if totals.daysInARow > 1 {
            parts.append("\(totals.daysInARow) days in a row")
        }
        return parts.joined(separator: " · ")
    }

    private static func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count.formatted()) words"
    }
}
#endif
