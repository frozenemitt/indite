import SwiftUI

#if os(macOS)
import AppKit

/// A small panel that stays on screen for the length of a meeting.
///
/// A meeting runs for an hour with nothing to show it is still listening. The
/// menu bar icon changes shape, which tells you a meeting is open, not that the
/// microphone is still hearing anything — and the difference between those two only
/// becomes apparent when you play the recording back.
///
/// Deliberately small and mute: the band, the clock, Pause and Stop. A dictation
/// panel is worth reading for the twenty seconds it exists; this one has to be
/// bearable for an hour.
@MainActor
final class MeetingIndicatorController {

    private var panel: NSPanel?
    private let model = MeetingIndicatorModel()
    private let settings: AppSettings
    /// Saves where the user drops the current panel. Replaced with the panel.
    private var dragWatcher: PanelDragWatcher?
    /// Held so the desktop-change notifications keep arriving for the life of the app.
    private var spaceObserver: (any NSObjectProtocol)?
    /// Held so the display-change notifications keep arriving for the life of the app.
    private var screenObserver: (any NSObjectProtocol)?

    /// What the panel's two buttons do. Set by whoever owns the meeting.
    var onPauseOrResume: (() -> Void)?
    var onStop: (() -> Void)?

    static let width: CGFloat = 232
    /// The band, and a row of controls 30 points tall. At 20 points the two buttons
    /// were the smallest targets in the app, on the panel reached for mid-call.
    static let height: CGFloat = 76

    /// Visible over full-screen apps and on every desktop: a meeting is usually a
    /// full-screen call, and that is exactly when the indicator is wanted.
    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        // Same reasoning as the dictation panel: a panel the window server has taken
        // off the other desktops is thrown away and rebuilt, because saying
        // `collectionBehavior` again never reaches the window server.
        if panel == nil || panel?.isOnActiveSpace == false {
            replacePanel()
        }
        watchForStranding()
        followScreenChanges()
        position(panel)
        panel?.orderFrontRegardless()
    }

    /// Put an open panel back where it would open whenever a display comes or goes.
    ///
    /// The panel is up for the whole meeting, so a display unplugged mid-call is the
    /// usual case, not a rare one. macOS carries a window off a removed display to the
    /// same distance from the bottom of another one, and does not bring it back onto
    /// that display's screen. Measured: this panel's default spot at the top of a
    /// 1440-point display landed above the top edge of the laptop's 1329-point screen,
    /// on no screen at all, for the rest of the meeting. Nor does macOS return it when
    /// the display is plugged back in. It now goes where the user left it, or to the
    /// top right if that spot is gone.
    private func followScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel)
            }
        }
    }

    func update(
        spectrum: [Double],
        seconds: TimeInterval,
        isPaused: Bool,
        canPauseOrResume: Bool,
        microphoneHeldReason: String?,
        error: String?
    ) {
        model.spectrum = spectrum
        model.isPaused = isPaused
        model.canPauseOrResume = canPauseOrResume
        model.microphoneHeldReason = microphoneHeldReason
        model.seconds = seconds
        model.error = error
    }

    func hide() {
        panel?.orderOut(nil)
        model.spectrum = []
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
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
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = Self.collectionBehavior
        // The user is in the call, and this panel never activates Nscribe, so Nscribe
        // is inactive whenever the panel is on screen. AppKit hides an inactive app's
        // tooltips by default, which left the error mark with nothing to say.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        // Stays up when Nscribe is hidden. The recorder shows the panel once per
        // meeting, so a panel hidden with the app did not come back until the next one.
        panel.canHide = false

        model.pauseOrResume = { [weak self] in self?.onPauseOrResume?() }
        model.stop = { [weak self] in self?.onStop?() }

        let hosting = NSHostingView(rootView: MeetingIndicatorView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        // Apple's Regular glass, as on the dictation panel, following light and dark.
        glass.style = .regular
        glass.cornerRadius = Self.height / 2

        let container = NSView()
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

        // Remembered only when the user drags it. Every move used to be saved, so a
        // spot `position` pulled out from under the menu bar or the Dock was written
        // over the one the user chose.
        dragWatcher = PanelDragWatcher(panel: panel) { [weak self] frame in
            self?.settings.meetingIndicatorOriginX = frame.origin.x
            self?.settings.meetingIndicatorOriginY = frame.origin.y
        }

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
    /// show() runs once per meeting, so a panel taken off the other desktops after the
    /// meeting began would stay off them for the rest of the hour, with nothing on
    /// screen saying the microphone is still hearing anything. A desktop change is the
    /// moment that reveals it: a panel on every desktop is on the one the user just
    /// moved to, whichever that is, so `isOnActiveSpace` is false only for a panel
    /// that has been stranded. A healthy panel is left alone and nothing blinks.
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
                self.panel?.orderFrontRegardless()
            }
        }
    }

    /// Where the user left it, or the top right — out of the way of the thing the
    /// meeting is actually about.
    ///
    /// A spot lying wholly on a screen comes back where the user put it, beside the Dock
    /// included, and is only pulled down from under the menu bar. That is how macOS
    /// places windows. Keeping the panel out of the Dock's strip moved it up by the
    /// Dock's height at every meeting, because the usable area leaves out the whole
    /// strip and not only the icons. The cost, accepted: a spot saved during a
    /// full-screen call, when the Dock was hidden, can reopen under the Dock's icons.
    ///
    /// A spot straddling an edge, left by displays being rearranged, is pulled inside
    /// the usable area of the screen it mostly lies on. Any overlap used to be enough,
    /// and such a spot opened the panel mostly off screen. Only a drag is saved, so
    /// neither correction replaces the spot the user chose.
    private func position(_ panel: NSPanel?) {
        guard let panel else { return }

        if let x = settings.meetingIndicatorOriginX, let y = settings.meetingIndicatorOriginY {
            let saved = NSRect(x: x, y: y, width: Self.width, height: Self.height)
            func overlap(_ screen: NSScreen) -> CGFloat {
                let shared = screen.frame.intersection(saved)
                return shared.width * shared.height
            }
            if let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }),
               overlap(screen) > 0 {
                let visible = screen.visibleFrame
                if screen.frame.contains(saved) {
                    panel.setFrameOrigin(NSPoint(x: x, y: min(y, visible.maxY - Self.height)))
                } else {
                    panel.setFrameOrigin(NSPoint(
                        x: min(max(x, visible.minX), visible.maxX - Self.width),
                        y: min(max(y, visible.minY), visible.maxY - Self.height)
                    ))
                }
                return
            }
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - Self.width - 24,
            y: frame.maxY - Self.height - 24
        ))
    }
}

