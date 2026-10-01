import SwiftUI
import os
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

/// Browse recorded meetings, read and correct them, and export.
///
/// A list and a page. Everything about one meeting is on its page, top to bottom:
/// who spoke, the summary, the transcript, and playback along the bottom. The
/// commands that act on the list sit directly above it. Delete used to be at the far
/// side of the window from the list it deleted from, and took one meeting at a time.
struct MeetingsView: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(TranscriptionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]

    @State private var selection: Set<Meeting> = []
    @State private var searchText = ""
    /// The meetings waiting on the delete confirmation.
    @State private var pendingDeletion: [Meeting] = []
    /// Why the last start failed, until the user dismisses it.
    @State private var startError: String?
    @State private var importer = MeetingImporter()
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Losing a meeting the user believed was saved is the worst outcome
                // here, so a store that is not writing to disk says so up front.
                if !MeetingStoreStatus.shared.isPersistent {
                    Label(
                        "Meetings are not being saved to disk and will be lost when you quit.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red)
                    .help(MeetingStoreStatus.shared.failureReason ?? "")
                }

                listBar
                sidebar
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            detail
        }
        .navigationTitle("Meetings")
        .frame(minWidth: 760, minHeight: 480)
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingDeletion.count == 1 ? "Delete" : "Delete \(pendingDeletion.count) Meetings", role: .destructive) {
                delete(pendingDeletion)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingDeletion.count == 1
                 ? "Its transcript, summary and recording will be deleted. This can\u{2019}t be undone."
                 : "Their transcripts, summaries and recordings will be deleted. This can\u{2019}t be undone.")
        }
        .alert(
            "Couldn\u{2019}t Start Meeting",
            isPresented: Binding(
                get: { startError != nil },
                set: { if !$0 { startError = nil } }
            ),
            presenting: startError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Import",
            isPresented: Binding(
                get: { importer.lastError != nil },
                set: { if !$0 { importer.lastError = nil } }
            ),
            presenting: importer.lastError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .onChange(of: recorder.activeMeeting, initial: true) { _, meeting in
            // Follow the meeting being recorded, so its page is the one on screen.
            // From the start as well: a window opened mid-meeting showed it without
            // selecting it, and lost it from view the moment it stopped.
            if let meeting { selection = [meeting] }
        }
        .onChange(of: recorder.state) { old, new in
            // A start that fails goes from preparing straight back to idle, with the
            // reason only in the recorder's error. On the page, that read as the
            // selected meeting's error, and with none selected it was not shown at all.
            if old == .preparing, new == .idle, let error = recorder.lastError {
                startError = error
                recorder.clearError()
            }
        }
        .onChange(of: selection) { _, _ in
            // The recorder's error belongs to the meeting it happened in. Once the user
            // picks another, it would only mislead there. A running meeting keeps its
            // error, since its live page and the pill still need it.
            if recorder.state == .idle {
                recorder.clearError()
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if selection.count > 1 {
            ContentUnavailableView {
                Label("\(selection.count) Meetings Selected", systemImage: "square.stack")
            } actions: {
                Button("Delete \(selection.count) Meetings\u{2026}", role: .destructive) {
                    pendingDeletion = deletable(Array(selection))
                }
                .disabled(deletable(Array(selection)).isEmpty)
            }
        } else if let meeting = selection.first {
            // A new view per meeting, so what it holds starts fresh with each one: the
            // player, which opens the recording as the page appears, and any export
            // failure in progress.
            MeetingPageView(meeting: meeting, find: searchText.trimmingCharacters(in: .whitespaces))
                .id(meeting.persistentModelID)
        } else if recorder.state == .preparing {
            // The new meeting joins the list only once it records, so this is what
            // says the click was heard. It said "No Meeting Selected" for the seconds
            // the speaker models take to load.
            ProgressView("Preparing…")
        } else {
            ContentUnavailableView {
                Label("No Meeting Selected", systemImage: "waveform")
            } description: {
                Text("Start a meeting, import a recording, or pick one from the list.")
            } actions: {
                if recorder.state == .idle {
                    Button("New Meeting") { startMeeting() }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.isBusy)
                }
            }
        }
    }

    // MARK: - List Bar

    /// New Meeting, Import and Delete, directly above the list they act on.
    ///
    /// In the column itself, not in the window's toolbar. The toolbar has room above
    /// the list for one titled button, and it moved the other two into an overflow
    /// menu at the far side of the window, which is the distance this bar exists to
    /// remove.
    private var listBar: some View {
        HStack(spacing: 6) {
            newMeetingButton

            Spacer(minLength: 0)

            Button {
                chooseRecordings()
            } label: {
                Label("Import Recording\u{2026}", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 20)
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Import a recording (⌘O), or drop one on the list")

            Button(role: .destructive) {
                pendingDeletion = deletable(Array(selection))
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 20)
            }
            .disabled(deletable(Array(selection)).isEmpty)
            .help(selection.count > 1 ? "Delete the selected meetings" : "Delete the selected meeting")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var newMeetingButton: some View {
        switch recorder.state {
        case .idle:
            Button {
                startMeeting()
            } label: {
                // A red record mark with its name beside it. As a bare gray circle it
                // was the window's main command and the hardest one to recognize.
                Label {
                    Text("New Meeting")
                } icon: {
                    Image(systemName: "record.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("n", modifiers: .command)
            // A dictation holds the same microphone. Without this the button looked
            // available, did nothing when clicked, and said nothing about why.
            .disabled(engine.isBusy)
            .help(recorder.microphoneHeldReason ?? "New Meeting (⌘N)")

        // Saving has its own mark. A red record button through it read as still
        // recording, while the page said "Saving…".
        case .preparing, .finishing:
            ProgressView().controlSize(.small)
                .help(recorder.state == .preparing ? "Preparing…" : "Saving…")

        case .recording, .paused:
            // The live page carries Pause and Stop; here it only says where to find it.
            Button {
                if let meeting = recorder.activeMeeting { selection = [meeting] }
            } label: {
                Label("Show Recording", systemImage: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .foregroundStyle(recorder.isPaused ? .orange : .red)
            .help("Show the meeting being recorded")
        }
    }

    private func startMeeting() {
        Task { await recorder.start(in: modelContext) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // Worked out once, since it searches every transcript, and both the list and
        // its overlay need it.
        let sections = self.sections
        let query = searchText.trimmingCharacters(in: .whitespaces)

        return List(selection: $selection) {
            // An import shows where its meeting will appear, and says what it is doing.
            if !importer.jobs.isEmpty {
                Section("Importing") {
                    ForEach(importer.jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.name)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(job.phase)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .selectionDisabled()
                    }
                }
            }

            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            showsTime: section.showsTime,
                            recordingState: meeting == recorder.activeMeeting ? recorder.state : nil,
                            // The sentence the search found, so a result says why it
                            // is one.
                            excerpt: query.isEmpty ? nil : meeting.excerpt(around: query)
                        )
                        .tag(meeting)
                        .contextMenu {
                            // The whole selection when the row is part of it, as in
                            // Finder; the row alone otherwise.
                            let targets = selection.contains(meeting) ? Array(selection) : [meeting]
                            Button(targets.count > 1 ? "Delete \(targets.count) Meetings\u{2026}" : "Delete\u{2026}", role: .destructive) {
                                pendingDeletion = deletable(targets)
                            }
                            .disabled(deletable(targets).isEmpty)
                        }
                    }
                }
            }
        }
        .overlay {
            if listedMeetings.isEmpty, importer.jobs.isEmpty {
                ContentUnavailableView("No Meetings", systemImage: "waveform",
                                       description: Text("Meetings you record or import appear here."))
            } else if sections.isEmpty, importer.jobs.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        // The Delete key, and Edit ▸ Delete.
        .onDeleteCommand {
            pendingDeletion = deletable(Array(selection))
        }
        // A recording dropped on the list is imported.
        .dropDestination(for: URL.self) { urls, _ in
            importRecordings(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    /// Every finished meeting, and the one being recorded.
    ///
    /// Not the one still starting. That meeting is saved from the first second in case
    /// of a crash, and a start that fails deletes it again. Listed, it could be selected
    /// or deleted while the recorder still held it, and one side was left reading a
    /// model the store had dropped.
    private var listedMeetings: [Meeting] {
        meetings.filter { $0.endedAt != nil || $0 == recorder.activeMeeting }
    }

    /// The meetings matching the search, grouped by when they happened, as Notes does.
    private var sections: [MeetingSection] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? listedMeetings : listedMeetings.filter {
            $0.title.localizedStandardContains(query) || $0.says(query)
        }
        return MeetingSection.group(matching)
    }

    // MARK: - Deleting

    /// The meeting being recorded, or saved after Stop, is the recorder's until it is
    /// finished.
    private func deletable(_ meetings: [Meeting]) -> [Meeting] {
        meetings.filter { $0 != recorder.activeMeeting }
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1
            ? "Delete \u{201C}\(pendingDeletion.first?.title ?? "")\u{201D}?"
            : "Delete \(pendingDeletion.count) meetings?"
    }

    private func delete(_ doomed: [Meeting]) {
        let doomed = deletable(doomed)
        guard !doomed.isEmpty else { return }

        // The meeting below the last one deleted takes its place, or the one above if
        // it was last, as in Notes and Mail. Left empty, the page needed another click
        // for every meeting deleted in a row.
        let listed = sections.flatMap(\.meetings)
        if let last = listed.lastIndex(where: { doomed.contains($0) }) {
            let next = listed[(last + 1)...].first { !doomed.contains($0) }
                ?? listed[..<last].last { !doomed.contains($0) }
            selection = next.map { [$0] } ?? []
        }

        for meeting in doomed {
            // The recording is not owned by SwiftData, so cascade delete does not
            // reach it.
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            modelContext.delete(meeting)
        }
        modelContext.saveOrLog()
    }

    // MARK: - Importing

    private func chooseRecordings() {
        guard let window = NSApp.keyWindow else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = "Import"

        // A sheet on the window, as opening is in any document app. Run modally, the
        // panel floated free of the window and blocked every other one in the app.
        Task {
            guard await panel.beginSheetModal(for: window) == .OK else { return }
            importRecordings(panel.urls)
        }
    }

    /// One after another, so two long files do not fight over the recognizer, and the
    /// last one imported is the one left selected.
    private func importRecordings(_ urls: [URL]) {
        Task {
            for url in urls {
                if let meeting = await importer.importRecording(at: url, settings: settings, in: modelContext) {
                    selection = [meeting]
                }
            }
        }
    }
}

// MARK: - Sections

/// One heading of the list: Today, Yesterday, Previous 7 Days, and so on.
private struct MeetingSection {
    let title: String
    let meetings: [Meeting]
    /// Today's and yesterday's rows show a time, since the heading already says the day.
    let showsTime: Bool

    /// Meetings arrive newest first, so each heading's rows stay in that order.
    static func group(_ meetings: [Meeting], now: Date = .now) -> [MeetingSection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var titles: [String] = []
        var buckets: [String: [Meeting]] = [:]

        for meeting in meetings {
            let day = calendar.startOfDay(for: meeting.startedAt)
            let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let title: String
            switch daysAgo {
            case ..<1: title = "Today"
            case 1: title = "Yesterday"
            case 2..<7: title = "Previous 7 Days"
            case 7..<30: title = "Previous 30 Days"
            default:
                title = meeting.startedAt.formatted(.dateTime.month(.wide).year())
            }
            if buckets[title] == nil { titles.append(title) }
            buckets[title, default: []].append(meeting)
        }

        return titles.map { title in
            MeetingSection(title: title, meetings: buckets[title] ?? [],
                           showsTime: title == "Today" || title == "Yesterday")
        }
    }
}

// MARK: - Row

private struct MeetingRow: View {
    let meeting: Meeting
    let showsTime: Bool
    /// The recorder's state on the row of the meeting it holds, nil on every other.
    let recordingState: MeetingRecorder.State?
    /// The sentence a search matched, when there is a search.
    let excerpt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                switch recordingState {
                case .recording:
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                case .paused:
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                case .finishing:
                    // Separating speakers and saving, which on a long meeting takes a
                    // while. The pulsing record mark read as still listening.
                    ProgressView().controlSize(.mini)
                default:
                    EmptyView()
                }
                Text(meeting.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            Text(facts)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let excerpt {
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    /// When it was, how long it ran, and who spoke, as one line: "13:20 · 4:39 ·
    /// Nora, Jonathan". The title no longer carries the date, so the row has to.
    private var facts: String {
        var parts = [showsTime
            ? meeting.startedAt.formatted(date: .omitted, time: .shortened)
            : meeting.startedAt.formatted(date: .abbreviated, time: .omitted)]
        if meeting.endedAt != nil {
            parts.append(MeetingExporter.durationLabel(meeting.duration))
        }
        if meeting.hasSpeakerAttribution {
            // Their names once every one of them has been given one. "Speaker 1,
            // Speaker 2" says less than "2 speakers".
            let speakers = meeting.sortedSpeakers
            let named = speakers.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            parts.append(named && speakers.count <= 3
                ? speakers.map(\.resolvedName).joined(separator: ", ")
                : speakers.count == 1 ? "1 speaker" : "\(speakers.count) speakers")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Searching

extension Meeting {
    /// Whether the words are in the meeting, as it reads now.
    ///
    /// The speakers' lines where it has them, since those are what a correction
    /// changes. The transcript kept without speakers is a second copy that a
    /// correction never reaches, and a search of it found words the user had fixed
    /// and missed the ones they had typed.
    func says(_ words: String) -> Bool {
        hasSpeakerAttribution
            ? utterances.contains { $0.text.localizedStandardContains(words) }
            : rawTranscript.localizedStandardContains(words)
    }

    /// The words around the first place the meeting says something, for a search
    /// result to show. Nil when only the title matched.
    func excerpt(around words: String) -> String? {
        let text = hasSpeakerAttribution
            ? orderedUtterances.first { $0.text.localizedStandardContains(words) }?.text
            : rawTranscript
        guard let text, let match = text.localizedStandardRange(of: words) else { return nil }

        let start = text.index(match.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { excerpt = "\u{2026}" + excerpt }
        if end < text.endIndex { excerpt += "\u{2026}" }
        return excerpt
    }
}

#endif
