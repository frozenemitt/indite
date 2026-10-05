import SwiftUI

#if os(macOS)

/// Shown once, on the first launch of a new version, with that version's notes: the
/// same notes the update carried, kept when it was installed.
struct WhatsNewView: View {
    let version: String
    let notes: String
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "What’s New in Nscribe", subtitle: "Version \(version)")
                .padding(.top, 34)
                .padding(.horizontal, 32)

            ReleaseNotesView(markdown: notes)
                .frame(height: 260)
                .padding(.horizontal, 24)
                .padding(.top, 18)

            WindowButtonBar {
                EmptyView()
            } trailing: {
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
