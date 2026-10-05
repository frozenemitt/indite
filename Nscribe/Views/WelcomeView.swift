import SwiftUI
import AVFoundation
import Speech

#if os(macOS)
import AppKit

/// The window a new user meets first. Shown on the first launch and never again.
///
/// Two pages, drawn like the rest of the family in `WindowFamily.swift`. The first is
/// a welcome in the manner of Apple's own: the icon, the name, what Nscribe does. The
/// second is a setup pane in the manner of System Settings, and it gets the person to
/// a dictation that works before the window closes.
///
/// It used to stop at a single page, with the permissions in small print. The first
/// dictation then ran into a key that did nothing until Accessibility was granted, two
/// permission prompts that used up the first try, and, on most Macs, the emoji picker
/// opening with every press of the Globe key. Each failed with nothing to say why.
struct WelcomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppUpdater.self) private var updater
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(TranscriptionEngine.self) private var engine
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    /// Whether setup has shown macOS's Accessibility prompt. macOS shows it once;
    /// after that the button opens System Settings instead.
    @AppStorage("askedForAccessibility") private var askedForAccessibility = false

    private enum Page { case welcome, setup }
    @State private var page = Page.welcome

    /// The page's main button has the keyboard. With keyboard navigation on, the first
    /// control in the window took it, and that was a link, which opened with a focus
    /// ring around it.
    private enum Focus { case continueButton, doneButton }
    @FocusState private var focus: Focus?

    // Read again every second while setup shows, since each step is finished in System
    // Settings or in a macOS prompt, not here.
    @State private var hasAccessibility = false
    @State private var microphoneAndSpeech = PermissionState.notAsked
    @State private var globeKeyIsFree = true
    /// Decided once, as setup opens, so the step stays and turns green when fixed
    /// rather than disappearing.
    @State private var showsGlobeKeyStep = false

    @State private var practiceText = ""

    private enum PermissionState { case notAsked, granted, denied }

    var body: some View {
        ZStack {
            switch page {
            case .welcome: welcomePage
            case .setup: setupPage
            }
        }
        .frame(width: 540, height: 700)
        .defaultFocus($focus, .continueButton)
        // Asked for again once the window is key. A menu bar app's window appears
        // before it becomes key, 3.4 s before on the first try, and by then AppKit had
        // given the keyboard to the first control.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            DispatchQueue.main.async { focus = page == .welcome ? .continueButton : .doneButton }
        }
        // Closing the window counts as seen, so the dictation key's own Accessibility
        // prompt, held back while this window is up, comes once it is gone.
        .onDisappear {
            hasSeenWelcome = true
            coordinator.practiceReceiver = nil
        }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            WindowHeader(iconSize: 128,
                         title: "Welcome to Nscribe",
                         subtitle: "Speak instead of typing, and keep every meeting in writing.")
                .padding(.horizontal, 48)

            VStack(alignment: .leading, spacing: 22) {
                feature("waveform", "Dictate anywhere",
                        "Talk instead of typing. Your words appear at the cursor, in any app.")
                feature("person.2.wave.2", "Meetings, written down",
                        "Record a call or a conversation. Nscribe separates the speakers and writes a title and a summary.")
                feature("lock.shield", "Private by design",
                        "Speech recognition, rewriting and speaker separation all run on this Mac. Nothing is uploaded.")
            }
            .frame(width: 400)
            .padding(.top, 40)

            Spacer(minLength: 0)

            WindowButtonBar {
                EmptyView()
            } trailing: {
                Button("Continue") {
                    page = .setup
                    focus = .doneButton
                }
                .keyboardShortcut(.defaultAction)
                .focused($focus, equals: .continueButton)
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Setup

    private var setupPage: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "Set Up Nscribe",
                         subtitle: "Allow what macOS protects, then try your first dictation.")
                .padding(.top, 30)
                .padding(.horizontal, 40)

            Form {
                Section("Permissions") {
                    step(1, done: hasAccessibility,
                         title: "Accessibility",
                         detail: "Lets the dictation key work in every app, and lets Nscribe type for you.",
                         action: ("Allow…", allowAccessibility))

                    step(2, done: microphoneAndSpeech == .granted,
                         title: "Microphone and Speech Recognition",
                         detail: microphoneAndSpeech == .denied
                            ? "Turned off in System Settings. Both are needed to dictate."
                            : "Lets Nscribe hear you and turn speech into text, on this Mac.",
                         action: (microphoneAndSpeech == .denied ? "Open Settings…" : "Allow…",
                                  allowMicrophoneAndSpeech))

                    if showsGlobeKeyStep {
                        step(3, done: globeKeyIsFree,
                             title: "Globe Key",
                             detail: "macOS also uses this key. In Keyboard settings, set “Press \(Image(systemName: "globe")) key to” to Do Nothing.",
                             action: ("Open Keyboard Settings…", openKeyboardSettings))
                    }
                }

                Section("Dictation Key") {
                    LabeledContent {
                        Button("Change…", action: chooseKey)
                    } label: {
                        Text(keyName)
                        Text(keyMode)
                    }
                }

                Section("Try It") {
                    practiceBox
                }

                Section {
                    Toggle("Update Nscribe automatically", isOn: Binding(
                        get: { updater.updatesAutomatically },
                        set: { updater.setUpdatesAutomatically($0) }
                    ))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)

            // Where everything is once this window has gone.
            HStack(spacing: 5) {
                Text("Meetings, Settings and recent dictations are in the")
                Image("MenuBarIcon")
                Text("menu.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            WindowButtonBar {
                Button("Back") {
                    page = .welcome
                    focus = .continueButton
                }
            } trailing: {
                Button("Done") { dismissWindow() }
                    .keyboardShortcut(.defaultAction)
                    .focused($focus, equals: .doneButton)
            }
        }
        .task {
            showsGlobeKeyStep = settings.useGlobeKey && !Self.globeKeyDoesNothing
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear {
            coordinator.practiceReceiver = { text in
                practiceText = practiceText.isEmpty ? text : practiceText + " " + text
            }
        }
        .onDisappear { coordinator.practiceReceiver = nil }
    }

    /// One numbered step: its number until it is done, a checkmark after.
    private func step(_ number: Int, done: Bool, title: String, detail: LocalizedStringKey,
                      action: (title: String, run: () -> Void)) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .green)
                } else {
                    Circle()
                        .fill(.tint)
                        .frame(width: 22, height: 22)
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 24)
            .accessibilityLabel(done ? "Done" : "Step \(number)")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if done {
                Text("Allowed")
                    .foregroundStyle(.secondary)
            } else {
                Button(action.title, action: action.run)
            }
        }
    }

    /// The place to try the key before the window closes. The words arrive as they
    /// will in any app: live while the person talks, then finished.
    private var practiceBox: some View {
        let listening = coordinator.isCancellable && coordinator.practiceReceiver != nil
            && NSApp.isActive
        let live = (engine.currentTranscript + " " + engine.volatileText)
            .trimmingCharacters(in: .whitespaces)

        return Group {
            if listening && !live.isEmpty {
                Text(live)
            } else if !practiceText.isEmpty {
                Text(practiceText)
                    .textSelection(.enabled)
            } else if !hasAccessibility {
                Text("Allow Accessibility above to try the dictation key here.")
                    .foregroundStyle(.secondary)
            } else if listening {
                Text("Listening…")
                    .foregroundStyle(.secondary)
            } else {
                Text(practicePrompt)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
    }

    // MARK: - State

    private func refresh() {
        hasAccessibility = AccessibilityPermission.isTrusted

        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if microphone == .authorized && speech == .authorized {
            microphoneAndSpeech = .granted
        } else if [.denied, .restricted].contains(microphone) || [.denied, .restricted].contains(speech) {
            microphoneAndSpeech = .denied
        } else {
            microphoneAndSpeech = .notAsked
        }

        globeKeyIsFree = Self.globeKeyDoesNothing
    }

    // MARK: - Actions

    private func chooseKey() {
        SettingsTab.open(.dictation)
        openSettings()
        WindowFronting.bringForward("com_apple_SwiftUI_Settings")
    }

    /// macOS's own prompt the first time, which also puts Nscribe in the Accessibility
    /// list; System Settings after that, since macOS shows the prompt only once.
    private func allowAccessibility() {
        if askedForAccessibility {
            AccessibilityPermission.openSystemSettings()
        } else {
            askedForAccessibility = true
            AccessibilityPermission.requestTrust()
        }
    }

    private func allowMicrophoneAndSpeech() {
        guard microphoneAndSpeech == .denied else {
            Task {
                _ = await TranscriptionEngine.shared.requestAuthorization()
                refresh()
            }
            return
        }
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let pane = [.denied, .restricted].contains(microphone) ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    // MARK: - Words

    private var keyName: String {
        settings.useGlobeKey ? "Globe key" : settings.hotkeyDisplay
    }

    private var keyMode: String {
        switch settings.hotkeyActivationMode {
        case .pushToTalk: "Hold it while you talk."
        case .toggle: "Press it to start, and again to stop."
        }
    }

    private var practicePrompt: LocalizedStringKey {
        let key: LocalizedStringKey = settings.useGlobeKey
            ? "\(Image(systemName: "globe"))"
            : "\(settings.hotkeyDisplay)"
        switch settings.hotkeyActivationMode {
        case .pushToTalk: return "Hold \(Text(key)), say a sentence, and let go."
        case .toggle: return "Press \(Text(key)), say a sentence, then press it again."
        }
    }

    /// Whether macOS's "Press 🌐 key to" setting is Do Nothing. Anything else also
    /// opens the emoji picker, switches the input source or starts Apple's dictation on
    /// every press. Missing means the setting was never changed, and the factory
    /// choice is not Do Nothing.
    private static var globeKeyDoesNothing: Bool {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int) == 0
    }
}
#endif
