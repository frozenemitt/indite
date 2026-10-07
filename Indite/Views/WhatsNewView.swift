import SwiftUI

#if os(macOS)

/// The What's New window's content, for the notes `AppUpdater` kept.
struct WhatsNewWindow: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        if let whatsNew = updater.whatsNew {
            WhatsNewView(version: whatsNew.version, notes: whatsNew.notes) {
                FamilyWindows.close(FamilyWindows.whatsNew)
            }
        }
    }
}

/// Shown once, on the first launch of a new version, with that version's notes: the
/// same notes the update carried, kept when it was installed.
struct WhatsNewView: View {
    let version: String
    let notes: String
    let onContinue: () -> Void

    @FocusState private var continueHasKeyboard: Bool

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "What’s New in Indite", subtitle: "Version \(version)")
                .padding(.top, 30)
                .padding(.horizontal, FamilyMetrics.headerMargin)

            ReleaseNotesView(markdown: notes, maxHeight: 320)
                .padding(.horizontal, FamilyMetrics.margin)
            .padding(.top, 20)

            WindowButtonBar {
                EmptyView()
            } trailing: {
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .focused($continueHasKeyboard)
                    .focusEffectDisabled()
            }
        }
        .frame(width: FamilyMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .defaultFocus($continueHasKeyboard, true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            DispatchQueue.main.async { continueHasKeyboard = true }
        }
    }
}
#endif
