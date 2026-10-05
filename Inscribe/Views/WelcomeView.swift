import SwiftUI

#if os(macOS)
import AppKit

/// The window a new user meets first: where the app lives, what it does, what macOS
/// will ask for. Shown on the first launch and never again.
///
/// Laid out as Apple's own welcome windows are: the icon, a title, three rows with a
/// symbol each, the small print, one button. A menu bar app has no window to find
/// after launch, and without this the first sign of Inscribe was an icon in the menu
/// bar, and the first dictation ran into two permission prompts and a key that did
/// nothing until Accessibility was granted in System Settings.
struct WelcomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    /// Continue has the keyboard from the start. With keyboard navigation on, the
    /// first control in the window took it, and that was a link, which opened with a
    /// focus ring around it.
    @FocusState private var continueHasKeyboard: Bool

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .padding(.top, 32)

            Text("Welcome to Inscribe")
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
                row("globe", "Dictate into any app",
                    "Hold \(key) and talk. The words are typed where your cursor is.")
                row("person.2.wave.2", "Record meetings",
                    "Start one from the menu bar. It comes back split by speaker, titled and summarized.")
                row("lock.shield", "Everything stays on your Mac",
                    "Transcription, rewriting and speaker separation all run here. Nothing is uploaded.")
            }
            .frame(width: 400)
            .padding(.top, 32)

            Spacer(minLength: 24)

            // The small print, as Apple's welcome windows carry it above the button.
            VStack(spacing: 6) {
                Text("macOS will ask for the Microphone and Speech Recognition when you first dictate. The dictation key needs Accessibility, which you grant in System Settings.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings…") {
                    AccessibilityPermission.openSystemSettings()
                }
                .buttonStyle(.link)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(width: 400)

            Button {
                hasSeenWelcome = true
                dismissWindow()
            } label: {
                Text("Continue")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .focused($continueHasKeyboard)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .frame(width: 520, height: 660)
        .defaultFocus($continueHasKeyboard, true)
    }

    /// The key as Settings names it.
    private var key: String {
        settings.useGlobeKey ? "the Globe key" : settings.hotkeyDisplay
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
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
            }
        }
    }
}
#endif
