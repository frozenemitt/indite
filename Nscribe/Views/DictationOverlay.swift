import SwiftUI

/// How a dictation ended, for the panel to say.
struct OverlayOutcome: Equatable {
    let symbol: String
    let headline: String
    /// Shown dimmed under the headline: the words that were copied, or the microphone
    /// that heard nothing.
    var detail = ""

    /// No text field had focus, so the words are on the clipboard.
    static func copied(_ text: String) -> OverlayOutcome {
        OverlayOutcome(symbol: "doc.on.clipboard", headline: "Copied. Press ⌘V to paste.", detail: text)
    }

    /// The paste was sent and the field never said it arrived.
    static let unconfirmed = OverlayOutcome(
        symbol: "questionmark.circle",
        headline: "Pasted, but the app did not confirm it.",
        detail: "If the words are missing, they are on the clipboard. Press ⌘V."
    )

    static func nothingHeard(microphone: String) -> OverlayOutcome {
        OverlayOutcome(symbol: "exclamationmark.triangle", headline: "Nothing was heard.",
                       detail: "Microphone: \(microphone)")
    }

    /// Something went wrong. `copied` adds where the words went, when they went to the
    /// clipboard.
    static func problem(_ message: String, copied: Bool = false) -> OverlayOutcome {
        OverlayOutcome(symbol: "exclamationmark.triangle", headline: message,
                       detail: copied ? "The words are on the clipboard. Press ⌘V to paste." : "")
    }
}

#if os(macOS)
import AppKit

/// A floating panel showing what Nscribe is hearing, while you hold the key.
///
/// Feedback used to be a sound and a menu bar icon, which tells you recording started
/// but not whether the words are landing. Seeing the text arrive is the difference
/// between trusting the dictation and repeating yourself.
///
/// It is glass rather than an opaque card, and the user sets how solid: the panel sits
/// over the thing being dictated into, and a pane you can read through lets you keep
/// both in view. Drag it anywhere; where you leave it is where it comes back.
@MainActor
final class DictationOverlayController {

    private var panel: NSPanel?

    private let model = OverlayModel()
    private let settings: AppSettings
    /// Held so the desktop-change notifications keep arriving for the life of the app.
    private var spaceObserver: (any NSObjectProtocol)?
    /// Held so the display-change notifications keep arriving for the life of the app.
    private var screenObserver: (any NSObjectProtocol)?
    /// Saves where the user drops the current panel. Replaced with the panel.
    private var dragWatcher: PanelDragWatcher?

    /// Takes an outcome off the screen once it has been up long enough to read.
    private var outcomeTask: Task<Void, Never>?

    static let minimumHeight: CGFloat = 92
    static let width: CGFloat = 460
    static let bandHeight: CGFloat = 22
    static let contentSpacing: CGFloat = 10
    static let verticalPadding: CGFloat = 28

    /// Visible over full-screen apps and on every desktop: a call is usually
    /// full-screen, and that is exactly when the overlay is wanted.
    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    init(settings: AppSettings) {
        self.settings = settings
        model.resizePanel = { [weak self] in self?.fitToText() }
    }

    // MARK: - Presentation

    func show() {
        outcomeTask?.cancel()
        model.outcome = nil
        model.text = ""
        model.rewrite = ""
        model.isProcessing = false
        model.spectrum = []
        present()
    }

