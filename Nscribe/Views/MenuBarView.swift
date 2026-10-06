import SwiftUI
import SwiftData
import os

#if os(macOS)
import AppKit

/// The menu under the menu bar icon.
///
/// A system menu, not a panel drawn to look like one. The panel had no highlight under
/// the pointer and no arrow keys, and its "⌘," and "⌘Q" were labels with no shortcut
/// behind them. Nothing here needs a window: every row is a command, a choice or a
/// line of status.
///
/// The first line says what Nscribe is doing, and what is wrong when something is. A
/// dictation key that had stopped working used to be reported in small gray type at
/// the end of a row, with the way to fix it in a tooltip.
struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(TranscriptionEngine.self) private var transcriptionEngine
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(MeetingRecorder.self) private var meetingRecorder
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor
    @Environment(AudioInputList.self) private var inputs
    @Environment(AppUpdater.self) private var updater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var modelContext

    /// The newest dictations, for the Recent Dictations submenu.
    @Query(MenuBarView.recentDictations) private var recent: [Dictation]

    private static var recentDictations: FetchDescriptor<Dictation> {
        var descriptor = FetchDescriptor<Dictation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 5
        return descriptor
    }

    var body: some View {
        // At the top until it is taken. The notification that announced the update
        // is gone after a glance, and Nscribe is rarely restarted on its own.
        if let version = updater.readyVersion {
            Button("Restart to Install Nscribe \(version)") { updater.restartToUpdate() }
            Divider()
        } else if let version = updater.driver.waitingVersion {
            Button("Nscribe \(version) Is Available…") { updater.checkForUpdates() }
            Divider()
        }

        if meetingRecorder.hasActiveMeeting {
            meetingSection
            Divider()
        }

        if hotkeyMonitor.hasFailed {
            keyRepairSection
            Divider()
        } else if !meetingRecorder.hasActiveMeeting {
            statusLine(readyLine, glyph: MenuGlyph.dot(.systemGreen))
            if let profileLine {
                Text(profileLine)
            }
            Divider()
        }

        Button(dictationTitle) {
            Task { await coordinator.toggle() }
        }
        .disabled(coordinator.isDelivering || dictationIsBlocked)

        if !meetingRecorder.hasActiveMeeting {
            Button("Start Meeting") { startMeeting() }
                .disabled(transcriptionEngine.isBusy)
        }

        Divider()

        rewriteMenu
        microphoneMenu

        Divider()

        Button("Meetings") { show(NscribeApp.meetingsWindowID) }
        recentMenu

        Divider()

        Button("Help") { HelpNavigator.shared.show(nil) }

        Button("Settings…") {
            openSettings()
            WindowFronting.bringForward("com_apple_SwiftUI_Settings")
        }
        .keyboardShortcut(",")

        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Button("Quit Nscribe") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Status

    /// A line that says something and does nothing: a disabled item, as the system's
    /// own menus show their status.
    private func statusLine(_ text: String, glyph: Image) -> some View {
        Button {} label: {
            Label { Text(text) } icon: { glyph }
                // Asked for by name. A menu shows a label's title alone unless told
                // otherwise, and the dot is how the line is read at a glance.
                .labelStyle(.titleAndIcon)
        }
        .disabled(true)
    }

    /// What to press, in the words Settings uses for it.
    private var readyLine: String {
        if coordinator.isDelivering { return "Finishing the dictation…" }
        if coordinator.isCancellable { return "Listening…" }
        if transcriptionEngine.isBusy, transcriptionEngine.owner == .shortcut {
            return "A shortcut is recording."
        }
        let key = settings.useGlobeKey ? "the Globe key" : settings.hotkeyDisplay
        switch settings.hotkeyActivationMode {
        case .pushToTalk: return "Ready. Hold \(key) to dictate."
        case .toggle: return "Ready. Press \(key) to dictate."
        }
    }

    /// Says when the app in front has a rule of its own.
    ///
    /// The Rewrite choice below is the default. A profile for the app in front
    /// overrides it, and nothing in the menu used to show that: the menu named one
    /// prompt while the dictation ran another.
    private var profileLine: String? {
        guard let profile = coordinator.frontProfile, let promptId = profile.promptId,
              promptId != globalChoice.promptId else { return nil }
        if promptId == PromptConfiguration.rawPromptId {
            return "In \(profile.appName), rewriting is off."
        }
        guard let name = promptConfig.prompt(withId: promptId)?.name else { return nil }
        return "In \(profile.appName), rewriting uses \(name)."
    }

    /// The line for a dictation key that will not start, and the one thing that fixes it.
    @ViewBuilder
    private var keyRepairSection: some View {
        statusLine("The dictation key is not working.", glyph: MenuGlyph.warning)

        if AccessibilityPermission.isTrusted {
            // Trusted, and the tap still would not build. Trying again is all there is.
            Button("Try Again") { hotkeyMonitor.start() }
        } else {
            Button("Allow Accessibility Access…") {
                AccessibilityPermission.openSystemSettings()
            }
        }
    }

    // MARK: - Dictation

    /// A meeting or a shortcut holds the microphone.
    ///
    /// Asked of the engine's owner rather than `coordinator.isRecording`, which is also
    /// false while a dictation is starting or stopping. That grayed out the row under
    /// its own dictation.
    private var dictationIsBlocked: Bool {
        guard transcriptionEngine.isBusy else { return false }
        return transcriptionEngine.owner == .meeting || transcriptionEngine.owner == .shortcut
    }

    /// "Stop" from the moment a dictation starts coming up, because `toggle()` reads a
    /// press during the start as a stop.
    private var dictationTitle: String {
        if coordinator.isDelivering { return "Finishing…" }
        return coordinator.isCancellable ? "Stop Dictation" : "Start Dictation"
    }

    // MARK: - Meeting

    /// The meeting leads the menu while one is open: its state and clock, then the two
    /// things that can be done to it.
    @ViewBuilder
    private var meetingSection: some View {
        switch meetingRecorder.state {
        case .preparing:
            Text("Starting the meeting…")
        case .finishing:
            Text("Saving the meeting…")
        case .recording, .paused, .idle:
            statusLine(
                meetingRecorder.isPaused
                    ? "Meeting paused · \(meetingRecorder.clockLabel)"
                    : "Recording a meeting · \(meetingRecorder.clockLabel)",
                glyph: MenuGlyph.dot(meetingRecorder.isPaused ? .systemOrange : .systemRed)
            )

            Button(meetingRecorder.isPaused ? "Resume Meeting" : "Pause Meeting") {
                Task {
                    if meetingRecorder.isPaused {
                        await meetingRecorder.resume()
                    } else {
                        await meetingRecorder.pause()
                    }
                }
            }
            // A dictation or a shortcut recorded during the pause holds the microphone,
            // and a resume then fails with an error sound and leaves the meeting paused.
            .disabled(meetingRecorder.isPaused && transcriptionEngine.isBusy)

            // Two steps, and both inside the menu. An ended meeting cannot be resumed,
            // and a dialog would bring Nscribe forward over the call.
            Menu("End Meeting") {
                Button("End and Save") {
                    Task { await meetingRecorder.stop(in: modelContext) }
                }
            }
        }
    }

    /// Start without opening the Meetings window.
    ///
    /// The window used to come forward over the call about to be joined. The pill and
    /// the menu bar clock show the meeting is running.
    private func startMeeting() {
        Task {
            await meetingRecorder.start(in: modelContext)
            // With no window open there is nowhere else for a failed start to say why.
            if meetingRecorder.state == .idle, let error = meetingRecorder.lastError {
                NotificationService.shared.showErrorIfEnabled(error, settings: settings)
            }
        }
    }

    // MARK: - Rewrite

    /// Whether the AI rewrites a dictation, and with which prompt: one choice.
    ///
    /// It used to be four controls: a prompt picker, an AI switch, a switch to skip the
    /// AI once, and a prompt named "Raw" that did nothing.
    private enum RewriteChoice: Hashable {
        case off
        case prompt(UUID)

        var promptId: UUID {
            switch self {
            case .off: PromptConfiguration.rawPromptId
            case .prompt(let id): id
            }
        }
    }

    private var globalChoice: RewriteChoice {
        settings.aiEnabled
            ? .prompt(settings.selectedPromptId ?? PromptConfiguration.defaultPromptId)
            : .off
    }

    private var rewriteMenu: some View {
        Menu("Rewrite: \(rewriteName)") {
            Picker("Rewrite", selection: Binding(
                get: { globalChoice },
                set: { choice in
                    switch choice {
                    case .off:
                        settings.aiEnabled = false
                    case .prompt(let id):
                        settings.selectedPromptId = id
                        settings.aiEnabled = true
                    }
                }
            )) {
                Text("Off").tag(RewriteChoice.off)
                Divider()
                ForEach(menuPrompts) { prompt in
                    Text(prompt.name).tag(RewriteChoice.prompt(prompt.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button("Edit Prompts…") {
                SettingsTab.open(.rewriting)
                openSettings()
                WindowFronting.bringForward("com_apple_SwiftUI_Settings")
            }
        }
    }

    /// The prompts shown in the menu, and the one in use even when it is hidden from
    /// the menu: left out, the submenu showed no checkmark at all.
    private var menuPrompts: [Prompt] {
        let selected = settings.selectedPromptId ?? PromptConfiguration.defaultPromptId
        return promptConfig.rewritingPrompts.filter { $0.isVisible || $0.id == selected }
    }

    private var rewriteName: String {
        switch globalChoice {
        case .off:
            return "Off"
        case .prompt(let id):
            // Naming the default here when the lookup fails hides a stored id whose
            // prompt has been deleted, and with it the reason rewriting has started
            // failing.
            return promptConfig.prompt(withId: id)?.name ?? "Missing Prompt"
        }
    }

    // MARK: - Recent Dictations

    /// The last five dictations. A click types one where the cursor is; with Option
    /// held, it is copied.
    ///
    /// Opening this menu does not take focus from the app in front, so the cursor is
    /// still where the user left it when the item is chosen. That is what makes the
    /// menu a way to put a dictation that went astray into the right place, where
    /// before it took the History window, a search and a Copy.
    private var recentMenu: some View {
        Menu("Recent Dictations") {
            if recent.isEmpty {
                Text(settings.keepDictationHistory ? "No dictations yet" : "Recent dictations are not kept")
            }

            ForEach(Array(recent.enumerated()), id: \.element.persistentModelID) { index, dictation in
                let button = Button(Self.menuTitle(for: dictation.text)) {
                    if NSEvent.modifierFlags.contains(.option) {
                        ClipboardService.copy(dictation.text)
                    } else {
                        Task { await coordinator.typeAgain(dictation.text) }
                    }
                }
                // The newest one carries the type-again key, so the menu teaches it.
                if index == 0, let shortcut = retypeShortcut {
                    button.keyboardShortcut(shortcut)
                } else {
                    button
                }
            }

            if !recent.isEmpty {
                Divider()
                Text("Click to type at the cursor. ⌥-click to copy.")
            }

            Divider()
            // No ellipsis: it opens the list and asks for nothing.
            Button("Show All") { show(NscribeApp.historyWindowID) }
        }
    }

    /// The first words of a dictation, on one line, short enough for a menu.
    private static func menuTitle(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 44 ? line.prefix(43).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// The type-again key as a menu shortcut, when it is switched on and in use.
    private var retypeShortcut: KeyboardShortcut? {
        guard settings.retypeHotkeyTrigger != nil, let key = settings.retypeHotkeyString.last else { return nil }
        var modifiers: EventModifiers = []
        for symbol in settings.retypeHotkeyString.dropLast() {
            switch symbol {
            case "⌃": modifiers.insert(.control)
            case "⌥": modifiers.insert(.option)
            case "⌘": modifiers.insert(.command)
            case "⇧": modifiers.insert(.shift)
            default: break
            }
        }
        let equivalent = key == " " ? KeyEquivalent.space : KeyEquivalent(Character(key.lowercased()))
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    // MARK: - Microphone

    private var microphoneMenu: some View {
        Menu("Microphone: \(microphoneName)") {
            Picker("Microphone", selection: Binding(
                get: { settings.inputDeviceUID },
                set: { settings.inputDeviceUID = $0 }
            )) {
                Text("System Default (\(inputs.systemDefaultName))")
                    .tag(AudioInputDevice.systemDefaultUID)
                Divider()
                ForEach(inputs.devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// The chosen microphone, or what recording falls back to when it is unplugged.
    private var microphoneName: String {
        let uid = settings.inputDeviceUID
        if uid == AudioInputDevice.systemDefaultUID {
            return inputs.systemDefaultName
        }
        return inputs.devices.first { $0.uid == uid }?.name
            ?? "Not Connected, Using \(inputs.systemDefaultName)"
    }

    // MARK: - Windows

    /// Open one of the app's windows and bring it to the front.
    private func show(_ windowID: String) {
        openWindow(id: windowID)
        WindowFronting.bringForward(windowID)
    }
}

// MARK: - Window Fronting

/// Brings a window Nscribe has just opened in front of every other app's.
///
/// A menu bar app is not the active application while its menu is showing, so a
/// window it opens lands behind whatever the user was looking at. `NSApp.activate()`
/// used to be enough, when the menu was a panel: a click in the panel was a click in
/// one of Nscribe's own windows, and macOS grants activation after that. A click in
/// a system menu is not, the request was declined, and every window opened from the
/// menu went to the back.
///
/// So the app activates over the others, which is what the user asked for by choosing
/// the window from the menu, and the window is ordered to the front whether or not the
/// activation is granted.
@MainActor
enum WindowFronting {
    /// - Parameter identifierPrefix: The start of the window's identifier: the id of a
    ///   `Window` scene, or SwiftUI's own for the Settings window.
    static func bringForward(_ identifierPrefix: String) {
        // After this turn of the run loop, since a window opened a moment ago does not
        // exist until then.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(identifierPrefix) == true }
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()

            // What came of it, read once things have settled. A window that stays
            // behind is invisible from inside the app, so the log is the only witness.
            try? await Task.sleep(for: .milliseconds(500))
            Log.app.notice("""
                Brought \(identifierPrefix, privacy: .public) forward: \
                found \(window != nil, privacy: .public), \
                app active \(NSApp.isActive, privacy: .public), \
                window key \(window?.isKeyWindow ?? false, privacy: .public)
                """)
        }
    }
}

// MARK: - Menu Glyphs

/// Colored marks for the status line.
///
/// Drawn as images of their own because a menu tints a symbol as a template, and the
/// status line's whole point is the color.
private enum MenuGlyph {
    static func dot(_ color: NSColor) -> Image {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }

    static var warning: Image {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        guard let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return Image(systemName: "exclamationmark.triangle.fill")
        }
        return Image(nsImage: image)
    }
}

// MARK: - Menu Bar Icon

/// The status bar draws this as a template image, so only the symbol's shape can say
/// what is happening; a color set here never shows.
///
/// One shape per state. A dictation and a meeting used to share the filled microphone,
/// and a paused meeting showed the idle one.
///
/// At rest the icon is the app icon's N: the two quotation marks and the chisel.
/// While a dictation is heard, the same N is knocked out of a filled tile. Both are
/// drawn by `Design/Icon/draw-icon.swift`, from the shapes the app icon is made of.
struct MenuBarIcon: View {
    let isDictating: Bool
    let isRewriting: Bool
    let meeting: MeetingRecorder.State
    let meetingClock: String
    let keyHasFailed: Bool

    var body: some View {
        // Named, or VoiceOver reads the status item as the symbol.
        icon
            .accessibilityLabel("Nscribe")
            .modifier(RegistersFamilyWindows())

        // The meeting's clock beside the icon, so an hour-long meeting shows it is
        // still running without the pill.
        if !isDictating, !isRewriting, meeting == .recording || meeting == .paused {
            Text(meetingClock)
                .monospacedDigit()
        }
    }

    private var icon: Image {
        // The dictation first: it is what the user is doing this second, and during a
        // paused meeting it is what holds the microphone.
        if isDictating { return Image("MenuBarIconSpeaking") }
        if isRewriting { return Image(systemName: "brain") }
        switch meeting {
        case .recording, .preparing, .finishing: return Image(systemName: "record.circle")
        case .paused: return Image(systemName: "pause.circle")
        case .idle:
            return keyHasFailed
                ? Image(systemName: "exclamationmark.triangle")
                : Image("MenuBarIcon")
        }
    }
}

#endif
