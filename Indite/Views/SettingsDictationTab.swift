import SwiftUI
import SwiftData

// MARK: - Dictation Settings

/// What happens once the text is in the field. Stored as the three switches that came
/// before it, so an existing choice carries over.
private enum AfterTyping: Hashable {
    case nothing, pressReturn, pressShiftReturn
}

/// Which shortcut is waiting for a keystroke.
private enum CaptureTarget {
    case undo, retype
}

/// Everything about a dictation: the key that starts it, the microphone it hears,
/// where its text goes, and what is kept of it.
struct DictationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor
    @Environment(\.modelContext) private var modelContext

    @Binding var tab: SettingsTab

    /// Which microphones are connected, kept current while the app runs.
    private let inputs = AudioInputList.shared
    @State private var capturing: CaptureTarget?
    @State private var captureError: String?

    /// A dictation that still has its recording, if any does, for the recording settings.
    @Query(DictationSettingsView.oneRecorded) private var recorded: [Dictation]

    private static var oneRecorded: FetchDescriptor<Dictation> {
        var descriptor = FetchDescriptor<Dictation>(predicate: #Predicate { $0.recordingFileName != nil })
        descriptor.fetchLimit = 1
        return descriptor
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            SetupStatusSection(tab: $tab)

            Section("Dictation Key") {
                Picker("Key", selection: $settings.dictationKeyRaw) {
                    ForEach(OptionKey.allCases) { key in
                        Text(key.displayName).tag(key.rawValue)
                    }
                }
                .help("Only Option pressed by itself starts a dictation. Option with another key, such as Option-E, or with a click, works as it always does.")

                Picker("To dictate", selection: $settings.hotkeyActivationModeRaw) {
                    ForEach(HotkeyActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .help("When you hold the key, you can also press it twice quickly to keep dictating without holding it. Press it once more to finish. Escape cancels a dictation, and nothing is typed.")

                Picker("Also start with a mouse button", selection: $settings.dictationMouseButtonRaw) {
                    Text("Off").tag(String?.none)
                    ForEach(MouseButton.allCases) { button in
                        Text(button.displayName).tag(Optional(button.rawValue))
                    }
                }
                .help("Click the side button on your mouse to start a dictation, and click it again to finish. That button then stops going back or forward in other apps.")
            }

            // How each key works is in its tooltip. A caption stays only where it
            // warns.
            Section("Undo Key") {
                Toggle("Undo the last dictation with a key", isOn: $settings.undoHotkeyEnabled)
                    .help("Press the keys within two minutes, and the words Indite just typed are removed. They are copied, so you can paste them somewhere else. This is not available while Indite presses Return after typing.")

                if settings.undoHotkeyEnabled {
                    shortcutRow("Key combination", target: .undo, display: settings.undoHotkeyString)
                }
            }

            Section("Type-Again Key") {
                Toggle("Type the last dictation again with a key", isOn: $settings.retypeHotkeyEnabled)
                    .help("If your words landed in the wrong place, click where they should go and press the keys.")

                if settings.retypeHotkeyEnabled {
                    shortcutRow("Key combination", target: .retype, display: settings.retypeHotkeyString)

                    if settings.retypeHotkeyTrigger == nil {
                        Label {
                            Text("Off, because Undo uses the same keys.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                }
            }

            if let captureError {
                Section {
                    Text(captureError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Microphone") {
                MicrophoneOrderRows(order: $settings.microphoneOrder, connected: inputs.devices)

                // A menu of lengths: the 30-second stepper this replaced took up to
                // 119 clicks to cross its range. A length it saved that is not listed
                // joins the menu, which otherwise shows a blank title, and seconds are
                // allowed so 90 reads as 1 min, 30 sec rather than 2 min.
                Picker("Stop automatically after", selection: $settings.maxRecordingSeconds) {
                    ForEach(Set([60, 120, 300, 600, 900, 1800, 3600, settings.maxRecordingSeconds]).sorted(), id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds])))
                            .tag(seconds)
                    }
                }
                .help("Ends a dictation that has run this long, in case the key sticks or you forget to stop.")

                Toggle("Mute the Mac while you dictate", isOn: $settings.muteWhileDictating)
                    .help("Music, videos and calls go quiet until you finish. Indite's own sounds still play.")
            }

            Section("Where the Text Goes") {
                Picker("When you stop talking", selection: $settings.outputModeRaw) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if typesText {
                    caption("If the cursor is not somewhere you can type, the words are copied for you to paste.")

                    Toggle("Keep what I had copied before", isOn: $settings.restoreClipboardAfterPaste)
                    caption("Indite types by pasting. On: whatever you copied earlier is still there to paste afterwards. Off: Paste gives you the words you dictated.")

                    // One choice of three. "Add a space" was a fourth until Indite
                    // spaced each dictation from the words around the cursor itself.
                    Picker("After typing, press", selection: Binding(
                        get: {
                            if settings.autoSubmitAfterInsert {
                                return settings.useShiftReturnAfterInsert ? AfterTyping.pressShiftReturn : .pressReturn
                            }
                            return .nothing
                        },
                        set: {
                            settings.autoSubmitAfterInsert = $0 == .pressReturn || $0 == .pressShiftReturn
                            settings.useShiftReturnAfterInsert = $0 == .pressShiftReturn
                        }
                    )) {
                        Text("Nothing").tag(AfterTyping.nothing)
                        Text("Return").tag(AfterTyping.pressReturn)
                        Text("Shift-Return").tag(AfterTyping.pressShiftReturn)
                    }
                    caption("Return sends the message in most chat apps. Shift-Return starts a new line without sending.")

                    Toggle("Say \u{201C}press enter\u{201D} to press Return", isOn: $settings.pressEnterSubmits)
                    caption("End a dictation with \u{201C}press enter\u{201D} or \u{201C}press return\u{201D}. Indite leaves those words out and presses Return, which sends the message in most chat apps. It does this even when you meant those words to be written.")
                }
            }

            Section("Recent Dictations") {
                Toggle("Keep a list of recent dictations", isOn: $settings.keepDictationHistory)

                if settings.keepDictationHistory {
                    Picker("Keep the last", selection: $settings.dictationHistoryLimit) {
                        // The stored limit joins the list when it is not on it. The
                        // stepper saved any multiple of 10, and a menu with no entry
                        // for the value in force shows a blank title.
                        ForEach(Set([25, 50, 100, 250, 500, settings.dictationHistoryLimit]).sorted(), id: \.self) { limit in
                            Text("\(limit) dictations").tag(limit)
                        }
                    }
                    // A menu rather than a stepper. A stepper applies every value it
                    // passes on the way, so the pruning below deleted dictations for good
                    // at each lower one. Pruned on the choice itself because pruning
                    // otherwise waits for the next saved dictation, which could be a long
                    // wait for a setting the user just changed on purpose.
                    .onChange(of: settings.dictationHistoryLimit) { _, newLimit in
                        DictationHistory.prune(to: newLimit, in: modelContext)
                        modelContext.saveOrLog()
                    }
                }

                // With the history off, recordings kept before still go after their days,
                // so their settings show for as long as any is left.
                if settings.keepDictationHistory || !recorded.isEmpty {
                    // Any number of days, typed, as Jonathan asked on 2026-11-08, rather
                    // than a menu of lengths. Recordings past it go at the next launch or
                    // dictation, not as the field changes; see
                    // `DictationHistory.expireRecordings`.
                    LabeledContent("Keep voice recordings for") {
                        HStack(spacing: 6) {
                            TextField("Days", value: Binding(
                                get: { settings.dictationRecordingDays },
                                set: { settings.dictationRecordingDays = max(1, $0) }
                            ), format: .number)
                            .labelsHidden()
                            // Bordered so it reads as a field to type in. A grouped
                            // form draws a plain one as a bare "14", like a value.
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            Text(settings.dictationRecordingDays == 1 ? "day" : "days")
                        }
                    }
                    .disabled(settings.keepDictationRecordingsForever)
                    .help("Indite saves the sound of each dictation, so Recent Dictations can turn it into text again. After this many days the sound is deleted. The text stays.")

                    Toggle("Keep until the dictation leaves the list", isOn: $settings.keepDictationRecordingsForever)
                        .help("The recording is deleted only when its dictation drops off the Recent Dictations list.")
                }

                Text("Your dictations and their recordings are saved on this Mac and sent nowhere. They are not locked, so anyone who can use your account on this Mac can read them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: capturing) { _, target in
            if let target { startCapturing(target) } else { hotkeyMonitor.endCapture() }
        }
        .onChange(of: settings.dictationKeyRaw) { _, _ in rearm() }
        .onChange(of: settings.hotkeyActivationModeRaw) { _, _ in rearm() }
        .onChange(of: settings.dictationMouseButtonRaw) { _, _ in rearm() }
        .onChange(of: settings.undoHotkeyEnabled) { _, _ in
            if capturing == .undo { capturing = nil }
            rearm()
        }
        .onChange(of: settings.undoHotkeyString) { _, _ in rearm() }
        .onChange(of: settings.retypeHotkeyEnabled) { _, _ in
            if capturing == .retype { capturing = nil }
            rearm()
        }
        .onChange(of: settings.retypeHotkeyString) { _, _ in rearm() }
        .onDisappear {
            // Capture swallows every keystroke on the machine, so it must never
            // outlive the screen that turned it on.
            hotkeyMonitor.endCapture()
            capturing = nil
        }
    }

    /// Small grey text under a control, for what a person must know before using it.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Key Combination

    /// A shortcut is its own button, as in System Settings: click it, then type the
    /// combination.
    private func shortcutRow(_ title: String, target: CaptureTarget, display: String) -> some View {
        LabeledContent(title) {
            Button(capturing == target ? "Type Combination…" : display) {
                capturing = capturing == target ? nil : target
            }
            .monospaced(capturing != target)
            // Recording listens through the tap. Without one nothing hears the
            // keystroke, and "Type Combination…" waited for ever.
            .disabled(capturing != target && !hotkeyMonitor.isRunning)
            .help("Use at least two of ⌃, ⌥ and ⌘, so the combination cannot swallow an everyday one like ⌘W. Escape cancels.")
        }
    }

    /// Listen for the combination the user wants, through the tap that is already
    /// watching the keyboard.
    ///
    /// The tap sees keystrokes wherever they are typed, so this does not depend on
    /// the settings window holding keyboard focus, which is what a menu bar app
    /// cannot promise.
    private func startCapturing(_ target: CaptureTarget) {
        captureError = nil

        hotkeyMonitor.beginCapture { keyCode, modifiers in
            if keyCode == 53 {  // Escape
                capturing = nil
                return
            }

            guard let combination = AppSettings.hotkeyString(
                forKeyCode: keyCode,
                modifiers: modifiers
            ) else {
                // Stay armed and say why, rather than swallowing the keystroke and
                // leaving the user pressing keys at a screen that never answers.
                captureError = "That one cannot be used. Use a letter, number or punctuation key with at least two of ⌃, ⌥ and ⌘."
                return
            }

            switch target {
            case .undo: settings.undoHotkeyString = combination
            case .retype: settings.retypeHotkeyString = combination
            }
            capturing = nil
        }
    }

    /// Push the current settings into the running tap.
    private func rearm() {
        hotkeyMonitor.dictationKey = settings.dictationKey
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
        hotkeyMonitor.mouseButton = settings.dictationMouseButton
        hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger
        hotkeyMonitor.retypeTrigger = settings.retypeHotkeyTrigger
        if !hotkeyMonitor.isRunning, AccessibilityPermission.isTrusted {
            hotkeyMonitor.start()
        }
    }

    /// Whether anything types text: the global choice, or an app profile.
    ///
    /// The typing options apply to both. Tied to the global choice alone, they
    /// disappeared whenever it copied, while a profile that types still followed them.
    private var typesText: Bool {
        settings.outputMode == .smartInsert
            || settings.appProfiles.values.contains {
                $0.isEnabled && $0.outputModeRaw == OutputMode.smartInsert.rawValue
            }
    }
}
