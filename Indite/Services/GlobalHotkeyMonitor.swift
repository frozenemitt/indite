import Foundation
import Observation

#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import os
import OSLog

/// How a hotkey starts and stops a recording.
enum HotkeyActivationMode: String, CaseIterable, Identifiable, Sendable {
    /// Hold the key to record, release to transcribe. Two quick taps keep it
    /// recording until the next press.
    case pushToTalk
    /// Press once to start, press again to stop.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk: "Hold to talk, double-tap to keep listening"
        case .toggle: "Press to start, press to stop"
        }
    }
}

/// The Option key that dictates, pressed on its own.
enum OptionKey: String, CaseIterable, Identifiable, Sendable {
    case left, right, either

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: "Left Option"
        case .right: "Right Option"
        case .either: "Either Option key"
        }
    }

    /// The key in a sentence: "Hold the right Option key to dictate."
    var phrase: String {
        switch self {
        case .left: "the left Option key"
        case .right: "the right Option key"
        case .either: "either Option key"
        }
    }

    /// How the key reads on a key cap.
    var symbol: String {
        switch self {
        case .left: "Left ⌥"
        case .right: "Right ⌥"
        case .either: "⌥"
        }
    }

    func matches(_ keyCode: CGKeyCode) -> Bool {
        switch self {
        case .left: keyCode == leftOptionKeyCode
        case .right: keyCode == rightOptionKeyCode
        case .either: keyCode == leftOptionKeyCode || keyCode == rightOptionKeyCode
        }
    }
}

/// A mouse side button that dictates. A click starts a dictation, and the next click
/// ends it and delivers the words, as the next press ends a locked recording.
enum MouseButton: String, CaseIterable, Identifiable, Sendable {
    case back, forward

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .back: "Back (button 4)"
        case .forward: "Forward (button 5)"
        }
    }

    /// The button's number in a mouse event, which counts the left button as 0, the
    /// right as 1 and the middle as 2.
    var eventNumber: Int64 {
        switch self {
        case .back: 3
        case .forward: 4
        }
    }
}

/// A key plus modifiers, e.g. ⌃⌥⌘Z: the undo and type-again shortcuts.
struct HotkeyTrigger: Equatable, Sendable {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
}

private let leftOptionKeyCode = CGKeyCode(kVK_Option)
private let rightOptionKeyCode = CGKeyCode(kVK_RightOption)
private let escapeKeyCode = CGKeyCode(kVK_Escape)

/// The bits in an event's flags that say which Option key is down. The shared
/// `.maskAlternate` stays set while either is held, so it cannot tell a release of one
/// from the other.
private let leftOptionDeviceBit: UInt64 = 0x20   // NX_DEVICELALTKEYMASK
private let rightOptionDeviceBit: UInt64 = 0x40  // NX_DEVICERALTKEYMASK

private func optionIsDown(_ keyCode: CGKeyCode, in flags: CGEventFlags) -> Bool {
    let bit = keyCode == leftOptionKeyCode ? leftOptionDeviceBit : rightOptionDeviceBit
    return flags.rawValue & bit != 0
}

/// Modifiers that make an Option press part of a shortcut rather than a dictation.
private let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]

/// Modifier bits we compare against, ignoring caps lock and device-specific noise.
private let relevantModifiers: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift
]

/// What a tapped keystroke turned out to mean.
private enum HotkeyAction: Sendable {
    case activate, deactivate, toggle, cancel, undo, retype
    /// A hold-to-talk press came up too soon to be a dictation. Dropped quietly unless
    /// a second press follows and makes it the start of a lock.
    case tap
    /// Two quick taps: the recording goes on until the next press.
    case lock
    /// A hold-to-talk press has turned out to be a dictation: held past a tap, or the
    /// second press of a double tap. Until then it records without a sound or a panel.
    case confirm
    /// The Option key turned out to be a modifier for another key or a click, so the
    /// recording it started was never meant. Cancelled without the stop sound.
    case abandon
    /// The settings screen is waiting for a new binding, and this was the keystroke.
    case capture(keyCode: CGKeyCode, modifiers: CGEventFlags)
}

