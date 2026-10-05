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

    /// The page's main button has the keyboard, without a focus ring of its own beside
    /// the blue it already has. With keyboard navigation on, the first control in the
    /// window took the keyboard, and that was a link, which opened ringed.
    private enum Focus { case continueButton, doneButton }
    @FocusState private var focus: Focus?

    // Read again every second while setup shows, since each step is finished in System
    // Settings or in a macOS prompt, not here.
    @State private var hasAccessibility = false
    @State private var microphoneAndSpeech = PermissionState.notAsked
    @State private var globeKeyIsFree = true
    /// Decided once, as setup opens, so the line stays and turns green when fixed
    /// rather than disappearing.
    @State private var showsGlobeKeySetting = false

    @State private var practiceText = ""

    private enum PermissionState { case notAsked, granted, denied }

    /// Every row's button is as wide as the widest, so their edges line up.
    private static let rowButtonWidth: CGFloat = 112

    var body: some View {
        ZStack {
            switch page {
            case .welcome: welcomePage
            case .setup: setupPage
            }
        }
        .frame(width: FamilyMetrics.width, height: 760)
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

            WindowHeader(title: "Welcome to Nscribe",
                         subtitle: "Dictation and meeting transcripts.")
                .padding(.horizontal, FamilyMetrics.headerMargin)

            VStack(alignment: .leading, spacing: 24) {
                feature("waveform", "Dictate anywhere",
                        "Talk instead of typing. Your words appear at the cursor, in any app.")
                feature("person.2.wave.2", "Meetings, written down",
                        "Record a call or a conversation. Nscribe separates the speakers and writes a title and a summary.")
                feature("lock.shield", "Private by design",
                        "Speech recognition, rewriting and speaker separation all run on this Mac. Nothing is uploaded.")
            }
            .frame(width: 400)
            .padding(.top, 44)

            // A little more room below than above, so the content sits at the eye's
            // center rather than the window's.
            Spacer(minLength: 0)
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
                .focusEffectDisabled()
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // Gray: on this page only the button is for pressing.
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 30)

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

    private var setupIsComplete: Bool {
        hasAccessibility && microphoneAndSpeech == .granted
    }

    private var setupPage: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "Set Up Nscribe",
                         subtitle: "Allow two permissions, then try your first dictation.")
                .padding(.top, 30)
                .padding(.horizontal, FamilyMetrics.headerMargin)

            Form {
                Section {
                    step(1, done: hasAccessibility,
                         title: "Accessibility",
                         detail: "Lets the dictation key work, and type, in any app.",
                         button: "Allow…", isNext: !hasAccessibility,
                         action: allowAccessibility)

                    step(2, done: microphoneAndSpeech == .granted,
                         title: "Microphone and Speech Recognition",
                         detail: microphoneAndSpeech == .denied
                            ? "Turned off in System Settings. Dictation needs both."
                            : "Lets Nscribe hear and transcribe you.",
                         button: microphoneAndSpeech == .denied ? "Open Settings…" : "Allow…",
                         isNext: hasAccessibility && microphoneAndSpeech != .granted,
                         action: allowMicrophoneAndSpeech)
                }

                Section("Try It") {
                    keyRow
                    if showsGlobeKeySetting {
                        globeKeyRow
                    }
                    practiceBox
                }

                Section {
                    menuBarRow
                    row {
                        Toggle("Update Nscribe automatically", isOn: Binding(
                            get: { updater.updatesAutomatically },
                            set: { updater.setUpdatesAutomatically($0) }
                        ))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)

            WindowButtonBar {
                Button("Back") {
                    page = .welcome
                    focus = .continueButton
                }
            } trailing: {
                // Prominent only once Nscribe can work. Before that, Done still closes
                // the window, and the steps above stay the way forward.
                if setupIsComplete {
                    Button("Done") { dismissWindow() }
                        .keyboardShortcut(.defaultAction)
                        .focused($focus, equals: .doneButton)
                        .focusEffectDisabled()
                } else {
                    Button("Done") { dismissWindow() }
                        .focused($focus, equals: .doneButton)
                        .focusEffectDisabled()
                }
            }
        }
        .task {
            showsGlobeKeySetting = settings.useGlobeKey && !Self.globeKeyDoesNothing
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

    /// One numbered step: a gray number until it is done, a green check after. Only
    /// the next step's button is prominent.
    private func step(_ number: Int, done: Bool, title: String, detail: String,
                      button: String, isNext: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: FamilyMetrics.iconSpacing) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .green)
                } else {
                    Circle()
                        .strokeBorder(.tertiary, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: FamilyMetrics.iconColumn)
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
                EmptyView()
            } else if isNext {
                Button(action: action) { Text(button).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .frame(width: Self.rowButtonWidth)
            } else {
                Button(action: action) { Text(button).frame(maxWidth: .infinity) }
                    .frame(width: Self.rowButtonWidth)
            }
        }
        // The button's height whether or not it is there, so finishing a step never
        // moves the rows below it.
        .frame(minHeight: 28)
    }

    private var keyRow: some View {
        row {
            HStack(spacing: 10) {
                Text("Dictation key")
                Spacer()
                KeyCap(key: settings.hotkeyDisplay, showsGlobe: settings.useGlobeKey)
                Button(action: chooseKey) { Text("Change…").frame(maxWidth: .infinity) }
                    .frame(width: Self.rowButtonWidth)
            }
        }
    }

    /// A row with nothing in the shared column, so its label still starts on the same
    /// edge as every other row's.
    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: FamilyMetrics.iconSpacing) {
            Color.clear
                .frame(width: FamilyMetrics.iconColumn, height: 1)
            content()
        }
    }

    /// macOS's own use of the Globe key, shown only when it gets in the way.
    private var globeKeyRow: some View {
        HStack(spacing: FamilyMetrics.iconSpacing) {
            Image(systemName: globeKeyIsFree ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(globeKeyIsFree ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                .frame(width: FamilyMetrics.iconColumn)
            Text(globeKeyIsFree
                 ? "The Globe key is free for Nscribe."
                 : "macOS also uses the Globe key. Set “Press \(Image(systemName: "globe")) key to” to Do Nothing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // Kept in place, unseen, once the key is free, so the row keeps its height
            // and nothing below it moves.
            Button(action: openKeyboardSettings) { Text("Open Settings…").frame(maxWidth: .infinity) }
                .frame(width: Self.rowButtonWidth)
                .opacity(globeKeyIsFree ? 0 : 1)
                .disabled(globeKeyIsFree)
        }
        .frame(minHeight: 36)
    }

    /// The place to try the key before the window closes. The words arrive as they
    /// will in any app, live while the person talks, under the ribbon that moves with
    /// their voice.
    private var practiceBox: some View {
        let listening = coordinator.isCancellable && coordinator.practiceReceiver != nil && NSApp.isActive
        let live = (engine.currentTranscript + " " + engine.volatileText)
            .trimmingCharacters(in: .whitespaces)

        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if listening && !live.isEmpty {
                    Text(live)
                } else if !practiceText.isEmpty {
                    Text(practiceText)
                        .lineLimit(4)
                        .textSelection(.enabled)
                } else if !hasAccessibility {
                    Text("Allow Accessibility above, then try the dictation key here.")
                        .foregroundStyle(.secondary)
                } else if listening {
                    Text("Listening…")
                        .foregroundStyle(.secondary)
                } else {
                    practicePrompt
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            if listening {
                ListeningBar(spectrum: engine.spectrum, isProcessing: coordinator.isRewriting)
                    .frame(height: 22)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 84)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .padding(.leading, FamilyMetrics.iconColumn + FamilyMetrics.iconSpacing)
    }

    /// The last thing to know: where Nscribe is once this window has gone.
    private var menuBarRow: some View {
        HStack(spacing: FamilyMetrics.iconSpacing) {
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 18)
                .foregroundStyle(.primary)
                .frame(width: FamilyMetrics.iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nscribe lives in the menu bar")
                Text("Meetings, Settings and recent dictations are all in its menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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

    /// What to do with the key, with the key drawn as a keycap.
    private var practicePrompt: some View {
        let key = KeyCap(key: settings.hotkeyDisplay, showsGlobe: settings.useGlobeKey)
        return HStack(spacing: 5) {
            switch settings.hotkeyActivationMode {
            case .pushToTalk:
                Text("Hold")
                key
                Text("and say a sentence, then let go.")
            case .toggle:
                Text("Press")
                key
                Text("to start, say a sentence, then press it again.")
            }
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
