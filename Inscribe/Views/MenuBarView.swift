import SwiftUI
import SwiftData

#if os(macOS)

/// The main menu bar interface for the transcription tool
struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(TranscriptionEngine.self) private var transcriptionEngine
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(MeetingRecorder.self) private var meetingRecorder
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var modelContext

    /// Kept current while the menu is open, so a microphone plugged in or switched on
    /// appears without reopening it.
    @State private var devices: [AudioInputDevice] = []
    @State private var systemDefaultName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Dictation control
            recordingButton

            Divider()
                .padding(.vertical, 4)

            // Prompt selection
            promptSection

            // Microphone selection, the same setting as in Settings
            microphoneSection
                .padding(.top, 8)

            Divider()
                .padding(.vertical, 4)

            // Quick toggles
            quickToggles

            Divider()
                .padding(.vertical, 4)

            // Meetings
            meetingSection

            Divider()
                .padding(.vertical, 4)

            // Footer actions
            footerSection
        }
        .padding(8)
        .frame(width: 280)
    }

    // MARK: - Recording Button

    /// Why the button cannot start a dictation, when something else holds the engine.
    ///
    /// Asked of the engine's owner rather than `coordinator.isRecording`, which is also
    /// false while a dictation is starting or stopping. That grayed out the button
    /// under its own dictation, with a tooltip blaming a meeting.
    private var dictationBlockedReason: String? {
        guard transcriptionEngine.isBusy else { return nil }
        switch transcriptionEngine.owner {
        case .meeting: return "A meeting is using the microphone."
        case .shortcut: return "A shortcut is recording."
        case .dictation, nil: return nil
        }
    }

    /// "Stop" from the moment a dictation starts coming up, because `toggle()` reads a
    /// press during the start as a stop.
    ///
    /// "Processing…" follows the dictation's own delivery, not every AI request in
    /// flight, which also counted a meeting summary running in the background. That
    /// grayed out this button while the hotkey went on dictating normally.
    private var recordingButtonTitle: String {
        if coordinator.isDelivering { return "Processing…" }
        return coordinator.isCancellable ? "Stop Dictation" : "Start Dictation"
    }

    private var recordingButton: some View {
        Button {
            Task {
                await coordinator.toggle()
            }
        } label: {
            HStack {
                Image(systemName: coordinator.isCancellable ? "stop.fill" : "record.circle")
                    .font(.title3)
                    .foregroundStyle(coordinator.isCancellable ? .red : .primary)

                Text(recordingButtonTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The key is named only while it works. After a reinstall breaks the
                // Accessibility grant, the tap is gone, and the menu went on advertising
                // a key that did nothing. The tooltip says where to turn it back on.
                if hotkeyMonitor.isRunning {
                    triggerLabel
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hotkey not listening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(coordinator.isCancellable ? Color.red.opacity(0.1) : Color.clear)
        )
        .disabled(coordinator.isDelivering || dictationBlockedReason != nil)
        .help(dictationBlockedReason
              ?? (hotkeyMonitor.isRunning ? "" : "The hotkey is not listening. See Settings → Hotkey."))
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                // A nil selectedPromptId means the default prompt, not "nothing
                // selected" — comparing against the id directly left the default
                // showing no checkmark at all while it was the one actually in use.
                ForEach(promptConfig.visiblePrompts) { prompt in
                    Button {
                        settings.selectedPromptId = prompt.id
                    } label: {
                        HStack {
                            Text(prompt.name)
                            if prompt.id == (settings.selectedPromptId ?? PromptConfiguration.defaultPromptId) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(selectedPromptName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                )
            }
            .menuStyle(.borderlessButton)
            .disabled(!settings.aiEnabled)
        }
    }

    // MARK: - Microphone Section

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Microphone")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                microphoneButton(
                    uid: AudioInputDevice.systemDefaultUID,
                    name: "System Default (\(systemDefaultName))"
                )
                if !devices.isEmpty {
                    Divider()
                }
                ForEach(devices) { device in
                    microphoneButton(uid: device.uid, name: device.name)
                }
            } label: {
                HStack {
                    Text(selectedMicrophoneName)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                )
            }
            .menuStyle(.borderlessButton)
        }
        .task {
            devices = AudioDeviceCatalog.inputDevices()
            systemDefaultName = AudioDeviceCatalog.systemDefaultName()
            for await _ in AudioDeviceCatalog.changes() {
                devices = AudioDeviceCatalog.inputDevices()
                systemDefaultName = AudioDeviceCatalog.systemDefaultName()
            }
        }
    }

    private func microphoneButton(uid: String, name: String) -> some View {
        Button {
            settings.inputDeviceUID = uid
        } label: {
            HStack {
                Text(name)
                if uid == settings.inputDeviceUID {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// The chosen microphone, or what recording falls back to when it is unplugged.
    private var selectedMicrophoneName: String {
        let uid = settings.inputDeviceUID
        if uid == AudioInputDevice.systemDefaultUID {
            return "System Default (\(systemDefaultName))"
        }
        return devices.first { $0.uid == uid }?.name ?? "Not Connected: Using System Default"
    }

    private var selectedPromptName: String {
        if !settings.aiEnabled {
            return "AI Disabled"
        }
        guard let promptId = settings.selectedPromptId else {
            return "Clean Up"
        }
        // Naming the default here when the lookup fails hides a stored id whose prompt
        // has been deleted, and with it the reason the AI pass has started failing.
        return promptConfig.prompt(withId: promptId)?.name ?? "Missing Prompt"
    }

    // MARK: - Quick Toggles

    /// Each label fills the row so its switch sits at the trailing edge, where every
    /// other row ends. At their own widths the two toggles were centered, and their
    /// switches sat 11 points apart, left of center.
    private var quickToggles: some View {
        VStack(spacing: 4) {
            Toggle(isOn: Binding(
                get: { settings.aiEnabled },
                set: { settings.aiEnabled = $0 }
            )) {
                Label("AI Processing", systemImage: "brain")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { coordinator.skipAIOnce },
                set: { coordinator.skipAIOnce = $0 }
            )) {
                Label("Skip AI This Time", systemImage: "forward.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!settings.aiEnabled)
        }
        .padding(.vertical, 4)
    }

    /// Open one of the app's windows and bring it to the front.
    ///
    /// A menu bar app is not the active application while its popover is showing, so
    /// `openWindow` on its own puts the new window behind whatever the user was
    /// looking at, and they have to go and find it.
    private func show(_ windowID: String) {
        openWindow(id: windowID)
        NSApp.activate()
    }

    // MARK: - Meeting Section

    /// Meeting mode is deliberately its own control rather than a variant of the
    /// record button: dictation delivers text and forgets it, a meeting is kept.
    private var meetingSection: some View {
        VStack(spacing: 4) {
            Button {
                if meetingRecorder.hasActiveMeeting {
                    Task { await meetingRecorder.stop(in: modelContext) }
                } else {
                    show(ScribeApp.meetingsWindowID)
                    Task { await meetingRecorder.start(in: modelContext) }
                }
            } label: {
                HStack {
                    // The stop icon while paused too, where the row also reads "Stop
                    // Meeting". Red only while the microphone is live.
                    Image(systemName: meetingRecorder.isRecording || meetingRecorder.isPaused
                          ? "stop.circle.fill" : "person.2.wave.2")
                        .foregroundStyle(meetingRecorder.isRecording ? .red : .primary)
                    Text(meetingButtonTitle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .disabled(!meetingButtonEnabled)
            .help(meetingRecorder.state == .idle ? (meetingRecorder.microphoneHeldReason ?? "") : "")

            // Shown only when a pause or resume can act. During "Preparing…" and
            // "Saving…" the row offered a pause that did nothing.
            if meetingRecorder.isRecording || meetingRecorder.isPaused {
                Button {
                    Task {
                        if meetingRecorder.isPaused {
                            await meetingRecorder.resume()
                        } else {
                            await meetingRecorder.pause()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: meetingRecorder.isPaused ? "play.circle" : "pause.circle")
                        Text(meetingRecorder.isPaused ? "Resume Meeting" : "Pause Meeting")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                // A dictation or a shortcut recorded during the pause holds the
                // microphone, and a resume then fails with an error sound and leaves the
                // meeting paused. The meeting's own resume grays the row out too, with no
                // tooltip, since a second click then does nothing.
                .disabled(meetingRecorder.isPaused && transcriptionEngine.isBusy)
                .help(meetingRecorder.isPaused ? (meetingRecorder.microphoneHeldReason ?? "") : "")
            }

            Button {
                show(ScribeApp.meetingsWindowID)
            } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Meetings")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button {
                show(ScribeApp.importWindowID)
            } label: {
                HStack {
                    Image(systemName: "waveform.badge.plus")
                    Text("Import Recording…")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button {
                show(ScribeApp.historyWindowID)
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Dictation History")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    private var meetingButtonTitle: String {
        switch meetingRecorder.state {
        case .idle: "Start Meeting"
        case .preparing: "Preparing…"
        case .recording, .paused: "Stop Meeting"
        case .finishing: "Saving…"
        }
    }

    /// "Preparing…" and "Saving…" report progress and cannot be acted on, as in the
    /// Meetings window. A click on "Preparing…" used to wait for the start and then
    /// stop, saving a meeting a second or two long.
    private var meetingButtonEnabled: Bool {
        switch meetingRecorder.state {
        case .idle: !transcriptionEngine.isBusy
        case .recording, .paused: true
        case .preparing, .finishing: false
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(spacing: 4) {
            // Activated for the same reason as `show(_:)`: an open Settings window
            // behind another app's otherwise stays there.
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings…")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Trigger Description

    /// What the user actually presses, so the menu never advertises a stale shortcut.
    ///
    /// The Globe key is drawn with its SF Symbol, as macOS draws it in menus. The emoji
    /// came out as a colored globe in an otherwise monochrome popover.
    private var triggerLabel: Text {
        settings.useGlobeKey ? Text(Image(systemName: "globe")) : Text(settings.hotkeyDisplay)
    }
}

// MARK: - Menu Bar Icon

/// The status bar draws this as a template image, so only the symbol's shape can say
/// what is happening; a color set here never shows.
struct MenuBarIcon: View {
    let isRecording: Bool
    let isProcessing: Bool

    var body: some View {
        // Named, or VoiceOver reads the status item as the symbol.
        Image(systemName: iconName)
            .accessibilityLabel("Inscribe")
    }

    private var iconName: String {
        if isRecording {
            return "mic.fill"
        } else if isProcessing {
            return "brain"
        } else {
            return "mic"
        }
    }
}

#endif