@MainActor
@Observable
final class MeetingIndicatorModel {
    var spectrum: [Double] = []
    var isPaused = false
    /// False while a pause or resume could not act: a dictation or a shortcut recorded
    /// during the pause holds the microphone, and a resume then fails.
    var canPauseOrResume = true
    /// Who holds the microphone while Resume is unavailable, when that is a dictation
    /// or a shortcut. Nil during the meeting's own resume, so the button keeps its name.
    var microphoneHeldReason: String?
    var seconds: TimeInterval = 0

    /// What has gone wrong in the meeting, if anything. The panel is often the only
    /// part of Nscribe on screen during a call, so a problem has to show here too.
    var error: String?

    /// Handed in by the controller so the buttons can reach the meeting.
    var pauseOrResume: () -> Void = {}
    var stop: () -> Void = {}
}

private struct MeetingIndicatorView: View {
    @Bindable var model: MeetingIndicatorModel

    /// True for a few seconds after a click on Stop, while the panel asks.
    ///
    /// Stop ends and saves the meeting, and an ended meeting cannot be resumed. It
    /// used to do that on one click, on a target 24 points wide, 10 points from Pause.
    @State private var isConfirmingStop = false
    @State private var confirmTimeout: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            ListeningBar(spectrum: model.spectrum, isProcessing: false)
                // Everything that is not a button lets the click through to the window,
                // which is what drags the panel. SwiftUI content swallowing the mouse
                // is why the dictation panel needed a drag view underneath it.
                .allowsHitTesting(false)

            if isConfirmingStop {
                confirmation
            } else {
                controls
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: MeetingIndicatorController.width, height: MeetingIndicatorController.height)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .font(.caption)
                .foregroundStyle(model.isPaused ? Color.orange : Color.red)

            Text(MeetingExporter.durationLabel(model.seconds))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)

            // A mark rather than the message: the panel is too small to hold one.
            // The words are in its tooltip and in the meeting window.
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(error)
            }

            Spacer(minLength: 0)

            // Labels rather than bare images, so VoiceOver reads the action and not
            // the symbol's name.
            Button(action: model.pauseOrResume) {
                Label(model.isPaused ? "Resume" : "Pause",
                      systemImage: model.isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.primary.opacity(0.12)))
                    .contentShape(Circle())
            }
            .disabled(!model.canPauseOrResume)
            .help(model.microphoneHeldReason ?? (model.isPaused ? "Resume" : "Pause"))

            Button {
                askToStop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.red.opacity(0.85)))
                    .contentShape(Circle())
            }
            .help("End and save the meeting")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.primary)
    }

    /// Asked in the panel itself, and the meeting goes on recording while it asks. A
    /// dialog would bring Nscribe forward over the call.
    private var confirmation: some View {
        HStack(spacing: 8) {
            Text("End meeting?")
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("Cancel") {
                stopAsking()
            }
            .buttonStyle(PillButtonStyle(fill: .primary.opacity(0.12), label: .primary))

            Button("End") {
                stopAsking()
                model.stop()
            }
            .buttonStyle(PillButtonStyle(fill: Color.red.opacity(0.85), label: .white))
        }
    }

    private func askToStop() {
        isConfirmingStop = true
        // Left alone, the question goes away. A panel still asking ten minutes later
        // would end the meeting on the next stray click.
        confirmTimeout?.cancel()
        confirmTimeout = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isConfirmingStop = false
        }
    }

    private func stopAsking() {
        confirmTimeout?.cancel()
        isConfirmingStop = false
    }
}

/// A capsule button for the pill's two answers, 30 points tall like its round ones.
private struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(label)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
#endif
