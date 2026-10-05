import SwiftUI
import AVFoundation
import Speech

#if os(macOS)
import AppKit

/// The window a new user meets first. Shown on the first launch and never again.
///
/// Two pages. The first is laid out as Apple's own welcome windows are: the icon, a
/// title, three rows with a symbol each, one button. The second gets the user to a
/// dictation that works before the window closes.
///
/// It used to end at the first page, with the permissions in small print. A menu bar
/// app has no window to find after launch, and the first dictation then ran into a key
/// that did nothing until Accessibility was granted, two permission prompts that ate
/// the first try, and, on most Macs, the emoji picker opening with every press of the
/// Globe key. Each of those failed with nothing to say why, and a new user gives up
/// at the first one.
struct WelcomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppUpdater.self) private var updater
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    /// Whether the checklist has shown macOS's Accessibility prompt. macOS shows it
    /// once; after that the button opens System Settings instead.
    @AppStorage("askedForAccessibility") private var askedForAccessibility = false

    private enum Page { case welcome, setup }
    @State private var page = Page.welcome

    /// The page's main button has the keyboard. With keyboard navigation on, the first
    /// control in the window took it, and that was a link, which opened with a focus
    /// ring around it.
    private enum Focus { case continueButton, doneButton }
    @FocusState private var focus: Focus?

    // The checklist, read again every second while the setup page shows, since each
    // item is finished in System Settings or in a macOS prompt, not here.
    @State private var hasAccessibility = false
    @State private var microphoneAndSpeech = PermissionState.notAsked
    @State private var globeKeyIsFree = true
    /// Decided once, as the page opens, so the row stays and turns green when fixed
    /// rather than disappearing.
    @State private var showsGlobeKeyRow = false

    @State private var practiceText = ""

    private enum PermissionState { case notAsked, granted, denied }

    var body: some View {
        ZStack {
            switch page {
            case .welcome: welcomePage
            case .setup: setupPage
            }
        }
        .frame(width: 520, height: 700)
        .defaultFocus($focus, .continueButton)
        // Asked for again once the window is key. A menu bar app's window appears
        // before it becomes key, 3.4 s before on the first try, and by then AppKit had
        // given the keyboard to the first control, the link.
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
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .padding(.top, 40)

            Text("Welcome to Nscribe")
                .font(.largeTitle.bold())
                .padding(.top, 16)

            // The menu bar icon itself, so it is seen before it is looked for.
            HStack(spacing: 5) {
                Text("It lives in the menu bar as")
                Image("MenuBarIcon")
            }
            .foregroundStyle(.secondary)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 20) {
                // The Globe key is only where Nscribe starts, and a new user had no way
                // to know another key could be chosen.
                row("globe", "Dictate into any app",
                    "\(howToDictate("talk")) The words are typed where your cursor is.",
                    link: ("Choose a different key…", chooseKey))
                row("person.2.wave.2", "Record meetings",
                    "Start one from the menu bar. It comes back split by speaker, titled and summarized.")
                row("lock.shield", "Everything stays on your Mac",
                    "Transcription, rewriting and speaker separation all run here. Nothing is uploaded.")
            }
            .frame(width: 400)
            .padding(.top, 36)

            Spacer(minLength: 24)

            Button {
                page = .setup
                focus = .doneButton
            } label: {
                Text("Continue")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .focused($focus, equals: .continueButton)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Setup

    private var setupPage: some View {
        VStack(spacing: 0) {
            Text("Get Set Up")
                .font(.largeTitle.bold())
                .padding(.top, 36)

            Text("Each item ticks itself off once it is done.")
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 16) {
                checklistItem(
                    done: hasAccessibility,
                    title: "Allow the dictation key",
                    detail: "Accessibility lets Nscribe hear the key and type into other apps.",
                    button: "Allow…", action: allowAccessibility)

                checklistItem(
                    done: microphoneAndSpeech == .granted,
                    title: "Allow the microphone and speech recognition",
                    detail: microphoneAndSpeech == .denied
                        ? "One of them was turned down. Turn it on in System Settings."
                        : "macOS asks once for each.",
                    button: microphoneAndSpeech == .denied ? "Open Settings…" : "Allow…",
                    action: allowMicrophoneAndSpeech)

                if showsGlobeKeyRow {
                    checklistItem(
                        done: globeKeyIsFree,
                        title: "Free up the Globe key",
                        detail: "macOS also uses it to show emoji or switch input. In Keyboard settings, set “Press 🌐 key to” to Do Nothing.",
                        button: "Open Keyboard Settings…", action: openKeyboardSettings)
                }
            }
            .frame(width: 440)
            .padding(.top, 24)

            practiceBox
                .frame(width: 440)
                .padding(.top, 22)

            // Where everything is found once this window has gone.
            HStack(spacing: 5) {
                Text("Meetings, Settings and recent dictations are in the")
                Image("MenuBarIcon")
                Text("menu.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 18)

            Spacer(minLength: 16)

            // On unless the user turns it off: a fix that waits for someone to look for
            // it rarely arrives.
            VStack(spacing: 4) {
                Toggle("Update automatically", isOn: Binding(
                    get: { updater.updatesAutomatically },
                    set: { updater.setUpdatesAutomatically($0) }
                ))
                Text("Nscribe checks GitHub once a day and asks you to restart when an update is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 400)

            HStack {
                Button("Back") {
                    page = .welcome
                    focus = .continueButton
                }
                .controlSize(.large)

                Spacer()

                Button {
                    dismissWindow()
                } label: {
                    Text("Done")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .focused($focus, equals: .doneButton)
            }
            .frame(width: 440)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .task {
            showsGlobeKeyRow = settings.useGlobeKey && !Self.globeKeyDoesNothing
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

    /// The place to try the key before the window closes. Read only: the words arrive
    /// the way they will in any app, from the key and the microphone.
    private var practiceBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it")
                .font(.headline)

            Text(practiceText.isEmpty ? practicePrompt : practiceText)
                .foregroundStyle(practiceText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .textSelection(.enabled)
        }
    }

    private var practicePrompt: String {
        hasAccessibility
            ? "\(howToDictate("say something")) The words appear here."
            : "Allow the dictation key first, then try it here."
    }

    private func checklistItem(done: Bool, title: String, detail: String,
                               button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !done {
                Button(button, action: action)
            }
        }
    }

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

    /// The key as Settings names it.
    private var key: String {
        settings.useGlobeKey ? "the Globe key" : settings.hotkeyDisplay
    }

    /// How the key is used, in the mode it is set to: "Hold the Globe key and talk."
    private func howToDictate(_ speaking: String) -> String {
        switch settings.hotkeyActivationMode {
        case .pushToTalk: "Hold \(key) and \(speaking)."
        case .toggle: "Press \(key), \(speaking), and press it again."
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

    private func row(_ symbol: String, _ title: String, _ detail: String,
                     link: (title: String, action: () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link {
                    Button(link.title, action: link.action)
                        .buttonStyle(.link)
                }
            }
        }
    }
}
#endif
