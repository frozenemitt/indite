#if os(macOS)
import AppKit

/// Tells a floating panel where the user dropped it, and about no other move.
///
/// Where a panel sits is the user's to choose, so only a drag is saved. Every other
/// move belongs to the app or to macOS: placing the panel, growing it, pulling it out
/// from under the menu bar, or carrying it off a display that was unplugged. Saving
/// those wrote over the spot the user chose.
///
/// Both ends of a drag were measured on copies of the two panels. AppKit sends
/// `willMove` when the user starts dragging, and for nothing else: not for
/// `setFrameOrigin`, not for a resize, not when macOS moves the panel off a removed
/// display or out of a display whose resolution shrank. The drag ends with the mouse
/// release, which reaches the app after the panel's last move.
///
/// The panels used to guess the end instead, and both guessed wrong. The dictation
/// panel saved when `performDrag` returned, which it does before the drag begins, so
/// no drag was ever saved. The meeting panel took the first move made with the button
/// up as the end, and the last move of a drag often arrives with the button still down.
@MainActor
final class PanelDragWatcher {
    /// Set when the user starts dragging the panel, cleared when they let go.
    private var isDragging = false

    // deinit is nonisolated and has to remove both, so the opt-out sits on the
    // properties rather than the whole class.
    nonisolated(unsafe) private var moveObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var releaseMonitor: Any?

    /// `onDrop` is handed the panel's frame where the user let go.
    init(panel: NSPanel, onDrop: @escaping @MainActor (NSRect) -> Void) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isDragging = true
            }
        }
        // A release on another window is a click somewhere else in the app, and a
        // release on this panel with no drag before it is a click on one of its buttons.
        releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) {
            [weak self, weak panel] event in
            MainActor.assumeIsolated {
                guard let self, let panel, self.isDragging, event.window === panel else { return }
                self.isDragging = false
                onDrop(panel.frame)
            }
            return event
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
    }
}
#endif
