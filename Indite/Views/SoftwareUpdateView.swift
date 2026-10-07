import SwiftUI

#if os(macOS)

/// Indite's Software Update window: one layout for every step, from checking to
/// restarting. The header holds its place and only the middle changes: the notes, a
/// progress bar, or nothing. The buttons group on the right, the one that moves
/// forward last, as macOS lays out its dialogs.
struct SoftwareUpdateView: View {
    let driver: UpdateDriver

    /// The button that moves forward has the keyboard, without a focus ring of its
    /// own beside the blue it already has. With keyboard navigation on, the first
    /// button took the keyboard, and "Later" opened ringed while "Update Now" was blue.
    @FocusState private var primaryHasKeyboard: Bool

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: title, subtitle: subtitle)
                .padding(.top, 30)
                .padding(.horizontal, FamilyMetrics.headerMargin)

            // The same margins as the buttons, so the bar ends where Cancel does.
            middle
                .padding(.horizontal, FamilyMetrics.margin)
                .padding(.top, 20)

            buttons
        }
        .frame(width: FamilyMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .defaultFocus($primaryHasKeyboard, true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            DispatchQueue.main.async { primaryHasKeyboard = true }
        }
        .onDisappear { driver.windowDidClose() }
    }

    // MARK: - Words

    private var title: String {
        switch driver.phase {
        case .idle, .checking: "Checking for Updates…"
        case .upToDate: "Indite is up to date"
        case .available(let version, _, _): "Indite \(version) is available"
        case .downloading(let version, _, _): "Downloading Indite \(version)"
        case .preparing(let version): "Preparing Indite \(version)"
        case .ready(let version), .waitingForRecording(let version): "Indite \(version) is ready"
        case .installing(let version): "Installing Indite \(version)"
        case .failed(let title, _): title
        }
    }

    private var subtitle: String? {
        switch driver.phase {
        case .idle, .checking: nil
        case .upToDate: "Version \(UpdateDriver.currentVersion) is the newest version."
        case .available(_, _, let infoURL):
            infoURL == nil
                ? "You have version \(UpdateDriver.currentVersion)."
                : "This version is described on the Indite website."
        case .downloading: "Indite will restart when the download finishes."
        case .preparing: nil
        case .ready: "Restart Indite to finish updating."
        case .waitingForRecording: "Indite will restart when your recording ends."
        case .installing: "Indite will open again in a moment."
        case .failed(_, let message): message
        }
    }

    // MARK: - Middle

    @ViewBuilder
    private var middle: some View {
        switch driver.phase {
        case .idle, .checking, .preparing, .installing:
            ProgressView()
                .progressViewStyle(.linear)

        case .downloading(_, let received, let expected):
            VStack(alignment: .leading, spacing: 6) {
                if expected > 0 {
                    ProgressView(value: Double(min(received, expected)), total: Double(expected))
                } else {
                    ProgressView()
                }
                HStack {
                    Text(expected > 0
                         ? "\(Self.size(received)) of \(Self.size(expected))"
                         : Self.size(received))
                    Spacer()
                    if let seconds = driver.secondsRemaining {
                        Text(Self.remaining(seconds))
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)

        case .available(_, let notes, _) where !notes.isEmpty:
            ReleaseNotesView(markdown: notes)

        default:
            EmptyView()
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        WindowButtonBar {
            EmptyView()
        } trailing: {
            switch driver.phase {
            case .idle, .checking, .downloading:
                Button("Cancel") { driver.cancel() }
                    .keyboardShortcut(.cancelAction)

            case .upToDate, .failed:
                primary("OK") { driver.acknowledge() }

            case .available(_, _, let infoURL):
                Button("Later") { driver.notNow() }
                    .keyboardShortcut(.cancelAction)
                if let infoURL {
                    primary("Learn More…") { driver.openInfoPage(infoURL) }
                } else {
                    primary("Update Now") { driver.installNow() }
                }

            case .ready:
                Button("Later") { driver.notNow() }
                    .keyboardShortcut(.cancelAction)
                primary("Restart Now") { driver.installNow() }

            case .waitingForRecording:
                // The restart is already set for when the recording ends, so the
                // window only closes; the other button says what it will cost.
                Button("Close") { driver.closeWindow() }
                    .keyboardShortcut(.cancelAction)
                primary("Stop Recording and Restart") { driver.installNow() }

            case .preparing, .installing:
                // Past the point where the update can be stopped. The hidden button
                // keeps the window the height of every other state.
                Button("Cancel") {}
                    .disabled(true)
                    .hidden()
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(.defaultAction)
            .focused($primaryHasKeyboard)
            .focusEffectDisabled()
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func remaining(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 60 ? [.minute] : [.second]
        formatter.maximumUnitCount = 1
        let rounded = seconds >= 60 ? (seconds / 60).rounded(.up) * 60 : max(5, (seconds / 5).rounded(.up) * 5)
        return "About \(formatter.string(from: rounded) ?? "") left"
    }
}
#endif