/// Everything the tap callback reads, kept where the tap's own thread can reach it.
private struct TapState: Sendable {
    var dictationKey: OptionKey = .right
    /// The mouse side button that dictates, if one does.
    var mouseButton: MouseButton?
    /// The number of the mouse button whose press was swallowed, so that its release
    /// is swallowed too and no app sees half a click.
    var swallowedButton: Int64?
    var undoTrigger: HotkeyTrigger?
    var retypeTrigger: HotkeyTrigger?
    var activationMode: HotkeyActivationMode = .pushToTalk
    var isRecording = false
    /// The Option key held down as the dictation key, left or right.
    var heldKey: CGKeyCode?
    var isKeyDown: Bool { heldKey != nil }
    var isCapturing = false
    /// Another key, modifier or click came while Option was held: ⌥E, ⌥Tab, ⌥⌘,
    /// Option-drag. The release that follows must not act as a dictation's release.
    var optionUsedAsModifier = false
    /// Whether this press started a recording rather than stopped one. Only a start
    /// can be taken back when the press turns out to be a modifier.
    var pressStartedRecording = false

    // Hold to talk, with double-tap to lock.

    /// When the trigger last went down.
    var pressedAt: ContinuousClock.Instant?
    /// A short tap came up and its recording is still running, waiting to see whether
    /// a second press follows. Cleared by that press, or by the main actor when the
    /// wait runs out, whichever takes the lock first.
    var tapPending = false
    /// This press followed a short tap. Released quickly, it locks the recording.
    var isSecondTap = false
    /// The recording is locked on, and the next press ends it.
    var isLocked = false
    /// This press ended a locked recording, so its release does nothing.
    var pressEndsLock = false

    /// Shorter than this, a hold is a tap: too short to have said anything after the
    /// start sound. Also how long a tap waits for the second press of a double tap.
    static let tapLength: Duration = .milliseconds(300)

    /// A press of the dictation key, as the current mode reads it.
    mutating func press(at now: ContinuousClock.Instant) -> HotkeyAction? {
        // Toggle mode acts on the release, once the press is known not to be ⌥E or
        // Option-drag. Acting on the press started and stopped recordings in the
        // middle of typing.
        guard activationMode == .pushToTalk else {
            pressStartedRecording = false
            return nil
        }
        pressedAt = now
        pressStartedRecording = true
        if isLocked {
            isLocked = false
            pressEndsLock = true
            pressStartedRecording = false
            return .deactivate
        }
        // The first tap's recording is still running, so this press carries it on
        // rather than starting another.
        if tapPending {
            tapPending = false
            isSecondTap = true
            return .confirm
        }
        return .activate
    }

    /// A release of the dictation key, as the current mode reads it.
    mutating func release(at now: ContinuousClock.Instant) -> HotkeyAction? {
        guard activationMode == .pushToTalk else { return .toggle }
        if pressEndsLock {
            pressEndsLock = false
            return nil
        }
        let wasTap = pressedAt.map { now - $0 < Self.tapLength } ?? false
        if isSecondTap {
            isSecondTap = false
            if wasTap {
                isLocked = true
                return .lock
            }
            return .deactivate
        }
        if wasTap {
            tapPending = true
            return .tap
        }
        return .deactivate
    }

    /// Another key, modifier or click arrived while Option was held, so Option is a
    /// modifier, and the recording its press began was never meant. A press that
    /// stopped a recording has already delivered it, so there is nothing to take back.
    mutating func useAsModifier() -> HotkeyAction? {
        guard !optionUsedAsModifier else { return nil }
        optionUsedAsModifier = true
        return pressStartedRecording ? .abandon : nil
    }

    /// The press turned out to be a modifier for another key, and its release means
    /// nothing. Whatever gesture it was part of is over.
    mutating func releaseAsModifier() {
        optionUsedAsModifier = false
        isSecondTap = false
        pressEndsLock = false
    }
}

