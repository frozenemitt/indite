import SwiftUI
import AVFoundation
import Speech
import Combine

// MARK: - Settings View

/// The Settings tabs, each named for the job it holds.
///
/// They used to be named for mechanisms: General, Sounds, Prompts, Hotkey, Output,
/// Dictation, Apps, About. One job was then spread over several. The settings for
/// meetings sat in Dictation and in Output, and no tab was called Meetings.
enum SettingsTab: String, CaseIterable {
    case dictation, rewriting, words, meetings, feedback, apps, about

    static let storageKey = "settingsTab"

    /// Choose the tab Settings shows, before opening it from somewhere else.
    static func open(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var tab: SettingsTab = .dictation

    var body: some View {
        TabView(selection: $tab) {
            DictationSettingsView(tab: $tab)
                .tabItem { Label("Dictation", systemImage: "mic") }
                .tag(SettingsTab.dictation)

            RewritingSettingsView()
                .tabItem { Label("Rewriting", systemImage: "text.bubble") }
                .tag(SettingsTab.rewriting)

            WordsSettingsView()
                .tabItem { Label("Words", systemImage: "character.book.closed") }
                .tag(SettingsTab.words)

            MeetingsSettingsView()
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
                .tag(SettingsTab.meetings)

            FeedbackSettingsView()
                .tabItem { Label("Feedback", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.feedback)

            AppProfilesSettingsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(SettingsTab.apps)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity,
               minHeight: 420, idealHeight: 520, maxHeight: .infinity)
    }
}

// MARK: - Status

/// Everything Indite needs from the Mac, in one list.
///
/// Whether the app was fully set up used to be answered in five places: the hotkey's
/// status in one tab, the AI's in another, the speaker models and the system-audio
/// permission in a third, and the store's in the Meetings window. A new install showed
/// none of them.
///
/// When nothing needs attention the list folds to one line.
struct SetupStatusSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor
    @Environment(\.appearsActive) private var appearsActive

    /// For the row that sends the user to the Meetings tab.
    @Binding var tab: SettingsTab

    @State private var isTrusted = AccessibilityPermission.isTrusted
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var speakerModelsInstalled = DiarizationModelStore.isInstalled
    @State private var showsEverything = false

    /// Re-check while the window is open: the user grants access in System Settings,
    /// and macOS sends no notification when they do.
    private let poll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Status") {
            if needsAttention {
                rows
            } else {
                DisclosureGroup(isExpanded: $showsEverything) {
                    rows
                } label: {
                    StatusRow(mark: .good, title: "Everything Indite needs is in place.")
                }
            }
        }
        .onAppear {
            refresh()
            // Trust may have been granted in a System Settings visit that started
            // before this window was open, in which case the poll below never sees a
            // change to react to.
            if !hotkeyMonitor.isRunning, isTrusted {
                hotkeyMonitor.start()
            }
        }
        .onReceive(poll) { _ in
            let wasTrusted = isTrusted
            refresh()
            // Trust just arrived, so the tap could not have been built before now.
            if isTrusted, !wasTrusted, !hotkeyMonitor.isRunning {
                hotkeyMonitor.start()
            }
        }
        .onChange(of: appearsActive) { _, active in
            // The speaker models are installed from another tab, and the permissions
            // from another app. Reading the disk every second for the models is waste;
            // coming back to this window is when they can have changed.
            if active { speakerModelsInstalled = DiarizationModelStore.isInstalled }
        }
    }

    private func refresh() {
        let trusted = AccessibilityPermission.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
        let microphoneNow = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneNow != microphone { microphone = microphoneNow }
        let speechNow = SFSpeechRecognizer.authorizationStatus()
        if speechNow != speech { speech = speechNow }
    }

    /// Whether any row is one the user has to act on.
    private var needsAttention: Bool {
        !isTrusted
            || hotkeyMonitor.hasFailed
            || microphone == .denied || microphone == .restricted
            || speech == .denied || speech == .restricted
            || AIProcessor.unavailabilityReason != nil
            || !MeetingStoreStatus.shared.isPersistent
    }

    @ViewBuilder
    private var rows: some View {
        keyRow
        permissionRow(
            "Microphone",
            granted: microphone == .authorized,
            refused: microphone == .denied || microphone == .restricted,
            pane: "Privacy_Microphone"
        )
        permissionRow(
            "Speech recognition",
            granted: speech == .authorized,
            refused: speech == .denied || speech == .restricted,
            pane: "Privacy_SpeechRecognition"
        )

        if let reason = AIProcessor.unavailabilityReason {
            StatusRow(mark: .attention, title: "Apple Intelligence", detail: reason)
        } else {
            StatusRow(mark: .good, title: "Apple Intelligence",
                      detail: "Rewrites dictations and summarizes meetings, on this Mac.")
        }

        if speakerModelsInstalled {
            StatusRow(mark: .good, title: "Speaker models", detail: "Installed.")
        } else {
            StatusRow(mark: .unknown, title: "Speaker models",
                      detail: "Not installed. Meetings are transcribed without speaker names.",
                      actionTitle: "Show") { tab = .meetings }
        }

        if settings.captureSystemAudioInMeetings {
            // Nothing tests this permission. The only test creates a tap, and a
            // refused permission may not refuse one, so the test could report access
            // macOS never gave.
            StatusRow(mark: .unknown, title: "System audio, for calls",
                      detail: "macOS gives no way to check this permission.",
                      actionTitle: "Open System Settings") { SystemAudioCapture.openSystemSettings() }
        }

        if !MeetingStoreStatus.shared.isPersistent {
            StatusRow(mark: .attention, title: "Meetings are not being saved to disk",
                      detail: MeetingStoreStatus.shared.failureReason
                        ?? "They will be lost when you quit.")
        }
    }

    /// The dictation key, which needs Accessibility access and a tap that built.
    @ViewBuilder
    private var keyRow: some View {
        if !isTrusted {
            // macOS shows its own prompt at most once per app version. Launch has
            // spent it by the time anyone opens this window, so System Settings is the
            // only way in from here.
            StatusRow(mark: .attention, title: "Accessibility",
                      detail: "Needed for the dictation key and for typing into other apps.",
                      actionTitle: "Open System Settings") { AccessibilityPermission.openSystemSettings() }
        } else if hotkeyMonitor.hasFailed {
            StatusRow(mark: .attention, title: "Dictation key",
                      detail: hotkeyMonitor.lastError,
                      actionTitle: "Try Again") { hotkeyMonitor.start() }
        } else {
            let key = settings.useGlobeKey ? "the Globe key" : settings.hotkeyDisplay
            StatusRow(mark: .good, title: "Dictation key", detail: "Listening for \(key).")
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, refused: Bool, pane: String) -> some View {
        if granted {
            StatusRow(mark: .good, title: title, detail: "Allowed.")
        } else if refused {
            StatusRow(mark: .attention, title: title, detail: "Not allowed.",
                      actionTitle: "Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                )
            }
        } else {
            StatusRow(mark: .unknown, title: title, detail: "macOS asks the first time you dictate.")
        }
    }
}

/// One line of the Status list: a mark, what it is about, and the button that fixes it.
private struct StatusRow: View {
    enum Mark {
        case good, attention, unknown
    }

    let mark: Mark
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        LabeledContent {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                switch mark {
                case .good:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .attention:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .unknown:
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
        }
    }
}
