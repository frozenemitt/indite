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

/// Opens and closes the family's windows from code that is not a view: Sparkle's
/// driver and the launch. SwiftUI hands its window actions only to views, so the menu
/// bar icon, on screen for the app's whole life, passes them here.
///
/// They were AppKit windows sized to their content at first. Under a transparent
/// title bar every resize changed the content's inset, which asked for another resize,
/// and AppKit stopped the app twice on the way to the first screenshot. SwiftUI's own
/// window scenes size themselves as the welcome window does, without that loop.
@MainActor
enum FamilyWindows {
    static let softwareUpdate = "software-update"
    static let whatsNew = "whats-new"

    private static var openWindow: OpenWindowAction?
    private static var dismissWindow: DismissWindowAction?
    /// Asked for before the menu bar icon appeared: What's New, at launch.
    private static var waiting: [String] = []

    static func register(open: OpenWindowAction, dismiss: DismissWindowAction) {
        openWindow = open
        dismissWindow = dismiss
        let ids = waiting
        waiting = []
        ids.forEach(show)
    }

    static func show(_ id: String) {
        guard let openWindow else {
            if !waiting.contains(id) { waiting.append(id) }
            return
        }
        openWindow(id: id)
        WindowFronting.bringForward(id)
    }

    static func close(_ id: String) {
        waiting.removeAll { $0 == id }
        dismissWindow?(id: id)
    }

    static func isShowing(_ id: String) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(id) == true }
    }
}

/// Put on the menu bar icon, which is the one view alive from launch to quit.
struct RegistersFamilyWindows: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear { FamilyWindows.register(open: openWindow, dismiss: dismissWindow) }
    }
}
#endif