/// System-wide hotkey monitor built on a CGEventTap.
///
/// Carbon's `RegisterEventHotKey` cannot bind a modifier key on its own and gives no
/// key-up callback, so it supports neither of the two things we need. An event tap
/// sees the raw `.flagsChanged` stream, which carries both.
///
/// Requires Accessibility trust — `CGEvent.tapCreate` returns nil without it.
///
/// `Log.hotkey` says whether the tap exists, whether it is enabled, and whether macOS
/// switched it off. No keystroke is ever written there.
@MainActor
@Observable
final class GlobalHotkeyMonitor {

    // MARK: - Observable State

    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Whether a start was tried and did not take.
    ///
    /// Not simply `!isRunning`, which is also true for the moment between launch and
    /// the first start, when nothing is wrong.
    var hasFailed: Bool { !isRunning && lastError != nil }

    // MARK: - Configuration

    /// The Option key that dictates.
    var dictationKey: OptionKey = .right {
        didSet {
            let value = dictationKey
            tapState.withLock { $0.dictationKey = value }
        }
    }

    /// Hold-to-talk or press-to-toggle.
    var activationMode: HotkeyActivationMode = .pushToTalk {
        didSet {
            let value = activationMode
            tapState.withLock { $0.activationMode = value }
        }
    }

    /// The mouse side button that starts and stops a dictation, or nil for none.
    var mouseButton: MouseButton? {
        didSet {
            let value = mouseButton
            tapState.withLock { $0.mouseButton = value }
        }
    }

    /// Optional second binding that takes back the last insertion.
    var undoTrigger: HotkeyTrigger? {
        didSet {
            let value = undoTrigger
            tapState.withLock { $0.undoTrigger = value }
        }
    }

    /// Optional third binding that types the last dictation again, at the cursor.
    var retypeTrigger: HotkeyTrigger? {
        didSet {
            let value = retypeTrigger
            tapState.withLock { $0.retypeTrigger = value }
        }
    }

    /// Whether a dictation is running, which is the only time Escape should cancel.
    ///
    /// Pushed in rather than pulled: the tap answers on its own thread, and asking the
    /// main actor at keystroke time is exactly the wait this class exists to avoid.
    var isRecording = false {
        didSet {
            let value = isRecording
            tapState.withLock { state in
                state.isRecording = value
                // Ended some other way — Escape, the time limit, the menu — so a lock
                // or a waiting tap has nothing left to act on.
                if !value {
                    state.isLocked = false
                    state.tapPending = false
                    state.isSecondTap = false
                }
            }
        }
    }

    // MARK: - Callbacks

    /// Recording should begin.
    var onActivate: (() -> Void)?
    /// The recording that began is a dictation, not a tap, and can show itself.
    /// Push-to-talk only.
    var onConfirm: (() -> Void)?
    /// Two quick taps locked the recording on, and the next press ends it.
    /// Push-to-talk only.
    var onLock: (() -> Void)?
    /// Recording should end and transcribe. Push-to-talk only.
    var onDeactivate: (() -> Void)?
    /// Recording should flip state. In toggle mode from the dictation key, and in
    /// either mode from the mouse button.
    var onToggle: (() -> Void)?
    /// The user cancelled with Escape while recording.
    var onCancel: (() -> Void)?
    /// The undo shortcut was pressed.
    var onUndo: (() -> Void)?
    /// The last dictation should be typed again, where the cursor is now.
    var onRetype: (() -> Void)?
    /// A recording started by the Option key should be dropped quietly: the key was
    /// being used as a modifier.
    var onAbandon: (() -> Void)?
    /// A keystroke arrived while the settings screen was recording a new binding.
    var onCapture: ((CGKeyCode, CGEventFlags) -> Void)?

    // MARK: - Tap Internals

