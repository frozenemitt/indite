import SwiftUI

#if os(macOS)
import AppKit

/// The window a new user meets first: where the app lives, what the key does, what
/// macOS will ask for. Shown on the first launch and never again.
///
/// A menu bar app has no window to find after launch. Without this, the first sign
/// of Inscribe was a ribbon in the menu bar, and the first dictation ran into two
/// permission prompts and a key that did nothing until Accessibility was granted
/// in System Settings.
struct WelcomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("Welcome to Inscribe")
                    .font(.largeTitle.bold())

                Text("Inscribe lives in the menu bar, as the ribbon.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 22) {
                row("globe", "Dictate into any app",
                    "Hold \(key), speak, and the words appear where your cursor is. In Keyboard settings, set “Press 🌐 key to” to Do Nothing, or macOS switches your input source as well.")
                row("person.2.wave.2", "Record meetings",
                    "Start Meeting from the menu bar. When it ends, the transcript is split by speaker, titled and summarized.")
                row("lock.shield", "Nothing leaves your Mac",
                    "Transcription, rewriting and speaker separation all run on this Mac.")
                row("hand.raised", "Three permissions",
                    "macOS asks for the Microphone and Speech Recognition the first time you dictate. The dictation key and typing into other apps need Accessibility, which is granted in System Settings.") {
                    Button("Open Accessibility Settings…") {
                        AccessibilityPermission.openSystemSettings()
                    }
                    .buttonStyle(.link)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 44)

            Spacer(minLength: 24)

            Button("Continue") {
                hasSeenWelcome = true
                dismissWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 32)
        }
        .frame(width: 540, height: 640)
    }

    /// The key as Settings names it.
    private var key: String {
        settings.useGlobeKey ? "the Globe key" : settings.hotkeyDisplay
    }

    private func row(
        _ symbol: String,
        _ title: String,
        _ detail: String,
        @ViewBuilder footer: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                footer()
            }
        }
    }
}
#endif
