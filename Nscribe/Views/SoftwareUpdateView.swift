import SwiftUI

#if os(macOS)

/// Nscribe's Software Update window: one layout for every step, from checking to
/// restarting. Its parts are the welcome window's: the icon and a title at the top,
/// the content in the middle, the buttons along the bottom.
struct SoftwareUpdateView: View {
    let driver: UpdateDriver

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: title, subtitle: subtitle)
                .padding(.top, 34)
                .padding(.horizontal, 32)

            middle
                .padding(.horizontal, 24)
                .padding(.top, 18)

            buttons
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { driver.windowDidClose() }
    }

    // MARK: - Words

    private var title: String {
        switch driver.phase {
        case .idle, .checking: "Checking for Updates"
        case .upToDate: "Nscribe is up to date"
        case .available(let version, _, _): "Nscribe \(version) is available"
        case .downloading(let version, _, _): "Downloading Nscribe \(version)"
        case .preparing(let version): "Preparing Nscribe \(version)"
        case .ready(let version): "Nscribe \(version) is ready"
        case .installing(let version): "Installing Nscribe \(version)"
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
                : "This version is announced on its website rather than installed here."
        case .downloading, .preparing: nil
        case .ready: "Restart Nscribe to finish updating."
        case .installing: "Nscribe will open again in a moment."
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
                .frame(maxWidth: 320)

        case .downloading(_, let received, let expected):
            VStack(spacing: 6) {
                if expected > 0 {
                    ProgressView(value: Double(min(received, expected)), total: Double(expected))
                } else {
                    ProgressView()
                }
                Text(expected > 0
                     ? "\(Self.size(received)) of \(Self.size(expected))"
                     : Self.size(received))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 320)

        case .available(_, let notes, _) where !notes.isEmpty:
            ReleaseNotesView(markdown: notes)
                .frame(height: 220)

        default:
            EmptyView()
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        switch driver.phase {
        case .idle, .checking, .downloading:
            WindowButtonBar {
                EmptyView()
            } trailing: {
                Button("Cancel") { driver.cancel() }
                    .keyboardShortcut(.cancelAction)
            }

        case .upToDate, .failed:
            WindowButtonBar {
                EmptyView()
            } trailing: {
                Button("OK") { driver.acknowledge() }
                    .keyboardShortcut(.defaultAction)
            }

        case .available(_, _, let infoURL):
            WindowButtonBar {
                Button("Not Now") { driver.notNow() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                if let infoURL {
                    Button("Learn More…") { driver.openInfoPage(infoURL) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Update Now") { driver.installNow() }
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .ready:
            WindowButtonBar {
                Button("Later") { driver.notNow() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                Button("Restart Now") { driver.installNow() }
                    .keyboardShortcut(.defaultAction)
            }

        case .preparing, .installing:
            // Nothing to choose: the update is past the point where it can be stopped.
            Color.clear.frame(height: 24)
        }
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
#endif