    /// Read and written on the tap's thread.
    ///
    /// Each setting above writes itself in as it changes, so `start()` has nothing to
    /// seed. It used to replace the whole state anyway. When Accessibility arrived
    /// during a capture and the tap was rebuilt, that ended the capture: the
    /// combination the user pressed next went to the app in front instead of into the
    /// settings screen.
    private let tapState = OSAllocatedUnfairLock(initialState: TapState())

    /// Carries decisions from the tap thread to the main actor in order.
    private let emit: AsyncStream<HotkeyAction>.Continuation

    @ObservationIgnored nonisolated(unsafe) private var pump: Task<Void, Never>?

    /// When the last release was acted on, so a press hard on its heels can be named
    /// for what it is.
    private var lastRelease: ContinuousClock.Instant?

    /// A press this soon after a release did not come from a human hand.
    private static let chatterWindow: Duration = .milliseconds(250)

    // deinit is nonisolated and has to tear the tap down, so this carries the
    // isolation opt-out rather than the whole class.
    @ObservationIgnored nonisolated(unsafe) private var host: TapHost?

    /// The tap port, kept separately from the host that runs it.
    ///
    /// macOS can switch a tap off in the same millisecond it is created, and the
    /// callback saying so arrives on the tap's own thread — which `TapHost.init`
    /// starts before returning, so `host` is still nil when it lands. Re-enabling
    /// through `host` dropped that first call and the tap stayed dead for the life of
    /// the app, while `isRunning` went on reporting it as listening.
    ///
    /// Read on the tap's thread and replaced on the main thread, so it lives behind a
    /// lock.
    private let tapPort = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)

    // MARK: - Lifecycle

    /// The one monitor in the process.
    ///
    /// `InditeApp` wires the launch callback inside its `init`, which captures a copy
    /// of the App struct — and a `@State` default built in that copy is not the
    /// instance SwiftUI installs. Launch armed one monitor while the menu bar and the
    /// Settings screen observed another, so the tap was created against an object
    /// nothing else could see, and every screen reported "Not listening" while the
    /// Globe key did nothing. One instance makes the two the same object.
    static let shared = GlobalHotkeyMonitor()

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyAction.self)
        emit = continuation
        pump = Task { @MainActor [weak self] in
            for await action in stream {
                self?.perform(action)
            }
        }
    }

    deinit {
        emit.finish()
        pump?.cancel()
        host?.invalidate()
        tapPort.withLockUnchecked { $0 = nil }
    }

    // MARK: - Public API

    /// Install the event tap. Returns false when Accessibility trust is missing.
    @discardableResult
    func start() -> Bool {
        stop()

        guard AccessibilityPermission.isTrusted else {
            lastError = "Accessibility access is required for the dictation key."
            isRunning = false
            Log.hotkey.error("not trusted, no tap")
            return false
        }

        // Clicks to notice Option-click and Option-drag, which are never swallowed, and
        // the side button that dictates, when one is chosen. That button's presses and
        // releases are swallowed.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lastError = "Could not create the event tap. Grant Accessibility access and try again."
            isRunning = false
            Log.hotkey.error("tapCreate returned nil")
            return false
        }

        // Assigned before the host exists, so the thread the host starts can always
        // find it.
        tapPort.withLockUnchecked { $0 = tap }
        let host = TapHost(tap: tap)
        self.host = host

        // A tap can be created and still never switch on — after a reinstall, the
        // Accessibility grant belongs to the old binary — and it then hears nothing.
        // This used to report "Listening" regardless, and since every retry only runs
        // when the monitor says it is not running, nothing ever rebuilt it.
        guard host.waitUntilEnabled() else {
            Log.hotkey.error("tap never switched on — Accessibility is probably not granted to this build")
            stop()
            lastError = "The dictation key could not switch on. In System Settings → Privacy & Security → Accessibility, remove Indite and add it again."
            return false
        }

        isRunning = true
        lastError = nil
        Log.hotkey.notice("tap installed, key=\(self.dictationKey.rawValue, privacy: .public), mode=\(self.activationMode.rawValue, privacy: .public), mouse=\(self.mouseButton?.rawValue ?? "off", privacy: .public)")
        return true
    }

    /// Remove the event tap.
    func stop() {
        host?.invalidate()
        host = nil
        tapPort.withLockUnchecked { $0 = nil }
        tapState.withLock { $0.heldKey = nil }
        isRunning = false
    }

    /// Report the next keystrokes to `handler` instead of acting on them, so the
    /// settings screen can record a new binding.
    ///
    /// Read from the tap rather than from an `NSEvent` monitor in the settings window:
    /// the tap sees every keystroke on the machine, so the user's chosen combination
    /// is captured whether or not that window happens to hold keyboard focus. Every
    /// keystroke is swallowed while this is on, so none of them leak into the app
    /// behind the settings window.
    func beginCapture(_ handler: @escaping (CGKeyCode, CGEventFlags) -> Void) {
        onCapture = handler
        if !isRunning { start() }
        tapState.withLock { $0.isCapturing = true }
    }

    /// Go back to treating keystrokes as hotkeys.
    func endCapture() {
        tapState.withLock { $0.isCapturing = false }
        onCapture = nil
    }

    // MARK: - Tap Thread

    /// Decide what a tapped keystroke means. Returns true when it should be swallowed.
    ///
    /// Runs on the tap's thread and touches nothing but the lock, so a busy main actor
    /// can never hold up a keystroke. Any resulting action is queued for the main actor.
    fileprivate nonisolated func decide(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool,
        button: Int64
    ) -> Bool {
        let (swallow, action) = tapState.withLock { state -> (Bool, HotkeyAction?) in
            // Recording a new binding takes the keyboard whole, so the combination the
            // user presses cannot also fire the old hotkey or type into another app.
            // Modifiers on their own pass through: they are the user still assembling
            // the combination, and Option must not start a recording here.
            if state.isCapturing {
                guard type == .keyDown, !isRepeat else { return (type == .keyDown, nil) }
                return (true, .capture(keyCode: keyCode, modifiers: flags))
            }

            switch type {
            case .flagsChanged:
                // Option always reaches the app, so ⌥E, ⌥-arrow and Option-click work as
                // they always have. The tap only watches it.
                if let held = state.heldKey {
                    if keyCode == held {
                        guard !optionIsDown(keyCode, in: flags) else { return (false, nil) }
                        state.heldKey = nil
                        if state.optionUsedAsModifier {
                            state.releaseAsModifier()
                            return (false, nil)
                        }
                        return (false, state.release(at: .now))
                    }
                    // ⇧, ⌘, ⌃, Fn or the other Option while it is held: a shortcut.
                    return (false, state.useAsModifier())
                }

                guard state.dictationKey.matches(keyCode), optionIsDown(keyCode, in: flags) else {
                    return (false, nil)
                }
                // Pressed on top of another modifier, it is part of a shortcut from the
                // start: ⌘⌥Esc, ⌃⌥⌘Z.
                guard flags.intersection(otherModifiers).isEmpty else { return (false, nil) }
                state.heldKey = keyCode
                state.optionUsedAsModifier = false
                return (false, state.press(at: .now))

            case .keyDown:
                // Escape abandons an in-flight recording without producing text.
                if keyCode == escapeKeyCode, state.isRecording { return (true, .cancel) }

                // Any other key while Option is held means Option is a modifier — ⌥E,
                // ⌥-arrow, ⌥Tab — and the recording its press started was never wanted.
                // The key itself goes through to the app untouched. A locked recording
                // is not held, so ⌘Tab and the rest reach it as ordinary keys.
                if state.isKeyDown, !state.optionUsedAsModifier {
                    return (false, state.useAsModifier())
                }

                // Checked before the record trigger so the two can never collide. The
                // auto-repeat of a held undo shortcut is swallowed with it; letting it
                // through sent the combination on to the app in front.
                if let undo = state.undoTrigger,
                   keyCode == undo.keyCode,
                   flags.intersection(relevantModifiers) == undo.modifiers.intersection(relevantModifiers) {
                    return (true, isRepeat ? nil : .undo)
                }

                if let retype = state.retypeTrigger,
                   keyCode == retype.keyCode,
                   flags.intersection(relevantModifiers) == retype.modifiers.intersection(relevantModifiers) {
                    return (true, isRepeat ? nil : .retype)
                }
                return (false, nil)

            case .otherMouseDown where button == state.mouseButton?.eventNumber:
                // The side button that dictates: a click starts a dictation and the
                // next one ends it. Swallowed, so the app in front does not also go
                // back or forward.
                state.swallowedButton = button
                return (true, .toggle)

            case .otherMouseUp:
                // The release of a swallowed press goes the same way as its press.
                guard button == state.swallowedButton else { return (false, nil) }
                state.swallowedButton = nil
                return (true, nil)

            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                // Option-click and Option-drag: Option is a modifier for the mouse.
                guard state.isKeyDown else { return (false, nil) }
                return (false, state.useAsModifier())

            default:
                return (false, nil)
            }
        }

        if let action { emit.yield(action) }
        return swallow
    }

    /// Re-enable a tap that macOS switched off.
    ///
    /// `.tapDisabledByUserInput` is routine. A timeout is not: it means the callback
    /// missed its deadline, and every keystroke queued behind it was dropped — so it
    /// gets said out loud rather than quietly patched over.
    fileprivate nonisolated func tapWasDisabled(byTimeout: Bool) {
        // A tap switched off by user input is routine; a timeout means the callback
        // missed its deadline and keystrokes were dropped, which is not.
        if byTimeout {
            Log.hotkey.error("tap disabled by TIMEOUT, re-enabling")
        } else {
            Log.hotkey.notice("tap disabled by user input, re-enabling")
        }
        guard let port = tapPort.withLockUnchecked({ $0 }) else {
            Log.hotkey.error("no tap port to re-enable")
            return
        }
        CGEvent.tapEnable(tap: port, enable: true)
        if !CGEvent.tapIsEnabled(tap: port) {
            Log.hotkey.error("tap would not switch back on")
        }

        // A release that happened while the tap was off never arrived, which left the
        // key marked as held: the next press was swallowed as a repeat, and the
        // recording ran on until the release after that. Ask the hardware instead.
        releaseIfKeyIsUp()
    }

    /// Send the release the tap missed, if the trigger key is no longer down.
    private nonisolated func releaseIfKeyIsUp() {
        guard let held = tapState.withLock({ $0.heldKey }),
              !CGEventSource.keyState(.combinedSessionState, key: held)
        else { return }

        let action = tapState.withLock { state -> HotkeyAction? in
            guard state.isKeyDown else { return nil }
            state.heldKey = nil
            if state.optionUsedAsModifier {
                state.releaseAsModifier()
                return nil
            }
            return state.release(at: .now)
        }
        if let action {
            Log.hotkey.notice("trigger key was released while the tap was off — releasing now")
            emit.yield(action)
        }
    }

    // MARK: - Main Actor

    /// Drop a short tap's recording once the wait for a second press runs out.
    ///
    /// The tap thread and this check share the lock, so a second press either claims
    /// the recording before the wait ends or finds it gone, never both.
    private func discardTapUnlessFollowed() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: TapState.tapLength)
            guard let self else { return }
            let unclaimed = tapState.withLock { state in
                defer { state.tapPending = false }
                return state.tapPending
            }
            guard unclaimed else { return }
            Log.hotkey.notice("key tapped, not held — recording discarded")
            onAbandon?()
        }
    }

    /// Show the recording once the key has been down longer than a tap. A tap, or an
    /// Option press that became ⌥E, never shows at all.
    private func confirmIfStillHeld() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: TapState.tapLength)
            guard let self else { return }
            let held = tapState.withLock { $0.isKeyDown && !$0.optionUsedAsModifier }
            if held { onConfirm?() }
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .activate:
            // Named, not acted on. The Globe key spent part of one morning sending a
            // release and another press every hundred and twenty milliseconds while
            // held, which ended each recording as fast as it could start — and looked
            // from outside exactly like the key doing nothing. Holding the release back
            // to defend against it cost a quarter of a second on every dictation, for a
            // fault that stopped on its own, so the defence is gone and only the
            // reading of it remains.
            if let lastRelease, ContinuousClock.now - lastRelease < Self.chatterWindow {
                Log.hotkey.error("a press followed a release within \(Self.chatterWindow, privacy: .public) — the dictation key is chattering")
            }
            onActivate?()
            confirmIfStillHeld()

        case .confirm:
            onConfirm?()

        case .deactivate:
            lastRelease = .now
            onDeactivate?()

        case .toggle:
            onToggle?()

        case .tap:
            lastRelease = .now
            discardTapUnlessFollowed()

        case .lock:
            Log.hotkey.notice("double tap — recording locked until the next press")
            onLock?()

        case .cancel: onCancel?()
        case .abandon: onAbandon?()
        case .undo: onUndo?()
        case .retype: onRetype?()
        case let .capture(keyCode, modifiers): onCapture?(keyCode, modifiers)
        }
    }
}