    /// Say how a dictation ended, when it did not end with the words in the field.
    ///
    /// A dictation copied to the clipboard used to look the same as one that was
    /// typed, and one that heard nothing closed the panel without a word. The only
    /// report was a notification, which many people switch off, and which appears at
    /// the far corner of the screen from where the panel is being watched.
    ///
    /// Up for three seconds, then gone. A dictation started meanwhile takes the panel
    /// over at once.
    func showOutcome(_ outcome: OverlayOutcome) {
        outcomeTask?.cancel()
        model.outcome = outcome
        model.text = outcome.detail
        model.rewrite = ""
        model.isProcessing = false
        model.spectrum = []
        present()
        // The headline needs room the one-line panel does not have. The text reports
        // its own height only when that changes, and an outcome's one line of detail
        // is often as tall as the dictation before it.
        fitToText()

        outcomeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Put the panel on screen at one line's height, where the user left it.
    private func present() {
        // A panel the window server has taken off the other desktops is thrown away
        // and rebuilt, because it cannot be talked back onto them.
        //
        // Saying `collectionBehavior` again does nothing. AppKit compares the value it
        // is handed against the one it already holds, finds them equal, and never
        // passes anything to the window server — and the window server is the one that
        // has forgotten. Measured on a panel stripped to a single desktop: assigning
        // the same value left it on one of eight, and so did assigning a different one.
        // A panel built a moment ago is on all eight.
        //
        // `isOnActiveSpace` is what tells a stranded panel from a healthy one. A panel
        // on every desktop is on the active one whichever desktop that is, so false
        // means this panel is somewhere the user is not.
        if panel == nil || panel?.isOnActiveSpace == false {
            replacePanel()
        }
        watchForStranding()
        followScreenChanges()

        place()
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key status would pull
        // focus out of the app being dictated into, which is where the text must land.
        panel?.orderFrontRegardless()
    }

    /// One line tall, where the user left it.
    private func place() {
        // Back to one line's worth, so each dictation grows from the same place.
        // `position` below puts it back where the user left it.
        if let panel, panel.frame.height != Self.minimumHeight {
            var frame = panel.frame
            frame.size.height = Self.minimumHeight
            panel.setFrame(frame, display: false)
        }
        position(panel)
    }

    /// Put an open panel back where it would open whenever a display comes or goes.
    ///
    /// macOS carries a window off a removed display to the same distance from the
    /// bottom of another one, and does not bring it back onto that display's screen.
    /// Measured: a panel near the top of a 1440-point display landed above the top
    /// edge of the laptop's 1329-point screen, on no screen at all. Nor does macOS
    /// return it when the display is plugged back in. A dictation that spans the
    /// change now lands where the user left the panel, or at the bottom of the screen
    /// if that spot is gone, and grows back to the words it holds.
    private func followScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                self.place()
                self.fitToText()
            }
        }
    }

    func update(text: String, spectrum: [Double]) {
        model.spectrum = spectrum

        // Only when it changed: the band wants twenty updates a second, and laying out
        // a panel-tall block of text that often to say the same words is waste.
        guard model.text != text else { return }
        model.text = text
    }

    func showProcessing() {
        model.isProcessing = true
        model.rewrite = ""
    }

    /// Show the AI's rewrite as it is written.
    ///
    /// The words appear about 0.7 s after release instead of when the whole rewrite
    /// is done, 3 s later for a long dictation. The paste still waits for the end.
    func showRewrite(_ text: String) {
        guard model.isProcessing, model.rewrite != text else { return }
        model.rewrite = text
    }

    func hide() {
        outcomeTask?.cancel()
        panel?.orderOut(nil)
        model.outcome = nil
        model.text = ""
        model.rewrite = ""
        model.isProcessing = false
        model.spectrum = []
    }

    /// Forget a dragged position, so the panel returns to the bottom of the screen.
    ///
    /// A panel dragged to a screen that is later unplugged would otherwise open
    /// somewhere the user cannot see, with no way back to it.
    func resetPosition() {
        settings.overlayOriginX = nil
        settings.overlayOriginY = nil
        position(panel)
    }

    /// Grow the panel to fit the text, moving only its bottom edge.
    ///
    /// The panel used to be 92 points tall whatever it held, so a dictation past a
    /// line and a half showed its last two lines and hid everything before them.
    ///
    /// It never shrinks to follow the text. The text loses a line and gains it back
    /// when a hypothesis shortens across a line break, and it drops several lines when
    /// the rewrite's first words replace the dictation. Following either pulled the
    /// bottom edge up and walked it back down. `show()` puts the panel back to one line
    /// for the next dictation.
    ///
    /// It shrinks only when its screen can no longer hold it. A panel grown tall on one
    /// screen and dragged onto a shorter one mid-dictation kept its height and hung off
    /// the bottom edge. It is now cut to the tallest panel the new screen can hold when
    /// the drag ends.
    ///
    /// It runs when the text reports a new height, not when new text is set. The text
    /// is laid out on a later pass, so a height read straight after setting it belonged
    /// to the words before, and a line that wrapped on the last word before a pause
    /// stayed cut off until the next word arrived.
    private func fitToText() {
        guard let panel else { return }

        let ceiling = availableTextHeight(for: panel)
        if abs(model.maxTextHeight - ceiling) > 0.5 {
            model.maxTextHeight = ceiling
        }

        // The text measures itself and says how tall it is. Asking the view hierarchy
        // stopped working once the glass view was in it: the glass pins its content to
        // its own bounds, which come from the panel, so every view was being told its
        // height by the one thing that wanted to be told. The panel stopped growing.
        let chrome = Self.bandHeight + Self.contentSpacing + Self.verticalPadding + headlineHeight
        let fitted = max(min(model.textHeight, ceiling) + chrome, Self.minimumHeight)
        let tallest = max(ceiling + chrome, Self.minimumHeight)
        // Grows to the text, and keeps any height the text gives back, up to the
        // tallest panel this screen can hold.
        let height = max(fitted, min(panel.frame.height, tallest))
        guard abs(height - panel.frame.height) > 0.5 else { return }

        // The top edge stays where it is and the bottom edge moves, so each new line
        // lands below the last, the way a page fills. The view pins its contents to the
        // top, so a panel held taller than its text keeps the spare room below the
        // words. An NSWindow's origin is its bottom-left corner, so holding the top
        // means moving the origin.
        //
        // Once the bottom reaches the bottom of the screen, the panel grows upward
        // instead, and a panel cut down to a shorter screen is lifted onto it. `show()`
        // puts the panel back where the user left it, so the next dictation starts from
        // the same place.
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame,
           frame.minY < visible.minY + Self.screenMargin {
            frame.origin.y = visible.minY + Self.screenMargin
        }
        // Not displayed here. The text's measurement calls this from inside SwiftUI's
        // layout pass, where forcing a display would lay the hosting view out again
        // within its own layout. The new frame is drawn on the next pass.
        panel.setFrame(frame, display: false)
    }

    /// Kept clear between the panel and the edges of the screen.
    private static let screenMargin: CGFloat = 12

    /// The room an outcome's headline takes above the text, or none while dictating.
    private var headlineHeight: CGFloat {
        model.outcome == nil ? 0 : DictationOverlayView.lineHeight + Self.contentSpacing
    }

    /// The text room in the tallest panel the screen can hold.
    ///
    /// The panel grows downward and then upward, so only a dictation taller than
    /// the whole screen starts dropping its oldest lines off the top.
    private func availableTextHeight(for panel: NSPanel) -> CGFloat {
        guard let screen = panel.screen ?? NSScreen.main else {
            return DictationOverlayView.lineHeight * 5
        }
        // Everything in the panel that is not text: the band, the gap under it, and
        // the padding. Only the padding was counted, so the tallest panel grew 32
        // points too high, up under the menu bar.
        let chrome = Self.bandHeight + Self.contentSpacing + Self.verticalPadding + headlineHeight
        let room = screen.visibleFrame.height - 2 * Self.screenMargin - chrome
        return max(room, DictationOverlayView.lineHeight)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.minimumHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow. On a light desktop a drop shadow around a dark panel reads as a
        // dark border drawn round it — and it is invisible in dark mode, which is why
        // the edge only ever looked wrong in one of the two.
        panel.hasShadow = false
        panel.level = .floating

        // Draggable, which means it also takes the clicks that land on it. That is the
        // trade for being able to move it out of the way mid-sentence: it is a small
        // target, it never takes focus, and the alternative is a panel you cannot move.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = Self.collectionBehavior
        // Stays up when Nscribe is hidden, which would otherwise take the panel away
        // in the middle of a dictation.
        panel.canHide = false

        // The SwiftUI content swallows the mouse, so `isMovableByWindowBackground`
        // never sees a click and the panel could not be dragged at all. This view sits
        // under the content, takes every hit, and drags the window itself. Safe
        // because the panel is display-only: there is nothing in it to click.
        let hosting = NSHostingView(rootView: DictationOverlayView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The glass the panel is made of. AppKit's own view rather than SwiftUI's
        // modifier: this one samples the windows behind the panel, which the SwiftUI
        // version had no access to inside a borderless transparent panel.
        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        // Apple's Regular glass, untinted, with its own edge. It frosts the windows
        // behind, so the words read over whatever is there. The clear glass it
        // replaced, faded by a Glass slider, let the text behind show through under
        // the dictation.
        glass.style = .regular
        glass.cornerRadius = 26

        let container = DragHandleView()
        // Remembered only when the user drags it. Every programmatic move used to be
        // saved too, so placing the panel on the screen with the pointer pinned it to
        // that screen for good, and each resize nudged the saved spot upward.
        dragWatcher = PanelDragWatcher(panel: panel) { [weak self] frame in
            guard let self else { return }
            self.settings.overlayOriginX = frame.origin.x
            // Saved as the spot a one-line panel would take with the same top edge,
            // since the top is what stays put. A panel dragged while grown tall
            // otherwise came back that much lower.
            self.settings.overlayOriginY = frame.maxY - Self.minimumHeight
            // A drag onto a shorter screen left a tall panel hanging off its bottom
            // edge until the text next changed height. Fitted after the save, so a
            // panel lifted onto the screen still comes back where the user dropped it.
            self.fitToText()
        }
        container.addSubview(glass)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        return panel
    }

    /// Drop the current panel and build another in its place.
    ///
    /// The old one is ordered out first so it does not linger on whatever desktop it
    /// was stranded on.
    private func replacePanel() {
        panel?.orderOut(nil)
        panel = makePanel()
    }

    /// Replace the panel if a desktop change finds it stranded.
    ///
    /// The panel has to follow the user across desktops mid-sentence: dictation often
    /// starts in one place and lands in another, and a panel left behind takes the
    /// words with it. A healthy panel follows on its own, being on every desktop
    /// already. A stranded one never comes back, and the next dictation is too late to
    /// be any use to the dictation that is running now.
    ///
    /// A panel on every desktop is on the one the user just moved to, whichever that
    /// is, so `isOnActiveSpace` is false only for a panel that has been stranded. A
    /// healthy panel is left alone and nothing blinks.
    ///
    /// The rebuilt panel is grown back to the text it was holding: the words live in
    /// the model, not in the panel, but its height was measured into the old one.
    private func watchForStranding() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel,
                      panel.isVisible, !panel.isOnActiveSpace else { return }
                self.replacePanel()
                self.position(self.panel)
                self.fitToText()
                self.panel?.orderFrontRegardless()
            }
        }
    }

    /// Where the user left it, or the bottom centre of the screen holding the pointer.
    ///
    /// A saved spot is pulled inside the screen it mostly lies on. Any overlap used to
    /// be enough, so a spot left straddling an edge, by a drag or by displays being
    /// rearranged, opened the panel mostly off screen on every dictation. The setting
    /// itself is left alone, so the spot comes back if the old arrangement does.
    private func position(_ panel: NSPanel?) {
        guard let panel else { return }

        if let x = settings.overlayOriginX, let y = settings.overlayOriginY {
            let saved = NSRect(x: x, y: y, width: Self.width, height: Self.minimumHeight)
            func overlap(_ screen: NSScreen) -> CGFloat {
                let shared = screen.frame.intersection(saved)
                return shared.width * shared.height
            }
            if let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }),
               overlap(screen) > 0 {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: min(max(x, visible.minX), visible.maxX - Self.width),
                    y: min(max(y, visible.minY), visible.maxY - Self.minimumHeight)
                ))
                return
            }
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 90
        ))
    }
}

