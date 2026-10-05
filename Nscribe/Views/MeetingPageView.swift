import SwiftUI
import os
import SwiftData

#if os(macOS)
import AppKit

// MARK: - Speaker colors

extension Meeting {
    /// A color per speaker, the same wherever the speaker is shown.
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

// MARK: - Page

/// One meeting's page: live while it records, and the finished page afterwards.
///
/// The finished page reads top to bottom: title, speakers, summary, transcript, with
/// playback along the bottom. The summary and the speakers used to sit in a column of
/// their own at the right, in small type, a window's width from the list.
struct MeetingPageView: View {
    @Bindable var meeting: Meeting
    /// What the list is searching for, so the page opens on the place it was found.
    let find: String

    @Environment(MeetingRecorder.self) private var recorder
    @Environment(\.modelContext) private var modelContext

    @State private var exportError: String?
    @State private var player = MeetingPlayer()
    /// When each word of the recording was said, for a meeting recorded since those
    /// were kept. Nil for an older one.
    @State private var wordTimings: MeetingWordTimings?
    /// The save waiting for a pause in typing.
    @State private var pendingSave: Task<Void, Never>?
    @State private var justCopied = false

    private var isLive: Bool { meeting == recorder.activeMeeting && recorder.hasActiveMeeting }

    var body: some View {
        Group {
            if isLive {
                LiveMeetingView(meeting: meeting)
            } else {
                transcriptPage
                    // Opened with the page rather than at the first click, so a
                    // recording that will not open says so before any word is clicked.
                    // Not while live, when the file is still being written.
                    .task {
                        await player.load(fileName: meeting.audioFileName)
                        wordTimings = MeetingWordTimings.load(forRecording: meeting.audioFileName)
                        // Given once the recording is open, so a click on a word marks
                        // its line before play has ever been pressed.
                        player.follow(meeting.orderedUtterances)
                    }
            }
        }
        .onDisappear {
            player.unload()
            // A correction typed in the last half second has not been written yet.
            pendingSave?.cancel()
            modelContext.saveOrLog()
        }
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
                    // One click, since it is what a transcript is most often wanted
                    // for. It was two, inside the Export menu, and as plain text.
                    Button {
                        ClipboardService.copy(MeetingExporter.markdown(meeting))
                        justCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            justCopied = false
                        }
                    } label: {
                        // The symbol says it was copied; the title stays, so the
                        // button keeps its width and the Export button beside it
                        // keeps its place.
                        Label("Copy as Markdown", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Copy the title, summary and transcript as Markdown")

                    Menu {
                        ForEach(MeetingExporter.Format.allCases) { format in
                            Button("Save as \(format.displayName)…") { save(as: format) }
                        }
                        Divider()
                        Button("Copy as Plain Text") {
                            ClipboardService.copy(MeetingExporter.plainText(meeting))
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .help("Save the meeting to a file")
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
                find: find,
                playhead: { player.playhead },
                actions: transcriptActions
            ) {
                MeetingPageHeader(meeting: meeting, recorder: recorder, player: player, afterCorrection: finishCorrection)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.loadedFileName != nil {
                    PlaybackBar(player: player, stretches: stretches)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MeetingPageHeader(meeting: meeting, recorder: recorder, player: player, afterCorrection: finishCorrection)

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

    /// Who spoke when, for the strip in the playback bar.
    private var stretches: [SpeakerStretch] {
        meeting.orderedUtterances.map {
            SpeakerStretch(start: $0.start, end: $0.end, color: meeting.color(forSpeakerId: $0.speakerId))
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
            },
            correct: { line, words in
                guard let utterance = utterance(line) else { return }
                utterance.text = words
                saveSoon()
            }
        )
    }

    /// Save once the typing has paused. A correction arrives a keystroke at a time,
    /// and a write to disk for each is waste.
    private func saveSoon() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            modelContext.saveOrLog()
        }
    }

    private func utterance(_ line: AnyHashable) -> Utterance? {
        meeting.utterances.first { AnyHashable($0.persistentModelID) == line }
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

    private func save(as format: MeetingExporter.Format) {
        // The Meetings window, whose toolbar the format was chosen from.
        guard let window = NSApp.keyWindow else { return }

        let panel = NSSavePanel()
        // Colons replaced: Finder shows a colon in a file name as a slash.
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

/// The top of a finished meeting's page: its title, when it was, who spoke, anything
/// that went wrong, and the summary.
///
/// A view of its own, handed what it reads, because it is drawn inside the
/// transcript's scrolling page, which is AppKit's and carries no SwiftUI environment
/// across. Reading the meeting, the recorder and the player in its own body is what
/// makes it redraw when one of them changes.
private struct MeetingPageHeader: View {
    @Bindable var meeting: Meeting
    let recorder: MeetingRecorder
    let player: MeetingPlayer
    /// Run after a speaker is merged away, to tidy the lines and tell the player.
    let afterCorrection: () -> Void

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

            if meeting.hasSpeakerAttribution {
                SpeakerChips(meeting: meeting, afterCorrection: afterCorrection)
            }

            // Shown whether or not the meeting has speakers. Hidden once there
            // were utterances, it kept quiet about a recognizer failure or a
            // recording that could not be saved in any meeting that had any.
            if let error = recorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            // A recording that will not open used to leave words that did nothing
            // when clicked, with the reason only in the log.
            if let error = player.lastError {
                Label("The recording could not be opened: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            // Only with words to summarize. On a meeting that captured none,
            // Summarize spun for a moment and then did nothing.
            if meeting.summary != nil || meeting.hasSpeakerAttribution || !meeting.rawTranscript.isEmpty {
                SummaryBlock(meeting: meeting, recorder: recorder)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 20)
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
        if !meeting.hasSpeakerAttribution && meeting.endedAt != nil {
            parts.append("not separated by speaker")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Speakers

/// The meeting's speakers, each a chip that opens to rename or merge them.
///
/// Named here, at the top of the page their names run down, where they used to be
/// renamed in a column at the far side of the window. Speakers are added from a
/// line's menu, together with the line: one added here, with no lines yet, was
/// deleted by the next correction along with the name typed into it.
private struct SpeakerChips: View {
    let meeting: Meeting
    let afterCorrection: () -> Void

    @State private var editing: MeetingSpeaker?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(meeting.sortedSpeakers) { speaker in
                Button {
                    editing = speaker
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(meeting.color(forSpeakerId: speaker.speakerId))
                            .frame(width: 8, height: 8)
                        Text(speaker.resolvedName)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Rename or merge this speaker")
                .popover(isPresented: Binding(
                    get: { editing?.persistentModelID == speaker.persistentModelID },
                    set: { if !$0 { editing = nil } }
                ), arrowEdge: .bottom) {
                    SpeakerEditor(meeting: meeting, speaker: speaker) {
                        editing = nil
                        afterCorrection()
                    }
                }
            }
        }
    }
}

/// Rename one speaker, or merge them into another.
private struct SpeakerEditor: View {
    let meeting: Meeting
    @Bindable var speaker: MeetingSpeaker
    /// Run once the speaker has been merged away, which closes this.
    let afterMerge: () -> Void

    var body: some View {
        let others = meeting.sortedSpeakers.filter { $0.speakerId != speaker.speakerId }
        let lines = meeting.utterances.count { $0.speakerId == speaker.speakerId }

        VStack(alignment: .leading, spacing: 12) {
            TextField(speaker.generatedLabel, text: $speaker.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { meeting.modelContext?.saveOrLog() }

            Text(lines == 1 ? "1 line in this meeting" : "\(lines) lines in this meeting")
                .font(.caption)
                .foregroundStyle(.secondary)

            // For when one person was taken for two.
            if !others.isEmpty, let context = meeting.modelContext {
                Menu("Merge Into") {
                    ForEach(others) { other in
                        Button(other.resolvedName) {
                            meeting.merge(speaker, into: other, in: context)
                            afterMerge()
                        }
                    }
                }
                .fixedSize()
            }
        }
        .padding(14)
        .onDisappear { meeting.modelContext?.saveOrLog() }
    }
}

// MARK: - Summary

/// The summary at the top of the page, folded to its first three points.
///
/// Folded so the transcript still starts near the top of the window. The whole
/// summary is one click away, and it is the first thing on the page because it is
/// the first thing wanted once a meeting is over.
private struct SummaryBlock: View {
    let meeting: Meeting
    let recorder: MeetingRecorder

    @State private var showsAll = false

    private static let foldedCount = 3

    // Kept by the recorder, which runs the summary. This view is rebuilt for every
    // meeting selected, and kept here, a summary still running when the user came back
    // looked finished, and Summarize started a second one alongside it.
    private var isSummarizing: Bool { recorder.summarizing.contains(meeting.persistentModelID) }
    private var error: String? { recorder.summaryErrors[meeting.persistentModelID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Summary", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if points.count > Self.foldedCount {
                    Button(showsAll ? "Show less" : "Show all \(points.count)") {
                        showsAll.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if meeting.summary != nil {
                    Button {
                        summarize()
                    } label: {
                        Label("Regenerate Summary", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSummarizing)
                    .help("Write the summary again")
                }
            }

            // Above the summary rather than instead of it: a failed Regenerate leaves
            // the previous summary on screen, and the failure has to be visible there.
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // In body, the transcript's size. Set a size down, in callout, the first
            // thing wanted on the page was the one block set smaller than the rest.
            if isSummarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…")
                        .foregroundStyle(.secondary)
                }
            } else if !points.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array((showsAll ? points : Array(points.prefix(Self.foldedCount))).enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(point.isBullet ? "\u{2022}" : "")
                                .foregroundStyle(.secondary)
                                .frame(width: 8, alignment: .leading)
                            // Read as Markdown for the bold the model writes, which a
                            // plain string showed as asterisks.
                            Text((try? AttributedString(
                                markdown: point.text,
                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                            )) ?? AttributedString(point.text))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text("No summary yet.")
                        .foregroundStyle(.secondary)
                    Button("Summarize") { summarize() }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
    }

    /// The summary a line at a time, with the model's own bullet marks taken off and
    /// drawn by the page, so a wrapped point hangs under its own first word.
    private var points: [(text: String, isBullet: Bool)] {
        (meeting.summary ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                for mark in ["- ", "* ", "\u{2022} "] where line.hasPrefix(mark) {
                    return (String(line.dropFirst(mark.count)), true)
                }
                return (line, false)
            }
    }

    private func summarize() {
        guard let context = meeting.modelContext else { return }
        Task { await recorder.summarize(meeting, in: context) }
    }
}

// MARK: - Playback Bar

/// A stretch of the recording in which one speaker talks, for the playback strip.
struct SpeakerStretch: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let color: Color
}

/// Play, skip back, the time, a strip of who spoke when, and speed.
///
/// Playback used to exist only line by line: a click on a line played it, and a
/// scrubber appeared under that line alone. There was no way to play a meeting
/// through, to change its speed, or to reach a moment without first playing its line.
///
/// A view of its own because it reads the playback time, which changes four times a
/// second. Read in the page's body, that time redrew the whole transcript with it.
private struct PlaybackBar: View {
    @Bindable var player: MeetingPlayer
    let stretches: [SpeakerStretch]

    private static let speeds: [Float] = [1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 6) {
            // The strip, with the time at one end and the length at the other.
            HStack(spacing: 10) {
                Text(MeetingExporter.durationLabel(player.currentTime))
                    .frame(minWidth: 40, alignment: .trailing)

                SpeakerStrip(
                    stretches: stretches,
                    duration: player.duration,
                    time: player.currentTime
                ) { player.seek(to: $0) }

                Text(MeetingExporter.durationLabel(player.duration))
                    .frame(minWidth: 40, alignment: .leading)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

            // The transport in the middle, as Voice Memos and Podcasts have it: three
            // glyphs with no border, the play the largest, and the speed at the side.
            // It was a bordered play button at the far left beside a borderless skip.
            HStack(spacing: 28) {
                Button {
                    player.skip(by: -15)
                } label: {
                    Label("Back 15 Seconds", systemImage: "gobackward.15")
                        .font(.title2)
                }
                .help("Back 15 seconds")

                // ⌘Return, not Space: the transcript is text, and Space belongs to text.
                Button {
                    player.togglePlayback()
                } label: {
                    Label(player.isPlaying ? "Pause" : "Play",
                          systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 30, height: 30)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help(player.isPlaying ? "Pause (⌘↩)" : "Play from the playhead (⌘↩)")

                Button {
                    player.skip(by: 15)
                } label: {
                    Label("Forward 15 Seconds", systemImage: "goforward.15")
                        .font(.title2)
                }
                .help("Forward 15 seconds")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Picker("Speed", selection: $player.rate) {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Text(speed == 1 ? "1×" : "\(speed.formatted())×").tag(speed)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Playback speed")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }
}

/// The whole recording as a strip, colored by who is speaking, with the playhead on
/// it. A click or a drag moves the playhead.
///
/// It is the slider and a picture of the meeting at once: where the long stretches
/// are, who held the floor, and where the silences fall.
private struct SpeakerStrip: View {
    let stretches: [SpeakerStretch]
    let duration: TimeInterval
    let time: TimeInterval
    let seek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = duration > 0 ? width / duration : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 6)

                Canvas { context, size in
                    for stretch in stretches {
                        let x = stretch.start * scale
                        let w = max(1, (stretch.end - stretch.start) * scale)
                        let rect = CGRect(x: x, y: (size.height - 6) / 2, width: w, height: 6)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(stretch.color.opacity(0.85)))
                    }
                }

                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: 16)
                    .offset(x: min(max(time * scale - 1.5, 0), max(width - 3, 0)))
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard scale > 0 else { return }
                        seek(min(max(value.location.x / scale, 0), duration))
                    }
            )
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(MeetingExporter.durationLabel(time))
        .accessibilityAdjustableAction { direction in
            seek(time + (direction == .increment ? 5 : -5))
        }
    }
}

// MARK: - Live Meeting

/// The page while a meeting records: the clock, Pause and Stop.
///
/// Quiet on purpose. The words as they arrive used to fill the page, and Jonathan
/// found them a distraction during a meeting. They are behind a switch that starts
/// off.
private struct LiveMeetingView: View {
    @Bindable var meeting: Meeting

    @Environment(MeetingRecorder.self) private var recorder
    @Environment(TranscriptionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @AppStorage("liveTranscriptShown") private var showsTranscript = false

    var body: some View {
        VStack(spacing: 0) {
            if !showsTranscript { Spacer(minLength: 0) }

            controls
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)

            Toggle("Show the words as they are heard", isOn: $showsTranscript)
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)

            if showsTranscript {
                Divider()
                liveTranscript
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var liveTranscript: some View {
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
