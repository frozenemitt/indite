import SwiftUI

#if os(macOS)
import AppKit

// The windows a person meets around installing and updating Nscribe: the welcome
// window, Software Update and What's New. They are drawn as one family, after
// Apple's own first-run windows and the panes of System Settings: the icon, a title
// and one line of explanation at the top, the content in the system's grouped style,
// the buttons along the bottom with the one that moves forward on the right.

/// The top of every window in the family.
struct WindowHeader: View {
    /// 128 for a welcome, 64 for everything after it.
    var iconSize: CGFloat = 64
    let title: String
    var subtitle: String?

    private var isLarge: Bool { iconSize >= 100 }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)

            Text(title)
                .font(isLarge ? .largeTitle.bold() : .title2.bold())
                .multilineTextAlignment(.center)
                .padding(.top, isLarge ? 14 : 8)

            if let subtitle {
                Text(subtitle)
                    .font(isLarge ? .title3 : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, isLarge ? 6 : 3)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The buttons along the bottom: the way back or out on the left, the way forward on
/// the right, as in Setup Assistant.
struct WindowButtonBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }
}

/// A release's notes, from the Markdown the appcast carries: paragraphs with bold
/// lead-ins.
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            Text(Self.render(markdown))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }

    private static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

/// A window opened from the app's code rather than from a SwiftUI scene, for the
/// windows that Sparkle and the launch decide to show: Software Update and What's
/// New. Sized to its content, which it follows as the content changes.
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Called when the person closes the window with its close button.
    var onClose: (() -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    func show<Content: View>(title: String, @ViewBuilder content: () -> Content) {
        let window = self.window ?? makeWindow(title: title)
        window.contentViewController = NSHostingController(rootView: content())
        (window.contentViewController as? NSHostingController<Content>)?.sizingOptions = [.preferredContentSize]
        if !window.isVisible { window.center() }
        bringForward()
    }

    /// Bring the window in front of the app the person is in. The app has to be made
    /// active first: a menu bar app is not, and its windows otherwise open behind.
    func bringForward() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Close without calling `onClose`: for when the app itself is done with it.
    func close() {
        let handler = onClose
        onClose = nil
        window?.close()
        onClose = handler
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
#endif
