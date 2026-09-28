import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

/// Turn an existing recording into a transcript, optionally speaker-separated.
///
/// The pipeline already existed for the microphone; this points it at a file. Useful
/// for a meeting someone else recorded, or one recorded before Inscribe was running.
struct ImportRecordingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var diarizer = MeetingDiarizer()

    @State private var droppedURL: URL?
    @State private var separateSpeakers = true
    @State private var speakerModelsInstalled = false
    @State private var progressNote: String?
    @State private var savedMeeting: Meeting?
    @State private var errorMessage: String?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone

            if let droppedURL {
                Text(droppedURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Off without the models. Left on, a run transcribed the whole file and
                // only then failed to separate speakers.
                Toggle("Separate speakers", isOn: speakerModelsInstalled ? $separateSpeakers : .constant(false))
                    .disabled(!speakerModelsInstalled)
                Text(speakerModelsInstalled
                     ? "Runs the same diarization meetings use. Slower, and worth it only when more than one person is talking."
                     : "Install the speaker models in Settings → Dictation → Speaker Models to separate speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Transcribe") { run(url: droppedURL) }
                        .disabled(isRunning)
                        .keyboardShortcut(.defaultAction)

                    if let progressNote {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progressNote).font(.caption)
                        }
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let savedMeeting {
                Label("Saved as \"\(savedMeeting.title)\" — open Meetings to read it.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - Views

    private var dropZone: some View {
        Button(action: chooseFile) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .frame(height: 110)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Drop an audio or video file, or click to choose")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                // A plain button hit-tests only what it draws, and inside the dashed
                // border it draws nothing.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o", modifiers: .command)
        .accessibilityLabel("Choose a recording")
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedFile(from: providers)
        }
        // Disabled during a run. accept() turns away any file chosen then, so the panel
        // opened only to discard the choice without a word.
        .disabled(isRunning)
    }

    // MARK: - File Selection

    private func chooseFile() {
        guard let window = NSApp.keyWindow else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]

        // A sheet on the window, as opening is in any document app. Run modally, the
        // panel floated free of the window and blocked every other one in the app.
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            accept(url)
        }
    }

    private func loadDroppedFile(from providers: [NSItemProvider]) -> Bool {
        guard !isRunning, let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in accept(url) }
        }
        return true
    }

    /// Whether a transcription is under way, from the Transcribe press to the save.
    private var isRunning: Bool { progressNote != nil }

    private func accept(_ url: URL) {
        // Ignored while a run is under way. The run clears the chosen file when it
        // saves, so a file accepted mid-run would vanish without a word.
        guard !isRunning else { return }

        // Opened the way the transcriber opens it, so a file is turned away only when
        // the run would fail on it. A list of extensions refused formats it reads, such
        // as .aifc and .m4b, and its message named no format at all for a folder.
        guard (try? AVAudioFile(forReading: url)) != nil else {
            errorMessage = "\(url.lastPathComponent) has no audio Inscribe can read."
            return
        }

        droppedURL = url
        // Checked with every file, so models installed from Settings while this window
        // was open are seen.
        speakerModelsInstalled = DiarizationModelStore.isInstalled
        errorMessage = nil
        savedMeeting = nil
    }

    // MARK: - Running

    private func run(url: URL) {
        errorMessage = nil
        savedMeeting = nil
        // Set before the task starts, so a drop landing before it runs is already
        // turned away.
        progressNote = "Transcribing…"

        Task {
            do {
                let (text, segments) = try await FileTranscriber.transcribe(
                    fileURL: url,
                    vocabulary: settings.vocabularyHints
                )

                var turns: [SpeakerTurn] = []
                if separateSpeakers && speakerModelsInstalled {
                    progressNote = "Separating speakers…"
                    do {
                        try await diarizer.loadModels()
                        // Decoded off the main actor: reading an hour-long file is one
                        // synchronous pass, and this Task inherits the view's isolation.
                        let samples = try await Task.detached {
                            try AudioFileSamples.read(from: url)
                        }.value
                        turns = try await diarizer.diarizeWholeRecording(samples)
                    } catch {
                        // Losing speaker labels should not lose the transcript.
                        errorMessage = "Speaker separation failed: \(error.localizedDescription)"
                    }
                }

                progressNote = "Saving…"
                savedMeeting = save(url: url, transcript: text, segments: segments, turns: turns)
                // Back to the empty drop zone. Left set, Transcribe stayed the default
                // button, and Return imported the same file again as a second meeting.
                droppedURL = nil
                progressNote = nil

            } catch {
                progressNote = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Store the result as a meeting, so it reads and exports like any other.
    private func save(
        url: URL,
        transcript: String,
        segments: [TimedTranscriptSegment],
        turns: [SpeakerTurn]
    ) -> Meeting {
        let meeting = Meeting(title: url.deletingPathExtension().lastPathComponent)
        modelContext.insert(meeting)

        // Dated backwards from now by the length of the recording. Left at now, the
        // meeting spanned no time at all and every list and export read 0:00.
        //
        // The length is the file's own, its frames over its sample rate. Taken from the
        // last transcribed word, it stopped short of any silence or music at the end.
        let file = try? AVAudioFile(forReading: url)
        let length = file.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        meeting.startedAt = Date().addingTimeInterval(-length)
        meeting.endedAt = Date()
        meeting.rawTranscript = TextProcessor.process(
            transcript,
            replacements: settings.wordReplacements
        )
        meeting.recordedDuration = length

        meeting.applyAttribution(
            timedSegments: segments,
            turns: turns,
            vocabulary: settings.vocabularyHints,
            replacements: settings.wordReplacements,
            in: modelContext
        )

        modelContext.saveOrLog()
        return meeting
    }
}
#endif
