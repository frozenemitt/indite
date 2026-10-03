import SwiftUI
import SwiftData

// MARK: - Dictation Settings

/// What happens once the text is in the field. Stored as the three switches that came
/// before it, so an existing choice carries over.
private enum AfterTyping: Hashable {
    case nothing, addSpace, pressReturn, pressShiftReturn
}

/// Which shortcut is waiting for a keystroke.
private enum CaptureTarget {
    case dictation, undo, retype
}

/// Everything about a dictation: the key that starts it, the microphone it hears,
/// where its text goes, and what is kept of it.
struct DictationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor
    @Environment(\.modelContext) private var modelContext

    @Binding var tab: SettingsTab

    @State private var devices: [AudioInputDevice] = []
    @State private var systemDefaultName = ""
    @State private var capturing: CaptureTarget?
    @State private var captureError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            SetupStatusSection(tab: $tab)

            Section("Dictation Key") {
                Toggle(isOn: $settings.useGlobeKey) {
                    Label("Use the Globe key", systemImage: "globe")
                }

                if settings.useGlobeKey {
                    Text("Set System Settings → Keyboard → “Press \(Image(systemName: "globe")) key to” to Do Nothing, or macOS will also switch your input source every time you dictate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                        )
                    }
                    .buttonStyle(.link)
                } else {
                    shortcutRow("Key combination", target: .dictation, display: settings.hotkeyDisplay)
                }

                Picker("Pressing it", selection: $settings.hotkeyActivationModeRaw) {
                    ForEach(HotkeyActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }

                LabeledContent("Escape") {
                    Text("Discards the dictation")
                }
            }

            // How each key works is in its tooltip. A caption stays only where it
            // warns.
            Section("Undo Key") {
                Toggle("Take back the last dictation with a key", isOn: $settings.undoHotkeyEnabled)
                    .help("Works for two minutes after the text was typed, and puts the text on your clipboard. Not available when After typing presses Return.")

                if settings.undoHotkeyEnabled {
                    shortcutRow("Key combination", target: .undo, display: settings.undoHotkeyString)

                    // Dictation wins when both use one shortcut. This caption is the
                    // only sign that undo has stepped aside.
                    if settings.undoHotkeyTrigger == nil {
                        Label {
                            Text("Off while dictation uses the same combination.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Type-Again Key") {
                Toggle("Type the last dictation again with a key", isOn: $settings.retypeHotkeyEnabled)
                    .help("For a dictation that landed in the wrong place: put the cursor where it should have gone and press this.")

                if settings.retypeHotkeyEnabled {
                    shortcutRow("Key combination", target: .retype, display: settings.retypeHotkeyString)

                    if settings.retypeHotkeyTrigger == nil {
                        Label {
                            Text("Off while another key uses the same combination.")
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
                Picker("Record from", selection: $settings.inputDeviceUID) {
                    Text("System Default (\(systemDefaultName))")
                        .tag(AudioInputDevice.systemDefaultUID)
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                if settings.inputDeviceUID != AudioInputDevice.systemDefaultUID,
                   !devices.contains(where: { $0.uid == settings.inputDeviceUID }) {
                    Label {
                        Text("That device is not connected, so recording uses the system default.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }

                // A menu of lengths: the 30-second stepper this replaced took up to
                // 119 clicks to cross its range. A length it saved that is not listed
                // joins the menu, which otherwise shows a blank title, and seconds are
                // allowed so 90 reads as 1 min, 30 sec rather than 2 min.
                Picker("Stop by itself after", selection: $settings.maxRecordingSeconds) {
                    ForEach(Set([60, 120, 300, 600, 900, 1800, 3600, settings.maxRecordingSeconds]).sorted(), id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds])))
                            .tag(seconds)
                    }
                }
                .help("So a key that sticks cannot record for ever.")
            }

            Section("Where the Text Goes") {
                Picker("After transcribing", selection: $settings.outputModeRaw) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if typesText {
                    Toggle("Restore my previous clipboard afterwards", isOn: $settings.restoreClipboardAfterPaste)

                    // One choice of four. It used to be a choice of three with a
                    // switch underneath that appeared for one of them.
                    Picker("After typing", selection: Binding(
                        get: {
                            if settings.autoSubmitAfterInsert {
                                return settings.useShiftReturnAfterInsert ? AfterTyping.pressShiftReturn : .pressReturn
                            }
                            return settings.addSpaceAfterInsert ? .addSpace : .nothing
                        },
                        set: {
                            settings.autoSubmitAfterInsert = $0 == .pressReturn || $0 == .pressShiftReturn
                            settings.useShiftReturnAfterInsert = $0 == .pressShiftReturn
                            settings.addSpaceAfterInsert = $0 == .addSpace
                        }
                    )) {
                        Text("Nothing").tag(AfterTyping.nothing)
                        Text("Add a space").tag(AfterTyping.addSpace)
                        Text("Press Return").tag(AfterTyping.pressReturn)
                        Text("Press Shift-Return").tag(AfterTyping.pressShiftReturn)
                    }
                    .help("Return sends the message in a chat app. Shift-Return starts a new line and leaves it unsent.")
                }
            }

            Section("History") {
                Toggle("Keep recent dictations", isOn: $settings.keepDictationHistory)

                if settings.keepDictationHistory {
                    Picker("Keep the last", selection: $settings.dictationHistoryLimit) {
                        // The stored limit joins the list when it is not on it. The
                        // stepper saved any multiple of 10, and a menu with no entry
                        // for the value in force shows a blank title.
                        ForEach(Set([25, 50, 100, 250, 500, settings.dictationHistoryLimit]).sorted(), id: \.self) { limit in
                            Text("\(limit)").tag(limit)
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

                Text("Everything you dictate is stored in plain text on this Mac. Nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            devices = AudioDeviceCatalog.inputDevices()
            systemDefaultName = AudioDeviceCatalog.systemDefaultName()
        }
        .task {
            // Picks up a microphone plugged in, or a default switched, while this tab
            // is open.
            for await _ in AudioDeviceCatalog.changes() {
                devices = AudioDeviceCatalog.inputDevices()
                systemDefaultName = AudioDeviceCatalog.systemDefaultName()
            }
        }
        .onChange(of: capturing) { _, target in
            if let target { startCapturing(target) } else { hotkeyMonitor.endCapture() }
        }
        .onChange(of: settings.useGlobeKey) { _, _ in
            // The recorder lives in the key combination row, which the Globe key hides.
            // Left armed, capture would go on swallowing every keystroke on the Mac
            // with nothing on screen to say why.
            if capturing == .dictation { capturing = nil }
            rearm()
        }
        .onChange(of: settings.hotkeyString) { _, _ in rearm() }
        .onChange(of: settings.hotkeyActivationModeRaw) { _, _ in rearm() }
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
            case .dictation: settings.hotkeyString = combination
            case .undo: settings.undoHotkeyString = combination
            case .retype: settings.retypeHotkeyString = combination
            }
            capturing = nil
        }
    }

    /// Push the current settings into the running tap.
    private func rearm() {
        hotkeyMonitor.trigger = settings.hotkeyTrigger
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
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
