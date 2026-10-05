import SwiftUI

#if os(macOS)
import AppKit

// The windows a person meets around installing and updating Nscribe: the welcome
// window, Software Update and What's New. They are drawn as one family, after
// Apple's own first-run windows and the panes of System Settings: the icon, a title
// and one line of explanation at the top, the content in the system's grouped style,
// the buttons along the bottom with the one that moves forward on the right.

/// The top of every window in the family: one icon size and one title style in all
/// of them, so moving from page to page or from state to state never jumps.
struct WindowHeader: View {
    static let iconSize: CGFloat = 80

    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)

            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 10)

            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The buttons along the bottom. In the welcome window the way back sits on the
/// left, as in Setup Assistant; in the others the buttons group on the right, the
/// one that moves forward last, as macOS lays out its dialogs.
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
        .padding(.top, 14)
        .padding(.bottom, 20)
    }
}

/// A release's notes, set as the welcome window sets its summary: a title and a line
/// under it for each change. The appcast carries them as Markdown paragraphs that
/// open with a bold title.
struct ReleaseNotesView: View {
    let markdown: String

    /// As tall as the notes, up to this; longer notes scroll.
    var maxHeight: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(Self.notes(in: markdown).enumerated()), id: \.offset) { _, note in
                    VStack(alignment: .leading, spacing: 3) {
                        if let title = note.title {
                            Text(title)
                                .font(.headline)
                        }
                        Text(note.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct Note {
        let title: String?
        let detail: AttributedString
    }

    /// "**Title.** Detail" becomes a title and its detail; any other paragraph is
    /// detail alone.
    private static func notes(in markdown: String) -> [Note] {
        markdown.components(separatedBy: "\n\n").compactMap { raw in
            let paragraph = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { return nil }
            if paragraph.hasPrefix("**"),
               let close = paragraph.range(of: "**", range: paragraph.index(paragraph.startIndex, offsetBy: 2)..<paragraph.endIndex) {
                let title = String(paragraph[paragraph.index(paragraph.startIndex, offsetBy: 2)..<close.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                let rest = String(paragraph[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                return Note(title: title, detail: render(rest))
            }
            return Note(title: nil, detail: render(paragraph))
        }
    }

    private static func render(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}

/// A key drawn as a keycap, for where the windows say which key to press.
struct KeyCap: View {
    let key: String
    var showsGlobe = false

    var body: some View {
        HStack(spacing: 3) {
            if showsGlobe {
                Image(systemName: "globe")
            } else {
                Text(key)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 7)
        .frame(minWidth: 26, minHeight: 22)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
        .accessibilityLabel(showsGlobe ? "Globe key" : key)
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