/// Drags the panel from anywhere inside it.
///
/// `performDrag` hands the drag to the window server and returns before the panel has
/// moved, so the end of the drag is left to `PanelDragWatcher`.
private final class DragHandleView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Text the overlay is showing.
@MainActor
@Observable
final class OverlayModel {
    var text = ""

    /// Set while the panel reports how a dictation ended, in place of live words.
    var outcome: OverlayOutcome?
    var isProcessing = false
    /// The AI's rewrite as far as it has got, shown in place of the dictated words.
    var rewrite = ""
    /// Loudness per frequency band, 0 to 1, low to high — one per bar.
    var spectrum: [Double] = []

    /// How tall the text lays itself out in full, before the cap below clips it. It is
    /// what sizes the panel.
    var textHeight: CGFloat = 0

    /// Handed in by the controller so a new measurement resizes the panel.
    var resizePanel: () -> Void = {}

    /// How tall the text may grow before older lines are pushed off the top: the text
    /// room in the tallest panel the screen's visible height can hold.
    var maxTextHeight: CGFloat = DictationOverlayView.lineHeight * 5
}

// MARK: - View

private struct DictationOverlayView: View {
    @Bindable var model: OverlayModel

    /// One line of the text style actually in use, so everything below follows the
    /// system font size rather than a number that happens to look right today.
    static let lineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .title3)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: DictationOverlayController.contentSpacing) {
            ListeningBar(spectrum: model.spectrum, isProcessing: model.isProcessing)

            if let outcome = model.outcome {
                Label(outcome.headline, systemImage: outcome.symbol)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.lineHeight)
            }

            // Clipped to the newest lines rather than truncated.
            //
            // `lineLimit` with head truncation keeps the first lines and puts the
            // ellipsis inside the last, so a long dictation showed its opening and hid
            // the words being spoken. Letting the text take its full height inside a
            // bottom-aligned frame pushes the old lines off the top instead, which is
            // the way round you need while you are still talking.
            Text(displayText)
                .font(.title3)
                .foregroundStyle(isDimmed ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Measured at its full height, above the cap. The capped frame once
                // filled whatever height the panel offered it, so measured below the
                // cap the text reported the panel's own height back instead of its own.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    model.textHeight = height
                    model.resizePanel()
                }
                .frame(maxHeight: model.maxTextHeight, alignment: .bottom)
                // As tall as the text up to the cap, and no taller. The panel does not
                // shrink to follow the text, and a frame filling a panel held tall drew
                // short text along its bottom under a blank gap, so each new line
                // pushed the earlier ones up.
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, DictationOverlayController.verticalPadding / 2)
        .frame(width: DictationOverlayController.width)
        // Fills the panel, with the contents at its top: the room the text does not
        // need lies below the words, not between them and the band.
        .frame(
            minHeight: DictationOverlayController.minimumHeight,
            maxHeight: .infinity,
            alignment: .top
        )
        // No background here, and no color scheme. The glass is an NSGlassEffectView
        // behind this view, and the words and the ribbon follow the system appearance
        // as the glass does: dark on a light pane, light on a dark one.
    }

    /// The dictation stays up, dimmed, until the rewrite starts replacing it.
    ///
    /// Swapping it for "Processing…" on release hid the words at the moment the user
    /// wants to check them, to say what the band's amber already says.
    private var displayText: String {
        if model.outcome != nil { return model.text }
        if model.isProcessing, !model.rewrite.isEmpty { return model.rewrite }
        if !model.text.isEmpty { return model.text }
        return model.isProcessing ? "Processing…" : "Listening…"
    }

    /// A placeholder, or a dictation waiting for its rewrite, is drawn dimmed.
    private var isDimmed: Bool {
        if model.outcome != nil { return true }
        return model.isProcessing ? model.rewrite.isEmpty : model.text.isEmpty
    }
}

#endif