// MARK: - Tap Thread Host

/// Owns the tap and the thread it runs on.
///
/// The tap must not share a run loop with anything that can block. On the main run
/// loop one synchronous SwiftData save is enough to push the callback past the system's
/// deadline, at which point macOS drops the keystrokes queued behind it and switches
/// the tap off — for every app on the machine, not just this one.
private final class TapHost: @unchecked Sendable {
    private let tap: CFMachPort
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var enabled = false
    private let ready = DispatchSemaphore(value: 0)

    init(tap: CFMachPort) {
        self.tap = tap

        nonisolated(unsafe) let tap = tap
        let host = self

        let thread = Thread {
            guard let loop: CFRunLoop = CFRunLoopGetCurrent() else {
                Log.hotkey.error("tap thread has no run loop")
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            let isEnabled = CGEvent.tapIsEnabled(tap: tap)
            host.publish(loop, enabled: isEnabled)

            // The one line worth keeping: a tap that reports itself installed but not
            // enabled receives nothing.
            Log.hotkey.notice("tap enabled=\(isEnabled, privacy: .public)")

            CFRunLoopRun()

            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        thread.name = "com.indite.hotkey-tap"
        thread.qualityOfService = QualityOfService.userInteractive
        thread.start()
    }

    func invalidate() {
        CGEvent.tapEnable(tap: tap, enable: false)
        // Invalidating the port would end the run loop on its own, by leaving the
        // thread with no sources. Stopping it explicitly just gets there sooner.
        if let loop = currentLoop() { CFRunLoopStop(loop) }
        CFMachPortInvalidate(tap)
    }

    /// Whether the tap switched on, once its thread has tried.
    ///
    /// Blocks the caller for the few milliseconds the thread takes to start, and at
    /// most half a second. A thread that has not answered by then counts as a tap
    /// that did not switch on.
    func waitUntilEnabled() -> Bool {
        guard ready.wait(timeout: .now() + .milliseconds(500)) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    private func publish(_ loop: CFRunLoop, enabled: Bool) {
        lock.lock()
        self.loop = loop
        self.enabled = enabled
        lock.unlock()
        ready.signal()
    }

    private func currentLoop() -> CFRunLoop? {
        lock.lock()
        defer { lock.unlock() }
        return loop
    }
}

// MARK: - C Callback

/// Runs on the tap's own thread. Reads what it needs from the event, decides, and
/// returns — the work the decision causes happens on the main actor afterwards.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.tapWasDisabled(byTimeout: type == .tapDisabledByTimeout)
        return nil
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let button = event.getIntegerValueField(.mouseEventButtonNumber)

    let swallow = monitor.decide(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat, button: button)
    return swallow ? nil : Unmanaged.passUnretained(event)
}
#endif
