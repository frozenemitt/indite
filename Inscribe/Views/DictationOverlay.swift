import SwiftUI

#if os(macOS)
import AppKit

/// A floating panel showing what Inscribe is hearing, while you hold the key.
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

    /// The pane behind the content, faded on its own so the words stay readable.
    private var glassView: NSGlassEffectView?

    private let model = OverlayModel()
    private let settings: AppSettings
    /// Held so the desktop-change notifications keep arriving for the life of the app.
    private var spaceObserver: (any NSObjectProtocol)?

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
        model.text = ""
        model.rewrite = ""
        model.isProcessing = false
        model.spectrum = []

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

        // Back to one line's worth, so each dictation grows from the same place.
        // `position` below puts it back where the user left it.
        if let panel, panel.frame.height != Self.minimumHeight {
            var frame = panel.frame
            frame.size.height = Self.minimumHeight
            panel.setFrame(frame, display: false)
        }

        position(panel)
        applyOpacity()
        applyContentOpacity()
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key status would pull
        // focus out of the app being dictated into, which is where the text must land.
        panel?.orderFrontRegardless()
    }

    func update(text: String, spectrum: [Double]) {
        model.spectrum = spectrum
        applyOpacity()
        applyContentOpacity()

        // Only when it changed: the band wants twenty updates a second, and laying out
        // a panel-tall block of text that often to say the same words is waste.
        guard model.text != text else { return }
        model.text = text
    }

    /// Fade the whole panel, glass included.
    ///
    /// The pane thins; the words do not.
    ///
    /// Three ways to do this and only one of them works. Tint only darkens the
    /// material, so nothing showed through at any setting. The window's alpha thins
    /// everything including the text, which defeats the panel. Fading the glass view
    /// alone is the answer, and it needs the content to be a sibling drawn on top of
    /// the glass rather than living inside it — a view's alpha takes its subviews
    /// with it.
    ///
    /// The tint itself is set once when the panel is built. Assigning it twenty times
    /// a second makes the material recomposite on every tick and the panel goes
    /// muddy.
    private func applyOpacity() {
        let wanted = settings.overlayOpacity

        // The rim is checked on its own. It starts from a different default than the
        // glass, so a pane set fully solid matched the glass, returned early, and left
        // the rim at three quarters.
        if abs(model.paneOpacity - wanted) > 0.001 {
            model.paneOpacity = wanted
        }

        guard let glassView, abs(glassView.alphaValue - wanted) > 0.001 else { return }
        glassView.alphaValue = wanted
    }

    /// The words and the band carry their own setting, so a pane turned right down can
    /// still hold solid text, or a solid pane can hold text that stays out of the way.
    private func applyContentOpacity() {
        let wanted = settings.overlayContentOpacity
        guard abs(model.contentOpacity - wanted) > 0.001 else { return }
        model.contentOpacity = wanted
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
        panel?.orderOut(nil)
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
        let chrome = Self.bandHeight + Self.contentSpacing + Self.verticalPadding
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
        let chrome = Self.bandHeight + Self.contentSpacing + Self.verticalPadding
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
        // Stays up when Inscribe is hidden, which would otherwise take the panel away
        // in the middle of a dictation.
        panel.canHide = false

        // The SwiftUI content swallows the mouse, so `isMovableByWindowBackground`
        // never sees a click and the panel could not be dragged at all. This view sits
        // under the content, takes every hit, and drags the window itself. Safe
        // because the panel is display-only: there is nothing in it to click.
        let hosting = NSHostingView(rootView: DictationOverlayView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The glass the panel is made of. AppKit's own view rather than SwiftUI's
        // modifier: this one samples the windows behind the panel, which is where the
        // lensing comes from and what the SwiftUI version had no access to inside a
        // borderless transparent panel.
        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        // Clear rather than regular: the regular style is mostly frost, and frost is
        // what hides the refraction. Clear blurs far less and lets the edge bend what
        // is behind it, which is the part that reads as glass rather than as fog.
        glass.style = .clear
        // Refraction in Liquid Glass lives in the rim, not the interior, so a curve
        // this gentle put almost none of the panel inside it. A larger radius gives
        // the effect somewhere to happen.
        glass.cornerRadius = 26
        // Set once. Reassigning it per frame makes the material recomposite and the
        // panel darkens as it goes.
        glass.tintColor = NSColor.black.withAlphaComponent(0.22)
        self.glassView = glass

        // The content sits on top of the glass rather than inside it. As the glass
        // view's `contentView` it would inherit the glass's alpha, and thinning the
        // pane would thin the dictation with it.
        let container = DragHandleView()
        // Remembered only when the user drags it. Every programmatic move used to be
        // saved too, so placing the panel on the screen with the pointer pinned it to
        // that screen for good, and each resize nudged the saved spot upward.
        container.onDragEnded = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.settings.overlayOriginX = panel.frame.origin.x
            // Saved as the spot a one-line panel would take with the same top edge,
            // since the top is what stays put. A panel dragged while grown tall
            // otherwise came back that much lower.
            self.settings.overlayOriginY = panel.frame.maxY - Self.minimumHeight
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
                self.applyOpacity()
                self.applyContentOpacity()
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
private final class DragHandleView: NSView {
    /// Called once a drag the user made has finished.
    var onDragEnded: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        // A click that moves nothing is not a drag. Saving on every mouse-up turned a
        // stray click into a chosen spot and pinned the panel to that screen. The
        // pointer is compared rather than the frame, because the panel keeps growing
        // under a held click, and once it reaches the bottom of the screen it grows
        // upward and moves every corner.
        let before = NSEvent.mouseLocation
        // Runs the whole drag before returning.
        window.performDrag(with: event)
        if NSEvent.mouseLocation != before {
            onDragEnded?()
        }
    }
}

/// Text the overlay is showing.
@MainActor
@Observable
final class OverlayModel {
    var text = ""
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

    /// How solid the pane behind is, so the rim drawn on top can match it.
    var paneOpacity: Double = 0.75

    /// How solid the words and the band are.
    var contentOpacity: Double = 1.0

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
        // The contents carry their own setting; the rim below belongs to the pane and
        // takes the pane's.
        .opacity(model.contentOpacity)
        .padding(.horizontal, 18)
        .padding(.vertical, DictationOverlayController.verticalPadding / 2)
        .frame(width: DictationOverlayController.width)
        // Fills the panel, with the contents at its top: the room the text does not
        // need lies below the words, not between them and the band. Filling it also
        // keeps the rim below on the panel's edge, where the glass ends.
        .frame(
            minHeight: DictationOverlayController.minimumHeight,
            maxHeight: .infinity,
            alignment: .top
        )
        // No background here. The glass is an NSGlassEffectView behind this view.
        //
        // The rim is drawn rather than sampled: a light edge, brightest where a light
        // above and to the left would catch it, fading around the curve. That is the
        // specular highlight the material renders faintly on a shape this large, and
        // drawing it is the honest way to get the read at this size.
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.55),
                            .white.opacity(0.12),
                            .white.opacity(0.04),
                            .white.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                // The rim is the pane's edge, so it thins with the pane. Left solid it
                // outlines a panel that is no longer there.
                .opacity(model.paneOpacity)
        )
        // Rendered dark throughout, so the text comes out light and the glass picks
        // its dark treatment, rather than each part being told separately.
        .environment(\.colorScheme, .dark)
    }

    /// The dictation stays up, dimmed, until the rewrite starts replacing it.
    ///
    /// Swapping it for "Processing…" on release hid the words at the moment the user
    /// wants to check them, to say what the band's amber already says.
    private var displayText: String {
        if model.isProcessing, !model.rewrite.isEmpty { return model.rewrite }
        if !model.text.isEmpty { return model.text }
        return model.isProcessing ? "Processing…" : "Listening…"
    }

    /// A placeholder, or a dictation waiting for its rewrite, is drawn dimmed.
    private var isDimmed: Bool {
        model.isProcessing ? model.rewrite.isEmpty : model.text.isEmpty
    }
}

#endif
