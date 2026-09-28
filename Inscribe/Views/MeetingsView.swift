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

    /// Why the microphone is unavailable to a meeting, named by whoever holds it.
    private var microphoneHeldReason: String? {
        guard engine.isBusy else { return nil }
        switch engine.owner {
        case .dictation: return "Inscribe is dictating. Finish that first."
        case .shortcut: return "A shortcut is recording."
        case .meeting, nil: return nil
        }
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
            .help(microphoneHeldReason ?? "Start Meeting (⌘N)")

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
    /// Numbers eight apart share a color, so after merges Speaker 1 and Speaker 9 could
    /// be the only two left, both blue. Speakers therefore take their colors in label
    /// order, and a speaker whose color an earlier one holds takes the next free color.
    /// That moves a color only in a meeting whose speakers were numbered past eight.
    /// Once all eight colors are held, a speaker takes its own color again.
    func color(forSpeakerId id: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        var taken = Set<Int>()
        for speaker in sortedSpeakers {
            guard let number = speaker.generatedLabel.split(separator: " ").last.flatMap({ Int($0) }),
                  number >= 1
            else { continue }
            let preferred = (number - 1) % palette.count
            let slot = (0..<palette.count)
                .map { (preferred + $0) % palette.count }
                .first(where: { !taken.contains($0) }) ?? preferred
            if speaker.speakerId == id { return palette[slot] }
            taken.insert(slot)
        }
        return .secondary
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
    @State private var splitTarget: Utterance?
    @State private var player = MeetingPlayer()

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
                    .task { await player.load(fileName: meeting.audioFileName) }
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
        .sheet(item: $splitTarget) { utterance in
            SplitUtteranceSheet(meeting: meeting, utterance: utterance) { offset, speaker in
                _ = meeting.split(
                    utterance,
                    atCharacterOffset: offset,
                    assigningTailTo: speaker,
                    in: modelContext
                )
                finishCorrection()
                splitTarget = nil
            } onCancel: {
                splitTarget = nil
            }
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

    private var transcriptPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

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

                transcript
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Wrapped rather than cut off. A default title, "Meeting Sunday 28
            // September, 14:30", did not fit on one line at the window's default size.
            TextField("Title", text: $meeting.title, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
                .onSubmit { modelContext.saveOrLog() }

            Text(details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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

    @ViewBuilder
    private var transcript: some View {
        if meeting.hasSpeakerAttribution {
            // Whether the recording opened, not only whether its file exists, so a
            // recording that will not play never offers lines that do nothing.
            let hasAudio = player.loadedFileName != nil
            // Read once for every line. The player changes it only when playback
            // crosses into another utterance, so this view redraws then and not
            // on every tick of the clock.
            let playingID = player.playingUtteranceID
            let isPlaying = player.isPlaying
            // Sorted once for every line's menu, not once per line.
            let speakers = meeting.sortedSpeakers

            // Lazy, so a long meeting builds only the lines on screen.
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(meeting.orderedUtterances) { utterance in
                    let isPlayingLine = isPlaying && utterance.persistentModelID == playingID

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            speakerMenu(for: utterance, speakers: speakers)

                            // Hearing the moment is the only way to know whether an
                            // attribution is right, so the line plays it.
                            if hasAudio {
                                Button {
                                    togglePlayback(of: utterance)
                                } label: {
                                    Label(utterance.timestampLabel,
                                          systemImage: isPlayingLine ? "pause.fill" : "play.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption.monospacedDigit())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(isPlayingLine ? "Pause" : "Play from here")
                                // Named for what it does. VoiceOver otherwise read the
                                // timestamp alone.
                                .accessibilityLabel(isPlayingLine ? "Pause" : "Play from \(utterance.timestampLabel)")
                            } else {
                                Text(utterance.timestampLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Clicked rather than selectable: selection took the click, so
                        // the words could not play themselves. Export ▸ Copy Transcript
                        // still copies the text.
                        Text(utterance.text)
                            .font(.body)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if hasAudio { togglePlayback(of: utterance) }
                            }
                            .pointerStyle(hasAudio ? .link : nil)

                        // Only on the line being played, so its later sentences can be
                        // reached without playing through the start.
                        if hasAudio, utterance.persistentModelID == playingID {
                            LineScrubber(utterance: utterance, player: player)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(utterance.persistentModelID == playingID
                                  ? Color.accentColor.opacity(0.12) : .clear)
                    )
                    .padding(.horizontal, -10)
                }
            }
        } else if meeting.rawTranscript.isEmpty {
            Text("No transcript was captured.")
                .foregroundStyle(.secondary)
        } else {
            Text(meeting.rawTranscript)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }

    /// Play from a line, or pause it if it is the line playing.
    ///
    /// A line paused part way resumes where it stopped rather than from its start, so
    /// clicking the same words twice more carries on listening.
    private func togglePlayback(of utterance: Utterance) {
        if player.isPlaying, player.playingUtteranceID == utterance.persistentModelID {
            player.pause()
            return
        }
        // Opened as the page appeared. The lines offer playback only once it has.
        guard player.loadedFileName == meeting.audioFileName else { return }
        player.follow(meeting.orderedUtterances)
        if !player.isPlaying,
           player.currentTime > utterance.start, player.currentTime < utterance.end {
            player.play()
        } else {
            player.play(from: utterance)
        }
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

    /// Reassign, or cut an utterance that holds two people.
    private func speakerMenu(for utterance: Utterance, speakers: [MeetingSpeaker]) -> some View {
        Menu {
            Section("Attribute to") {
                ForEach(speakers) { speaker in
                    Button {
                        meeting.reassign(utterance, to: speaker)
                        finishCorrection()
                    } label: {
                        if speaker.speakerId == utterance.speakerId {
                            Label(speaker.resolvedName, systemImage: "checkmark")
                        } else {
                            Text(speaker.resolvedName)
                        }
                    }
                }
            }

            Divider()

            Button("Attribute to a New Speaker") {
                let speaker = meeting.addSpeaker(in: modelContext)
                meeting.reassign(utterance, to: speaker)
                finishCorrection()
            }

            if !UtteranceSplitPoint.candidates(in: utterance.text).isEmpty {
                Button("Split This Line…") {
                    splitTarget = utterance
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(meeting.color(forSpeakerId: utterance.speakerId))
                    .frame(width: 8, height: 8)
                Text(meeting.displayName(forSpeakerId: utterance.speakerId))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(meeting.color(forSpeakerId: utterance.speakerId))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change who said this")
    }

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

// MARK: - Line Scrubber

/// Scrub within the line being played.
///
/// A view of its own because it reads the playback time, which changes four times a
/// second. Read in the detail view's body, that time redrew the whole transcript
/// with it.
private struct LineScrubber: View {
    let utterance: Utterance
    let player: MeetingPlayer

    var body: some View {
        // A hundredth of a second short of the line's end. The moment the line ends is
        // where the next one starts, so a drag to the far right moved the highlight on
        // and took away the slider under the pointer.
        let upper = max(utterance.start, utterance.end - 0.01)

        HStack(spacing: 10) {
            Text(MeetingExporter.durationLabel(player.currentTime))
                .frame(minWidth: 36, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(max(player.currentTime, utterance.start), upper) },
                    set: { player.seek(to: $0) }
                ),
                in: utterance.start...upper
            )
            .controlSize(.mini)
            .accessibilityLabel("Playback position")

            Text(MeetingExporter.durationLabel(utterance.end))
                .frame(minWidth: 36, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
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
                VStack(alignment: .leading, spacing: 12) {
                    let live = recorder.liveTranscript
                    Text(live.isEmpty ? "Listening…" : Self.tail(of: live))
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .foregroundStyle(live.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

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

    /// Why the microphone is unavailable to a meeting, named by whoever holds it.
    private var microphoneHeldReason: String? {
        guard engine.isBusy else { return nil }
        switch engine.owner {
        case .dictation: return "Inscribe is dictating. Finish that first."
        case .shortcut: return "A shortcut is recording."
        case .meeting, nil: return nil
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
                .help(recorder.isPaused ? (microphoneHeldReason ?? "") : "")

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

    /// The end of a live transcript: its last few hundred words, marked as cut.
    ///
    /// The live text changes several times a second, and each change laid out the
    /// whole meeting again, which on a long meeting kept the main thread busy for as
    /// long as it ran. The end is what anyone reads while it grows; the whole of it is
    /// in the meeting once it stops.
    private static func tail(of text: String, words: Int = 300) -> String {
        var index = text.endIndex
        var spaces = 0

        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == " " {
                spaces += 1
                if spaces == words {
                    return "…" + text[index...]
                }
            }
            index = previous
        }
        return text
    }
}

#endif

// MARK: - Split Sheet

#if os(macOS)
/// Cut one block of text into two speakers.
///
/// Offers sentence boundaries rather than a free cursor: a missed handover almost
/// always falls at the end of a sentence, and picking from a short list is faster
/// than placing a caret in a wall of text.
private struct SplitUtteranceSheet: View {
    let meeting: Meeting
    let utterance: Utterance
    let onSplit: (Int, MeetingSpeaker?) -> Void
    let onCancel: () -> Void

    @State private var selectedOffset: Int?
    @State private var tailSpeaker: MeetingSpeaker?

    private var candidates: [(offset: Int, preview: String)] {
        UtteranceSplitPoint.candidates(in: utterance.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Split This Line")
                .font(.headline)

            Text("Currently all attributed to \(meeting.displayName(forSpeakerId: utterance.speakerId)). Choose where the next speaker starts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Picker("Next speaker starts at", selection: $selectedOffset) {
                    ForEach(candidates, id: \.offset) { candidate in
                        Text("…\(candidate.preview)")
                            .tag(candidate.offset as Int?)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            // Not the line's own speaker. The second half would join straight back
            // onto the first, and the split would change nothing.
            Picker("Second half is", selection: $tailSpeaker) {
                Text("A new speaker").tag(nil as MeetingSpeaker?)
                ForEach(meeting.sortedSpeakers.filter { $0.speakerId != utterance.speakerId }) { speaker in
                    Text(speaker.resolvedName).tag(speaker as MeetingSpeaker?)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Split") {
                    guard let selectedOffset else { return }
                    onSplit(selectedOffset, tailSpeaker)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedOffset == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
#endif
