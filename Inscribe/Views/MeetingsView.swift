import SwiftUI
import os
import SwiftData

#if os(macOS)
import AppKit

/// Browse recorded meetings, read them by speaker, rename speakers, and export.
///
/// Laid out as Voice Memos and Notes are: the list on the left, the transcript as the
/// page, and the summary and speakers in an inspector on the right. The old single
/// page stacked speakers, player and summary above the transcript, so the words
/// started a screen down, and deleting a meeting needed a right-click.
struct MeetingsView: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(TranscriptionEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]

    @State private var selection: Meeting?
    @State private var searchText = ""
    /// The meeting waiting on the delete confirmation.
    @State private var pendingDeletion: Meeting?
    /// Why the last start failed, until the user dismisses it.
    @State private var startError: String?

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

                sidebar
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let meeting = selection {
                // A new view per meeting, so what it holds starts fresh with each one:
                // the player, which opens the recording as the page appears, and any
                // export failure or split in progress.
                MeetingDetailView(meeting: meeting) {
                    pendingDeletion = meeting
                }
                .id(meeting.persistentModelID)
            } else if recorder.state == .preparing {
                // The new meeting joins the list only once it records, so this is what
                // says the click was heard. It said "No Meeting Selected" for the
                // seconds the speaker models take to load.
                ProgressView("Preparing…")
            } else {
                ContentUnavailableView {
                    Label("No Meeting Selected", systemImage: "waveform")
                } description: {
                    Text("Start a meeting, or pick one from the list.")
                } actions: {
                    if recorder.state == .idle {
                        Button("Start Meeting") {
                            Task { await recorder.start(in: modelContext) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.isBusy)
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                recordButton
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDeletion?.title ?? "")\u{201D}?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { meeting in
            Button("Delete", role: .destructive) { delete(meeting) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its transcript, summary and recording will be deleted. This can\u{2019}t be undone.")
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
        .onChange(of: recorder.activeMeeting, initial: true) { _, meeting in
            // Follow the meeting being recorded, so the live transcript is on screen.
            // From the start as well: a window opened mid-meeting showed it without
            // selecting it, and lost it from view the moment it stopped.
            if let meeting { selection = meeting }
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
            // error, since its live section and panel still need it.
            if recorder.state == .idle {
                recorder.clearError()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // Worked out once, since it searches every transcript, and both the list and
        // its overlay need it.
        let sections = self.sections

        return List(selection: $selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            showsTime: section.showsTime,
                            recordingState: meeting == recorder.activeMeeting ? recorder.state : nil
                        )
                        .tag(meeting)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeletion = meeting
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(!canDelete(meeting))
                        }
                        .contextMenu {
                            Button("Delete\u{2026}", role: .destructive) {
                                pendingDeletion = meeting
                            }
                            .disabled(!canDelete(meeting))
                        }
                    }
                }
            }
        }
        .overlay {
            if listedMeetings.isEmpty {
                ContentUnavailableView("No Meetings", systemImage: "waveform",
                                       description: Text("Meetings you record appear here."))
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
        // The Delete key, and Edit ▸ Delete.
        .onDeleteCommand {
            if let selection, canDelete(selection) { pendingDeletion = selection }
        }
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
            $0.title.localizedStandardContains(query)
                || $0.rawTranscript.localizedStandardContains(query)
        }
        return MeetingSection.group(matching)
    }

    /// The meeting being recorded, or saved after Stop, is the recorder's until it is
    /// finished.
    private func canDelete(_ meeting: Meeting) -> Bool {
        meeting != recorder.activeMeeting
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recorder.state {
        case .idle:
            Button {
                Task { await recorder.start(in: modelContext) }
            } label: {
                Label("Start Meeting", systemImage: "record.circle")
            }
            .keyboardShortcut("n", modifiers: .command)
            // A dictation holds the same microphone. Without this the button looked
            // available, did nothing when clicked, and said nothing about why.
            .disabled(engine.isBusy)
            .help(recorder.microphoneHeldReason ?? "Start Meeting (⌘N)")

        // Saving has its own mark. A red record button through it read as still
        // recording, while the page said "Saving…".
        case .preparing, .finishing:
            ProgressView().controlSize(.small)
                .help(recorder.state == .preparing ? "Preparing…" : "Saving…")

        case .recording, .paused:
            // The live page carries Pause and Stop; here it only says where to find it.
            Button {
                selection = recorder.activeMeeting
            } label: {
                Label("Show Recording", systemImage: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
            }
            .foregroundStyle(recorder.isPaused ? .orange : .red)
            .help("Show the meeting being recorded")
        }
    }

    private func delete(_ meeting: Meeting) {
        guard canDelete(meeting) else { return }
        // The meeting below takes its place, or the one above if it was last, as in
        // Notes and Mail. Left empty, the page needed another click for every meeting
        // deleted in a row.
        if selection == meeting {
            let listed = sections.flatMap(\.meetings)
            selection = listed.firstIndex(of: meeting).flatMap { index in
                index + 1 < listed.count ? listed[index + 1] : listed[..<index].last
            }
        }
        // The recording is not owned by SwiftData, so cascade delete does not reach it.
        MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
        modelContext.delete(meeting)
        modelContext.saveOrLog()
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

            HStack(spacing: 6) {
                Text(showsTime
                     ? meeting.startedAt.formatted(date: .omitted, time: .shortened)
                     : meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                if meeting.endedAt != nil {
                    Text(MeetingExporter.durationLabel(meeting.duration))
                }
                if meeting.hasSpeakerAttribution {
                    Label("\(meeting.speakers.count)", systemImage: "person.2")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Speaker colors

private extension Meeting {
    /// A color per speaker, the same in the transcript and the inspector.
    ///
    /// Taken from the number in the speaker's label, the third color for "Speaker 3",
    /// rather than from the speaker's place in the list. By place, merging Speaker 2
    /// away moved Speaker 3 up one and recolored every line of theirs. A label with no
    /// number, "Unattributed", is gray.
    ///
    /// Numbers eight apart share a color, so Speaker 1 and Speaker 9 are both blue.
    /// A color that follows the speaker's own number stays put through every merge,
    /// which matters more than keeping two survivors distinct.
    func color(forSpeakerId id: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        guard let label = speakers.first(where: { $0.speakerId == id })?.generatedLabel,
              let number = label.split(separator: " ").last.flatMap({ Int($0) }),
              number >= 1
        else { return .secondary }
        return palette[(number - 1) % palette.count]
    }
}

// MARK: - Detail

private struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    let onDelete: () -> Void

    @Environment(MeetingRecorder.self) private var recorder
    @Environment(\.modelContext) private var modelContext

    @AppStorage("meetingInspectorShown") private var showsInspector = true
    @State private var exportError: String?
    @State private var player = MeetingPlayer()
    /// When each word of the recording was said, for a meeting recorded since those
    /// were kept. Nil for an older one.
    @State private var wordTimings: MeetingWordTimings?

    private var isLive: Bool { meeting == recorder.activeMeeting && recorder.hasActiveMeeting }

    // Kept by the recorder, which runs the summary. This view is rebuilt for every
    // meeting selected, and kept here, a summary still running when the user came back
    // looked finished, and Summarize started a second one alongside it.
    private var isSummarizing: Bool { recorder.summarizing.contains(meeting.persistentModelID) }
    private var summaryError: String? { recorder.summaryErrors[meeting.persistentModelID] }

    var body: some View {
        Group {
            if isLive {
                LiveMeetingView(meeting: meeting)
            } else {
                transcriptPage
                    // Opened with the page rather than at the first click, so a
                    // recording that will not open says so before any line is clicked.
                    // Not while live, when the file is still being written.
                    .task {
                        await player.load(fileName: meeting.audioFileName)
                        wordTimings = MeetingWordTimings.load(forRecording: meeting.audioFileName)
                        // Given once the recording is open, so a click on a word marks
                        // its line before play has ever been pressed.
                        player.follow(meeting.orderedUtterances)
                    }
                    .inspector(isPresented: $showsInspector) {
                        inspector
                            .inspectorColumnWidth(min: 240, ideal: 290, max: 400)
                    }
            }
        }
        .onDisappear { player.unload() }
        .alert(
            "Couldn\u{2019}t Export Meeting",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            presenting: exportError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .toolbar {
            if !isLive {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        ForEach(MeetingExporter.Format.allCases) { format in
                            Button("Save as \(format.displayName)…") { save(as: format) }
                        }
                        Divider()
                        Button("Copy Transcript") {
                            ClipboardService.copy(MeetingExporter.plainText(meeting))
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Export or copy the transcript")

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete this meeting")
                }

                // Kept apart from Export and Delete, which act on the meeting. In their
                // group, the panel toggle shared their capsule and sat beside Delete.
                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help(showsInspector ? "Hide summary and speakers" : "Show summary and speakers")
                }
            }
        }
    }

    // MARK: Transcript page

    /// The page for a finished meeting: its header, then the transcript, scrolling as
    /// one, with the playback bar along the bottom when there is a recording.
    @ViewBuilder
    private var transcriptPage: some View {
        if meeting.hasSpeakerAttribution {
            TranscriptView(
                lines: transcriptLines,
                speakers: meeting.sortedSpeakers.map { TranscriptSpeaker(id: $0.speakerId, name: $0.resolvedName) },
                playingID: player.playingUtteranceID.map { AnyHashable($0) },
                isPlaying: player.isPlaying,
                // Whether the recording opened, not only whether its file exists, so
                // a recording that will not play never offers a playhead to move.
                canPlay: player.loadedFileName != nil,
                playhead: { player.playhead },
                actions: transcriptActions
            ) {
                MeetingPageHeader(meeting: meeting, recorder: recorder, player: player)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.loadedFileName != nil {
                    PlaybackBar(player: player)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MeetingPageHeader(meeting: meeting, recorder: recorder, player: player)

                    Group {
                        if meeting.rawTranscript.isEmpty {
                            Text("No transcript was captured.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(meeting.rawTranscript)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    /// The meeting's lines as the transcript view takes them.
    private var transcriptLines: [TranscriptLine] {
        meeting.orderedUtterances.map { utterance in
            TranscriptLine(
                id: AnyHashable(utterance.persistentModelID),
                speakerId: utterance.speakerId,
                speakerName: meeting.displayName(forSpeakerId: utterance.speakerId),
                color: NSColor(meeting.color(forSpeakerId: utterance.speakerId)),
                timestamp: utterance.timestampLabel,
                text: utterance.text,
                start: utterance.start,
                end: utterance.end,
                wordTimes: wordTimings?.times(
                    forWordsOf: utterance.text,
                    spokenFrom: utterance.start,
                    to: utterance.end
                )
            )
        }
    }

    /// What a click or a menu choice in the transcript does to the meeting.
    private var transcriptActions: TranscriptActions {
        TranscriptActions(
            seek: { time in
                player.seek(to: time)
            },
            reassign: { line, speakerId in
                guard let utterance = utterance(line),
                      let speaker = meeting.speakers.first(where: { $0.speakerId == speakerId }) else { return }
                meeting.reassign(utterance, to: speaker)
                finishCorrection()
            },
            reassignToNewSpeaker: { line in
                guard let utterance = utterance(line) else { return }
                meeting.reassign(utterance, to: meeting.addSpeaker(in: modelContext))
                finishCorrection()
            },
            split: { line, offset, speakerId in
                guard let utterance = utterance(line) else { return }
                // The text view counts in UTF-16 units and the cut is made in
                // characters. They differ as soon as a line holds an emoji.
                let text = utterance.text
                let characters = text.distance(
                    from: text.startIndex,
                    to: String.Index(utf16Offset: min(offset, text.utf16.count), in: text)
                )
                _ = meeting.split(
                    utterance,
                    atCharacterOffset: characters,
                    assigningTailTo: speakerId.flatMap { id in meeting.speakers.first { $0.speakerId == id } },
                    in: modelContext
                )
                finishCorrection()
            }
        )
    }

    private func utterance(_ line: AnyHashable) -> Utterance? {
        meeting.utterances.first { AnyHashable($0.persistentModelID) == line }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Only with words to summarize. On a meeting that captured none,
                // Summarize span for a moment and then did nothing.
                if meeting.summary != nil || meeting.hasSpeakerAttribution || !meeting.rawTranscript.isEmpty {
                    summarySection
                }
                speakerSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary")
                    .font(.headline)
                Spacer()
                if meeting.summary != nil {
                    Button {
                        summarize()
                    } label: {
                        Label("Regenerate Summary", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSummarizing)
                    .help("Regenerate the summary")
                }
            }

            // Above the summary rather than instead of it: a failed Regenerate leaves
            // the previous summary on screen, and the failure has to be visible there.
            if let summaryError {
                Text(summaryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isSummarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } else if let summary = meeting.summary, !summary.isEmpty {
                // Read as Markdown for the bold the model writes, which a plain string
                // showed as asterisks. Its line breaks and "- " bullets stay as written.
                Text((try? AttributedString(
                    markdown: summary,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(summary))
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                Text("A summary is written on this Mac, in parts if the meeting is long.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Summarize") { summarize() }
                    .controlSize(.regular)
            }
        }
    }

    @ViewBuilder
    private var speakerSection: some View {
        if meeting.hasSpeakerAttribution {
            let speakers = meeting.sortedSpeakers

            // Speakers are added from a line's menu, together with the line. One added
            // here, with no lines yet, was deleted by the next correction along with
            // the name typed into it.
            VStack(alignment: .leading, spacing: 10) {
                Text("Speakers")
                    .font(.headline)

                ForEach(speakers) { speaker in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(meeting.color(forSpeakerId: speaker.speakerId))
                            .frame(width: 10, height: 10)

                        TextField(speaker.generatedLabel, text: Binding(
                            get: { speaker.name },
                            set: { speaker.name = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { modelContext.saveOrLog() }

                        Text("\(utteranceCount(for: speaker))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Lines attributed to this speaker")

                        // For when the diarizer split one person into two.
                        Menu {
                            ForEach(speakers.filter { $0.speakerId != speaker.speakerId }) { other in
                                Button("Merge into \(other.resolvedName)") {
                                    meeting.merge(speaker, into: other, in: modelContext)
                                    finishCorrection()
                                }
                            }
                        } label: {
                            Label("Merge Speaker", systemImage: "ellipsis.circle")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(meeting.speakers.count < 2)
                        .help("Merge with another speaker")
                    }
                }

                Text("Click a speaker\u{2019}s name in the transcript to change who said that line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if meeting.endedAt != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers")
                    .font(.headline)
                Text("This meeting was not separated by speaker.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func utteranceCount(for speaker: MeetingSpeaker) -> Int {
        meeting.utterances.count { $0.speakerId == speaker.speakerId }
    }

    // MARK: Corrections

    /// Join lines the correction left side by side, drop any speaker left with
    /// nothing attributed to them, save, and give the player the new lines.
    private func finishCorrection() {
        meeting.joinNeighbours(in: modelContext)
        meeting.pruneEmptySpeakers(in: modelContext)
        modelContext.saveOrLog()
        // After the save, so a split's new line is followed under its lasting ID. The
        // player held the lines from the last press of play, so a correction during
        // playback left it marking a line that had been joined away.
        player.follow(meeting.orderedUtterances)
    }

    // MARK: Actions

    private func summarize() {
        Task { await recorder.summarize(meeting, in: modelContext) }
    }

    private func save(as format: MeetingExporter.Format) {
        // The Meetings window, whose toolbar the format was chosen from.
        guard let window = NSApp.keyWindow else { return }

        let panel = NSSavePanel()
        // Colons replaced. Every default title carries a time, "14:30", and Finder
        // shows a colon in a file name as a slash.
        let name = meeting.title.replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        panel.canCreateDirectories = true

        // A sheet on the window, as saving is in any document app. Run modally, the
        // panel floated free of the window and blocked every other one in the app.
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }

            do {
                try MeetingExporter.export(meeting, as: format).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // Said on screen. Only logged, a failed export looked like a successful one.
                Log.meetings.error("Export failed: \(error, privacy: .public)")
                exportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Page Header

/// The top of a finished meeting's page: its title, when it was, and anything that
/// went wrong with it.
///
/// A view of its own, handed what it reads, because it is drawn inside the
/// transcript's scrolling page, which is AppKit's and carries no SwiftUI environment
/// across. Reading the meeting, the recorder and the player in its own body is what
/// makes it redraw when one of them changes.
private struct MeetingPageHeader: View {
    @Bindable var meeting: Meeting
    let recorder: MeetingRecorder
    let player: MeetingPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                // Wrapped rather than cut off, so a long title is read whole.
                TextField("Title", text: $meeting.title, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .onSubmit { meeting.modelContext?.saveOrLog() }

                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Shown whether or not the meeting has speakers. Hidden once there
            // were utterances, it kept quiet about a recognizer failure or a
            // recording that could not be saved in any meeting that had any.
            if let error = recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            // A recording that will not open used to leave lines that did nothing
            // when clicked, with the reason only in the log.
            if let error = player.lastError {
                Label("The recording could not be opened: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    /// When the meeting was, how long it ran and what was kept, as one line.
    ///
    /// One string rather than a row of pieces: in a narrow window each piece wrapped on
    /// its own, into ragged columns.
    private var details: String {
        var parts = [meeting.startedAt.formatted(date: .long, time: .shortened)]
        if meeting.endedAt != nil {
            parts.append(MeetingExporter.durationLabel(meeting.duration))
        }
        if meeting.wasPaused {
            parts.append("\(MeetingExporter.durationLabel(meeting.recordedDuration)) recorded")
        }
        if !meeting.hasAudio && meeting.endedAt != nil {
            parts.append("no recording kept")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Playback Bar

/// Play, the time, and a slider over the whole recording.
///
/// Playback used to exist only line by line: a click on a line played it, and a
/// scrubber appeared under that line alone. There was no way to play a meeting
/// through or to reach a moment without first playing its line.
///
/// A view of its own because it reads the playback time, which changes four times a
/// second. Read in the page's body, that time redrew the whole transcript with it.
private struct PlaybackBar: View {
    let player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            // ⌘Return, not Space: the transcript is text, and Space belongs to text.
            Button {
                player.togglePlayback()
            } label: {
                Label(player.isPlaying ? "Pause" : "Play",
                      systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 22, height: 22)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help(player.isPlaying ? "Pause (⌘↩)" : "Play from the playhead (⌘↩)")

            Text(MeetingExporter.durationLabel(player.currentTime))
                .frame(minWidth: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )
            .controlSize(.small)
            .accessibilityLabel("Playback position")

            Text(MeetingExporter.durationLabel(player.duration))
                .frame(minWidth: 40, alignment: .leading)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Live Meeting

/// The page while a meeting records: the clock, Pause and Stop, and the words so far.
private struct LiveMeetingView: View {
    @Bindable var meeting: Meeting

    @Environment(MeetingRecorder.self) private var recorder
    @Environment(TranscriptionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                // Lazy, and in paragraphs: only those on screen are laid out, and only the
                // last one changes as words arrive. As one Text, the whole meeting was laid
                // out again several times a second.
                LazyVStack(alignment: .leading, spacing: 12) {
                    let live = recorder.liveTranscript
                    if live.isEmpty {
                        Text("Listening…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(Self.paragraphs(of: live).enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Only when there is a diarizer to do it. Without one, the page
                    // promised separation below the error saying there would be none.
                    if recorder.diarizationActive {
                        Text("Speakers are separated once the meeting ends: telling voices apart reliably needs the whole recording.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            // Pinned to the newest words, which is where anyone looks while it grows.
            .defaultScrollAnchor(.bottom)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            TextField("Title", text: $meeting.title)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .onSubmit { modelContext.saveOrLog() }
                .frame(maxWidth: 480)

            status

            // Recomputed each second: the recorder's clock is derived, not observed.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(MeetingExporter.durationLabel(recorder.recordedSeconds))
                    .font(.system(size: 48, weight: .light).monospacedDigit())
                    .foregroundStyle(recorder.isPaused ? .secondary : .primary)
            }

            buttons

            // Errors during a meeting used to be set and never shown: a diarizer that
            // would not load, system audio that would not start, a recognizer that
            // failed part way.
            if let error = recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            // Only while capturing. Teardown clears the flag during the save, and the
            // note would flash up at the very end of every meeting.
            if settings.captureSystemAudioInMeetings, !recorder.systemAudioActive,
               recorder.state == .recording || recorder.state == .paused {
                Label("Microphone only. System audio is not being recorded, so other people on a call are not transcribed.",
                      systemImage: "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var status: some View {
        switch recorder.state {
        case .finishing:
            // Separating speakers and saving takes a while on a long meeting, and
            // a pulsing "Recording" through all of it read as still listening.
            Label {
                Text("Saving…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        default:
            Label("Recording", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if recorder.state == .recording || recorder.state == .paused {
            HStack(spacing: 12) {
                Button {
                    Task { recorder.isPaused ? await recorder.resume() : await recorder.pause() }
                } label: {
                    Label(recorder.isPaused ? "Resume" : "Pause",
                          systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 90)
                }
                // A dictation taken during the pause holds the microphone, and a resume
                // then fails and leaves the meeting paused.
                .disabled(recorder.isPaused && engine.isBusy)
                .help(recorder.isPaused ? (recorder.microphoneHeldReason ?? "") : "")

                Button {
                    Task { await recorder.stop(in: modelContext) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(minWidth: 90)
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Stop and save the meeting (⌘↩)")
            }
            .controlSize(.large)
        }
    }

    /// The live text in paragraphs, each closed at the first sentence end after 60
    /// words. The boundaries depend only on the text before them, so earlier paragraphs
    /// stay the same as the meeting grows.
    private static func paragraphs(of text: String) -> [String] {
        var paragraphs: [String] = []
        var words: [Substring] = []
        for word in text.split(separator: " ") {
            words.append(word)
            if words.count >= 60, let last = word.last, ".?!".contains(last) {
                paragraphs.append(words.joined(separator: " "))
                words = []
            }
        }
        if !words.isEmpty { paragraphs.append(words.joined(separator: " ")) }
        return paragraphs
    }
}

#endif
