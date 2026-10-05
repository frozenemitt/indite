import AppKit
import os

/// Puts Nscribe in the Dock and the Command-Tab switcher while one of its windows is
/// open, and keeps it to the menu bar the rest of the time.
///
/// Info.plist starts the app as a menu bar app (`LSUIElement`). Left that way, the
/// Meetings window would have no Dock icon and no place in Command-Tab to come back
/// by, and no window would have the Edit menu that copy, paste and undo run through,
/// since a menu bar app shows no menus of its own. Settings, Meetings, Recent
/// Dictations, the welcome window and Sparkle's update window all count. The
/// dictation panel and the meeting pill are panels, and do not.
@MainActor
enum DockPresence {
    static func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
        // Decided a moment after the close, not at it. Sparkle closes its "Checking…"
        // window and opens the update window 18 ms later. Deciding at the close made
        // Nscribe a menu bar app for those 18 ms, macOS moved it out of the front, and
        // the update window opened behind the app the user was in.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { update() }
            }
        }
    }

    private static func update() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        Log.app.notice("Activation policy \(hasWindow ? "regular" : "accessory", privacy: .public)")
    }
}
