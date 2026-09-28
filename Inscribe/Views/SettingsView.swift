import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            SoundsSettingsView()
                .tabItem {
                    Label("Sounds", systemImage: "speaker.wave.2")
                }

            PromptsSettingsView()
                .tabItem {
                    Label("Prompts", systemImage: "text.bubble")
                }

            HotkeySettingsView()
                .tabItem {
                    Label("Hotkey", systemImage: "keyboard")
                }

            OutputSettingsView()
                .tabItem {
                    Label("Output", systemImage: "text.cursor")
                }

            DictationSettingsView()
                .tabItem {
                    Label("Dictation", systemImage: "waveform")
                }

            AppProfilesSettingsView()
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity,
               minHeight: 420, idealHeight: 520, maxHeight: .infinity)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor

    @State private var isConfirmingReset = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("AI Processing") {
                Toggle("Enable AI processing", isOn: $settings.aiEnabled)

                if settings.aiEnabled {
                    if let reason = AIProcessor.unavailabilityReason {
                        Label {
                            Text(reason)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }

                    // Nil and the default's own id both mean Clean Up. The menu bar
                    // stores the id when Clean Up is picked there, which a separate row
                    // for nil could not show, so the picker went blank.
                    Picker("Default Prompt", selection: Binding(
                        get: { settings.selectedPromptId ?? PromptConfiguration.defaultPromptId },
                        set: { settings.selectedPromptId = $0 }
                    )) {
                        ForEach(promptConfig.prompts) { prompt in
                            Text(prompt.name).tag(prompt.id)
                        }
                    }

                    Text("Uses Apple's on-device AI model. Your data never leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Let the AI see what is already in the field", isOn: $settings.useSurroundingContext)

                    Text("Reads the text around your cursor and gives it to the AI as background, so a dictated reply matches the thread it belongs to. It is marked as context to read, not text to rewrite. Uses the Accessibility access Inscribe already has.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dictation History") {
                Toggle("Keep recent dictations", isOn: $settings.keepDictationHistory)

                if settings.keepDictationHistory {
                    Picker("Keep the last", selection: $settings.dictationHistoryLimit) {
                        ForEach([25, 50, 100, 250, 500], id: \.self) { limit in
                            Text("\(limit)").tag(limit)
                        }
                    }
                    // A menu rather than a stepper. A stepper applies every value it
                    // passes on the way, so the pruning below deleted dictations for good
                    // at each lower one. Pruned on the choice itself because pruning
                    // otherwise waits for the next saved dictation, which could be a long
                    // wait for a setting the user just changed on purpose.
                    .onChange(of: settings.dictationHistoryLimit) { _, newLimit in
                        DictationHistory.prune(to: newLimit, in: modelContext)
                        modelContext.saveOrLog()
                    }
                }

                Text("Stores everything you dictate, in plain text on this Mac. Nothing is sent anywhere — but if you dictate anything you would not want written to disk, switch this off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("When a transcript is ready", isOn: $settings.showNotifications)
                Toggle("When something goes wrong", isOn: $settings.notifyOnError)

                Text("Errors are listed separately so silencing routine banners does not also hide the reason nothing appeared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Defaults") {
                    isConfirmingReset = true
                }
                .confirmationDialog(
                    "Reset settings to their defaults?",
                    isPresented: $isConfirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) { resetToDefaults() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This also clears your word replacements, vocabulary hints, per-app settings and recorded hotkey. Your prompts and their settings are kept. It cannot be undone.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func resetToDefaults() {
        settings.resetToDefaults()
        // The Hotkey tab re-arms on its own changes, but it is not on screen here —
        // without this the old combination keeps firing and the restored one does
        // nothing until the app is relaunched.
        hotkeyMonitor.trigger = settings.hotkeyTrigger
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
        hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger
    }
}

// MARK: - Prompts Settings

struct PromptsSettingsView: View {
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(AppSettings.self) private var settings

    @State private var selectedPromptId: UUID?

    var body: some View {
        HSplitView {
            // Prompt list
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedPromptId) {
                    Section("Built-in Prompts") {
                        ForEach(promptConfig.builtInPromptsList) { prompt in
                            PromptRow(prompt: prompt) {
                                promptConfig.toggleVisibility(promptId: prompt.id)
                            }
                            .tag(prompt.id)
                        }
                    }

                    if !promptConfig.customPrompts.isEmpty {
                        Section("Custom Prompts") {
                            ForEach(promptConfig.customPrompts) { prompt in
                                PromptRow(prompt: prompt) {
                                    promptConfig.toggleVisibility(promptId: prompt.id)
                                }
                                .tag(prompt.id)
                            }
                            .onDelete { indexSet in
                                deletePrompts(at: indexSet)
                            }
                        }
                    }
                }
                .listStyle(.bordered)

                HStack {
                    Button("Add Prompt", systemImage: "plus") {
                        // Created and selected at once, so the one editor fills it in.
                        // A separate Add sheet copied that editor and lacked its Keep my
                        // words switch.
                        let newPrompt = Prompt(
                            name: "New Prompt",
                            systemPrompt: "You are a helpful text processing assistant.",
                            userTemplate: ""
                        )
                        promptConfig.addPrompt(newPrompt)
                        selectedPromptId = newPrompt.id
                    }
                    .help("Add Prompt")

                    Button("Delete Prompt", systemImage: "minus") {
                        if let id = selectedPromptId {
                            deletePrompt(id: id)
                        }
                    }
                    .help("Delete Prompt")
                    .disabled(selectedPromptId == nil || isBuiltIn(selectedPromptId))

                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 220)

            // Prompt detail
            VStack {
                if let promptId = selectedPromptId,
                   let prompt = promptConfig.prompt(withId: promptId) {
                    PromptDetailView(
                        prompt: prompt,
                        canEdit: !prompt.isBuiltIn,
                        onSave: { updatedPrompt in
                            promptConfig.updatePrompt(updatedPrompt)
                        },
                        onDuplicate: { newPrompt in
                            promptConfig.addPrompt(newPrompt)
                            selectedPromptId = newPrompt.id
                        },
                        onSaveGenerationSettings: { temp, sampling in
                            promptConfig.updateGenerationSettings(
                                promptId: promptId,
                                temperature: temp,
                                samplingMode: sampling
                            )
                        }
                    )
                    // One editor per prompt, so its fields start from that prompt
                    // rather than keeping what the previous one left in them.
                    .id(promptId)
                } else {
                    ContentUnavailableView(
                        "Select a Prompt",
                        systemImage: "text.bubble",
                        description: Text("Choose a prompt from the list to view or edit it.")
                    )
                }
            }
            .frame(minWidth: 280)
        }
        .onAppear {
            if selectedPromptId == nil {
                selectedPromptId = promptConfig.prompts.first?.id
            }
        }
    }

    private func isBuiltIn(_ id: UUID?) -> Bool {
        guard let id = id else { return true }
        return promptConfig.prompt(withId: id)?.isBuiltIn ?? true
    }

    private func deletePrompts(at indexSet: IndexSet) {
        // Resolved to ids up front: each deletion shrinks `customPrompts`, so the
        // later indices of a multi-row delete would land on the wrong prompts.
        let ids = indexSet.map { promptConfig.customPrompts[$0].id }
        for id in ids {
            deletePrompt(id: id)
        }
    }

    private func deletePrompt(id: UUID) {
        promptConfig.deletePrompt(withId: id)
        forgetDeletedPrompt(id)
        selectedPromptId = promptConfig.prompts.first?.id
    }

    /// Clear the settings still pointing at a prompt that no longer exists.
    ///
    /// A dangling id is not inert: the AI pass throws `promptNotFound` on every
    /// dictation from then on, and the menu bar goes on naming a prompt as if
    /// nothing had happened.
    private func forgetDeletedPrompt(_ id: UUID) {
        if settings.selectedPromptId == id {
            settings.selectedPromptId = nil
        }

        var profiles = settings.appProfiles
        let stale = profiles.filter { $0.value.promptId == id }.keys
        guard !stale.isEmpty else { return }
        for bundleID in stale {
            profiles[bundleID]?.promptId = nil
        }
        settings.appProfiles = profiles
    }
}

struct PromptRow: View {
    let prompt: Prompt
    let onToggleVisibility: () -> Void

    var body: some View {
        HStack {
            // Secondary even when selected. The selection turns light gray once the
            // editor takes focus, and a white icon vanished against it.
            Image(systemName: prompt.isBuiltIn ? "sparkles" : "text.bubble")
                .foregroundStyle(.secondary)

            Text(prompt.name)
                .lineLimit(1)

            Spacer()

            Toggle("Show in Menu Bar", isOn: Binding(
                get: { prompt.isVisible },
                set: { _ in onToggleVisibility() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(prompt.isVisible ? "Visible in menu bar" : "Hidden from menu bar")
        }
    }
}

struct PromptDetailView: View {
    let prompt: Prompt
    let canEdit: Bool
    let onSave: (Prompt) -> Void
    let onDuplicate: (Prompt) -> Void
    let onSaveGenerationSettings: (Double, SamplingMode) -> Void

    // Prompt text state
    @State private var name: String
    @State private var systemPrompt: String
    @State private var userTemplate: String
    @State private var keepsWords: Bool

    // Generation settings state
    @State private var temperature: Double
    @State private var samplingModeTag: String
    @State private var topPThreshold: Double
    @State private var topKValue: Int

    init(
        prompt: Prompt,
        canEdit: Bool,
        onSave: @escaping (Prompt) -> Void,
        onDuplicate: @escaping (Prompt) -> Void,
        onSaveGenerationSettings: @escaping (Double, SamplingMode) -> Void
    ) {
        self.prompt = prompt
        self.canEdit = canEdit
        self.onSave = onSave
        self.onDuplicate = onDuplicate
        self.onSaveGenerationSettings = onSaveGenerationSettings
        self._name = State(initialValue: prompt.name)
        self._systemPrompt = State(initialValue: prompt.systemPrompt)
        self._userTemplate = State(initialValue: prompt.userTemplate)
        self._keepsWords = State(initialValue: prompt.keepsWords)
        self._temperature = State(initialValue: prompt.temperature)
        self._samplingModeTag = State(initialValue: prompt.samplingMode.caseTag)
        // Extract associated values for sub-controls
        switch prompt.samplingMode {
        case .topP(let threshold):
            self._topPThreshold = State(initialValue: threshold)
            self._topKValue = State(initialValue: 10)
        case .topK(let k):
            self._topPThreshold = State(initialValue: 0.9)
            self._topKValue = State(initialValue: k)
        default:
            self._topPThreshold = State(initialValue: 0.9)
            self._topKValue = State(initialValue: 10)
        }
    }

    var body: some View {
        Form {
            // A built-in prompt changes only through a copy, so the way to one comes
            // first rather than below every field it cannot edit.
            if !canEdit, !isRaw {
                duplicateSection
            }

            Section {
                TextField("Name", text: $name)
                    .disabled(!canEdit)

                if isRaw {
                    Text("Inserts the transcription as it was heard. The AI never runs for this prompt, so there is nothing here to tune.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !isRaw {
                Section("System Prompt") {
                    TextEditor(text: $systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .disabled(!canEdit)
                }

                Section("User Template") {
                    TextEditor(text: $userTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .disabled(!canEdit)

                    Text("Your transcription is automatically appended after these instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Your Words") {
                    Toggle("Keep my words", isOn: $keepsWords)
                        .disabled(!canEdit)
                    Text("For prompts that correct rather than rewrite. Any word the model drops is put back, and only punctuation, capitals, repeated words and one-for-one word fixes get through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Generation settings — always editable, even for built-in prompts
                Section("Generation Settings") {
                    // Greedy sampling always takes the likeliest word, so temperature
                    // has nothing to act on.
                    if samplingModeTag != "greedy" {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Temperature")
                                Spacer()
                                Text(String(format: "%.1f", temperature))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                            Text(temperatureHint)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Picker("Sampling", selection: $samplingModeTag) {
                        Text("Automatic").tag("automatic")
                        Text("Greedy").tag("greedy")
                        Text("Top-P").tag("topP")
                        Text("Top-K").tag("topK")
                    }
                    .help("Automatic: default random sampling.\nGreedy: deterministic, always picks the most likely word.\nTop-P: samples from words within a cumulative probability threshold.\nTop-K: samples from the K most likely words.")

                    Text(samplingHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if samplingModeTag == "topP" {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Probability Threshold")
                                Spacer()
                                Text(String(format: "%.2f", topPThreshold))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $topPThreshold, in: 0.1...1.0, step: 0.05)
                        }
                    }

                    if samplingModeTag == "topK" {
                        Stepper("Top K: \(topKValue)", value: $topKValue, in: 1...100)
                    }
                }

                if canEdit {
                    duplicateSection
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: name) { persist() }
        .onChange(of: systemPrompt) { persist() }
        .onChange(of: userTemplate) { persist() }
        .onChange(of: keepsWords) { persist() }
        .onChange(of: temperature) { persist() }
        .onChange(of: currentSamplingMode) { persist() }
    }

    /// The Raw prompt skips the AI entirely, so its instructions and generation
    /// settings would change nothing, and a copy of it would send empty instructions
    /// to the model.
    private var isRaw: Bool {
        prompt.id == PromptConfiguration.rawPromptId
    }

    private var duplicateSection: some View {
        Section {
            Button {
                let duplicate = Prompt(
                    name: "\(name) Copy",
                    systemPrompt: systemPrompt,
                    userTemplate: userTemplate,
                    isBuiltIn: false,
                    temperature: temperature,
                    samplingMode: currentSamplingMode,
                    keepsWords: keepsWords
                )
                onDuplicate(duplicate)
            } label: {
                Label("Duplicate as Custom Prompt", systemImage: "doc.on.doc")
            }
        }
    }

    /// Write the editor's state to the store, on every change.
    ///
    /// The rest of Settings applies each control as it moves. This editor used to wait
    /// for a Save button, and selecting another prompt or closing the window threw the
    /// unsaved text away without a word.
    private func persist() {
        if canEdit {
            onSave(Prompt(
                id: prompt.id,
                name: name,
                systemPrompt: systemPrompt,
                userTemplate: userTemplate,
                isBuiltIn: false,
                // Carried over: `updatePrompt` replaces the stored prompt wholesale,
                // so anything left out is reset.
                isVisible: prompt.isVisible,
                temperature: temperature,
                samplingMode: currentSamplingMode,
                keepsWords: keepsWords
            ))
        } else {
            onSaveGenerationSettings(temperature, currentSamplingMode)
        }
    }

    /// Build a SamplingMode from the current UI state
    private var currentSamplingMode: SamplingMode {
        switch samplingModeTag {
        case "greedy": return .greedy
        case "topP": return .topP(topPThreshold)
        case "topK": return .topK(topKValue)
        default: return .automatic
        }
    }

    private var temperatureHint: String {
        if temperature < 0.3 { return "Very predictable" }
        if temperature < 0.7 { return "Balanced" }
        return "Creative"
    }

    private var samplingHint: String {
        switch samplingModeTag {
        case "greedy": return "Always picks the most likely word. Same input = same output."
        case "topP": return "Samples from the smallest set of words whose probabilities add up to the threshold."
        case "topK": return "Samples from the K most likely words. Lower K = more focused output."
        default: return "Default random sampling with temperature-based variation."
        }
    }
}

// MARK: - Sounds Settings

struct SoundsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SoundCatalog.self) private var soundCatalog

    @State private var importError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Feedback Sounds") {
                Toggle("Play feedback sounds", isOn: $settings.playFeedbackSounds)

                Group {
                    SoundPickerRow(
                        label: "Recording Started",
                        selection: $settings.startSoundName,
                        sounds: soundCatalog.allSounds
                    )
                    SoundPickerRow(
                        label: "Recording Stopped",
                        selection: $settings.stopSoundName,
                        sounds: soundCatalog.allSounds
                    )
                    SoundPickerRow(
                        label: "Processing Complete",
                        selection: $settings.completeSoundName,
                        sounds: soundCatalog.allSounds
                    )
                    SoundPickerRow(
                        label: "Error",
                        selection: $settings.errorSoundName,
                        sounds: soundCatalog.allSounds
                    )
                }
                .disabled(!settings.playFeedbackSounds)
            }

            // None turns this off. The feedback switch above does not reach the loop,
            // which plays only while the AI works.
            Section("Processing Indicator") {
                SoundPickerRow(
                    label: "Processing Loop",
                    selection: $settings.processingSoundName,
                    sounds: soundCatalog.allSounds
                )
            }

            Section("Custom Sounds") {
                if soundCatalog.customSounds.isEmpty {
                    Text("No custom sounds imported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(soundCatalog.customSounds) { sound in
                        HStack {
                            Text(sound.displayName)

                            Spacer()

                            Button("Preview Sound", systemImage: "speaker.wave.2") {
                                SoundCatalog.shared.preview(sound.id)
                            }
                            .help("Preview Sound")

                            Button("Delete Sound", systemImage: "trash", role: .destructive) {
                                deleteSound(sound.id)
                            }
                            .help("Delete Sound")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }

                Button("Import Sound File…") {
                    importSoundFile()
                }

                if let importError {
                    Text(importError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importSoundFile() {
        guard let window = NSApp.keyWindow else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Sound File"
        // Any audio type, the same test the catalog lists custom sounds by.
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        // A sheet on the Settings window. Run modally, the panel floated free of the
        // window and blocked every other one in the app.
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }

            do {
                try soundCatalog.importSound(from: url)
                importError = nil
            } catch {
                importError = "Failed to import: \(error.localizedDescription)"
            }
        }
    }

    private func deleteSound(_ id: String) {
        do {
            try soundCatalog.deleteCustomSound(id: id)

            // Reset any settings that reference this sound back to default, now
            // that the file is actually gone — resetting first meant a failed
            // delete still stranded the user's sound choice on a file that was
            // never removed.
            if settings.startSoundName == id { settings.startSoundName = "Morse" }
            if settings.stopSoundName == id { settings.stopSoundName = "Pop" }
            if settings.completeSoundName == id { settings.completeSoundName = "Glass" }
            if settings.errorSoundName == id { settings.errorSoundName = "Basso" }
            if settings.processingSoundName == id { settings.processingSoundName = "Bottle" }
        } catch {
            importError = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

struct SoundPickerRow: View {
    let label: String
    @Binding var selection: String
    let sounds: [SoundCatalog.SoundItem]

    var body: some View {
        HStack {
            Picker(label, selection: $selection) {
                ForEach(sounds) { sound in
                    Text(sound.displayName).tag(sound.id)
                }
            }

            Button("Preview Sound", systemImage: "speaker.wave.2") {
                SoundCatalog.shared.preview(selection)
            }
            .labelStyle(.iconOnly)
            .help("Preview Sound")
            .buttonStyle(.borderless)
            .disabled(selection == SoundCatalog.noneID)
        }
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor

    @State private var isRecordingHotkey = false
    @State private var captureError: String?
    @State private var isTrusted = AccessibilityPermission.isTrusted

    /// Re-check trust while the window is open — the user grants it in System Settings,
    /// and macOS sends no notification when they do.
    private let trustPoll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var settings = settings

        Form {
            accessibilitySection

            Section("Activation") {
                Picker("When the key is pressed", selection: $settings.hotkeyActivationModeRaw) {
                    ForEach(HotkeyActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Trigger Key") {
                Toggle("Use the Globe (🌐) key", isOn: $settings.useGlobeKey)

                if settings.useGlobeKey {
                    Text("Set System Settings → Keyboard → \"Press 🌐 to\" to *Do Nothing*, or macOS will also switch your input source every time you dictate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                        )
                    }
                    .buttonStyle(.link)
                } else {
                    customHotkeyRow
                }
            }

            Section("Undo") {
                Toggle("Enable an undo shortcut", isOn: $settings.undoHotkeyEnabled)

                if settings.undoHotkeyEnabled {
                    LabeledContent("Shortcut") {
                        Text(settings.undoHotkeyString)
                            .font(.system(.body, design: .monospaced))
                    }

                    // Dictation wins when both use one shortcut. This caption is the
                    // only sign that undo has stepped aside.
                    if settings.undoHotkeyTrigger == nil {
                        Label {
                            Text("Off while dictation uses the same shortcut.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }

                    Text("Takes back the last text Inscribe typed, and puts it on your clipboard. Sends the receiving app its own Undo, and only within two minutes — after that it would throw away unrelated work. Not available when After typing is set to Press Return.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                if hotkeyMonitor.isRunning {
                    Label {
                        Text("Listening for \(triggerDescription)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else if let error = hotkeyMonitor.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("Not listening", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }

                Text("Press Escape while recording to discard it without producing text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // The status message says to grant access "and try again" — this is
            // that retry. Trust may already have been granted in a System
            // Settings visit that started before this tab was even open, in
            // which case the poll below never sees a change to react to.
            if !hotkeyMonitor.isRunning, AccessibilityPermission.isTrusted {
                hotkeyMonitor.start()
            }
        }
        .onReceive(trustPoll) { _ in
            let current = AccessibilityPermission.isTrusted
            guard current != isTrusted else { return }
            isTrusted = current
            // Trust just arrived — the tap could not have been created before now.
            if current, !hotkeyMonitor.isRunning {
                hotkeyMonitor.start()
            }
        }
        .onChange(of: isRecordingHotkey) { _, recording in
            if recording { startCapturing() } else { hotkeyMonitor.endCapture() }
        }
        .onChange(of: settings.useGlobeKey) { _, _ in
            // The recorder lives in the custom-shortcut row, which the Globe key hides.
            // Left armed, capture would go on swallowing every keystroke on the Mac
            // with nothing on screen to say why.
            isRecordingHotkey = false
            rearm()
        }
        .onChange(of: settings.hotkeyString) { _, _ in rearm() }
        .onChange(of: settings.hotkeyActivationModeRaw) { _, _ in rearm() }
        .onChange(of: settings.undoHotkeyEnabled) { _, _ in rearm() }
        .onDisappear {
            // Capture swallows every keystroke on the machine, so it must never
            // outlive the screen that turned it on.
            hotkeyMonitor.endCapture()
            isRecordingHotkey = false
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var accessibilitySection: some View {
        if !isTrusted {
            Section {
                Label {
                    Text("Inscribe needs Accessibility access")
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                }

                Text("The hotkey and typing into other apps both go through macOS Accessibility. Nothing works until you grant it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // macOS shows its own prompt at most once per app version. Launch has
                // spent it by the time anyone opens this tab, so System Settings is
                // the only way in from here.
                Button("Open System Settings") {
                    AccessibilityPermission.openSystemSettings()
                }
            }
        }
    }

    /// The shortcut is its own button, as in System Settings: click it, then type the
    /// combination.
    @ViewBuilder
    private var customHotkeyRow: some View {
        LabeledContent("Shortcut") {
            Button(isRecordingHotkey ? "Type Shortcut…" : settings.hotkeyDisplay) {
                isRecordingHotkey.toggle()
            }
            .monospaced(!isRecordingHotkey)
            // Recording listens through the tap. Without one nothing hears the
            // keystroke, and "Type Shortcut…" waited for ever.
            .disabled(!isRecordingHotkey && !hotkeyMonitor.isRunning)
        }

        if let captureError {
            Text(captureError)
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("Use at least two of ⌃, ⌥ and ⌘, so the shortcut cannot swallow an everyday one like ⌘W. Escape cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var triggerDescription: String {
        settings.useGlobeKey ? "the Globe key" : settings.hotkeyDisplay
    }

    // MARK: - Hotkey Recording

    /// Listen for the combination the user wants, through the tap that is already
    /// watching the keyboard.
    ///
    /// The tap sees keystrokes wherever they are typed, so this no longer depends on
    /// the settings window holding keyboard focus — which is what a menu bar app
    /// cannot promise, and why the old local monitor caught nothing.
    private func startCapturing() {
        captureError = nil

        hotkeyMonitor.beginCapture { keyCode, modifiers in
            if keyCode == 53 {  // Escape
                isRecordingHotkey = false
                return
            }

            guard let combination = AppSettings.hotkeyString(
                forKeyCode: keyCode,
                modifiers: modifiers
            ) else {
                // Stay armed and say why, rather than swallowing the keystroke and
                // leaving the user pressing keys at a screen that never answers.
                captureError = "That one cannot be a hotkey. Use a letter, number or punctuation key with at least two of ⌃, ⌥ and ⌘."
                return
            }

            settings.hotkeyString = combination
            isRecordingHotkey = false
        }
    }

    /// Push the current settings into the running tap.
    private func rearm() {
        hotkeyMonitor.trigger = settings.hotkeyTrigger
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
        hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger
        if !hotkeyMonitor.isRunning, AccessibilityPermission.isTrusted {
            hotkeyMonitor.start()
        }
    }

}

// MARK: - Output Settings

/// What happens once the text is in the field. Stored as the two switches that came
/// before it, so an existing choice of Return carries over.
private enum AfterTyping: Hashable {
    case nothing, addSpace, pressReturn
}

struct OutputSettingsView: View {
    /// One labelled slider with its value beside it. Two of these read as a pair.
    private func solidityRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: 0.25...1)
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Where Text Goes") {
                Picker("After transcribing", selection: $settings.outputModeRaw) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if settings.outputMode == .smartInsert {
                    Text("Inscribe checks what has keyboard focus. A text field gets the text typed straight in; anything else falls back to the clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if typesText {
                Section("Typing") {
                    Toggle("Restore my previous clipboard afterwards", isOn: $settings.restoreClipboardAfterPaste)

                    Picker("After typing", selection: Binding(
                        get: {
                            settings.autoSubmitAfterInsert ? AfterTyping.pressReturn
                                : settings.addSpaceAfterInsert ? .addSpace : .nothing
                        },
                        set: {
                            settings.autoSubmitAfterInsert = $0 == .pressReturn
                            settings.addSpaceAfterInsert = $0 == .addSpace
                        }
                    )) {
                        Text("Nothing").tag(AfterTyping.nothing)
                        Text("Add a space").tag(AfterTyping.addSpace)
                        Text("Press Return").tag(AfterTyping.pressReturn)
                    }

                    if settings.autoSubmitAfterInsert {
                        Toggle("Use Shift+Return instead", isOn: $settings.useShiftReturnAfterInsert)
                            .padding(.leading, 20)

                        Text(settings.useShiftReturnAfterInsert
                             ? "Starts a new line and leaves the message unsent — for chat apps where Return would send it."
                             : "Sends the message in chat apps, and runs the search in search fields.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("While Speaking") {
                Toggle("Show the words as you say them", isOn: $settings.showDictationOverlay)

                Text("Floats a panel above other windows while you hold the key, so you can see the dictation landing rather than trusting a sound. Drag it anywhere; it comes back where you left it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.showDictationOverlay {
                    Button("Reset Panel Position") {
                        coordinator.resetOverlayPosition()
                    }
                }

                Toggle("Show the microphone during meetings", isOn: $settings.showMeetingIndicator)

                Text("A small panel with the same band, so an hour-long meeting shows it is still hearing the room rather than only that it is open. Drag it anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Both panels read these, so they stay while either one is on.
                if settings.showDictationOverlay || settings.showMeetingIndicator {
                    solidityRow("Background", value: $settings.overlayOpacity)
                    solidityRow("Text and band", value: $settings.overlayContentOpacity)

                    Text("Two separate dials, shared by both panels. The background is glass — turn it down to read the window underneath through it. The text and band sit on top and keep their own setting, so a pane you can see straight through can still carry words you can read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Whether anything types text: the global choice, or an app profile.
    ///
    /// The typing options apply to both. Tied to the global choice alone, they
    /// disappeared whenever it copied, while a profile that types still followed them.
    private var typesText: Bool {
        settings.outputMode == .smartInsert
            || settings.appProfiles.values.contains {
                $0.isEnabled && $0.outputModeRaw == OutputMode.smartInsert.rawValue
            }
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    /// This run's own log, so a dictation that went wrong can be explained without
    /// anyone opening a terminal.
    @ViewBuilder
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch lastRead {
            case nil:
                ProgressView()
                    .controlSize(.small)

            case .failure(let error)?:
                Text("Could not read the log: \(error.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.orange)

            case .success(let entries)?:
                if entries.isEmpty {
                    Text("Nothing recorded yet this run. Dictate once and come back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entries.reversed()) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.date, format: .dateTime.hour().minute().second())
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)

                                    Text(entry.category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 72, alignment: .leading)

                                    Text(entry.message)
                                        .font(.caption2)
                                        .foregroundStyle(entry.isProblem ? Color.orange : .primary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
            }

            HStack {
                Button("Refresh") { reload() }
                Button("Copy") {
                    ClipboardService.copy(Diagnostics.asText(entries))
                }
                .disabled(entries.isEmpty)
            }

            Text("Only this run, and only Inscribe. Anything you wrote or said is redacted by the system before it gets here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func reload() {
        // Diagnostics.recent() walks the unified log, which can take real time on
        // a busy run — off the main actor so opening this disclosure group does
        // not stall the rest of the Settings window while it works.
        Task {
            lastRead = await Task.detached(priority: .utility) {
                Result { try Diagnostics.recent() }
            }.value
        }
    }

    /// Read from the bundle rather than hard-coded, so this stops matching
    /// reality the moment the app ships a new version.
    private var appVersionText: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(shortVersion) (\(build))"
    }

    /// The last read of the log, kept whole so a failed read shows as one rather
    /// than as an empty log. Nil until the first read returns.
    @State private var lastRead: Result<[Diagnostics.Entry], any Error>?
    @State private var showingDiagnostics = false

    private var entries: [Diagnostics.Entry] {
        (try? lastRead?.get()) ?? []
    }

    var body: some View {
        // Scrolls because the log can outgrow the window; the anchor keeps the page
        // centered while it fits.
        ScrollView {
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Inscribe")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Background Voice Transcription")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(appVersionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(width: 200)

                DisclosureGroup(isExpanded: $showingDiagnostics) {
                    diagnostics
                } label: {
                    Label("What Inscribe has been doing", systemImage: "stethoscope")
                        .font(.subheadline)
                }
                .frame(maxWidth: 520)
                .onChange(of: showingDiagnostics) { _, shown in
                    if shown { reload() }
                }

                Divider()
                    .frame(width: 200)

                VStack(spacing: 8) {
                    Text("Uses on-device AI for transcription and text processing.")
                    Text("Your voice data never leaves your device.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }
}

// MARK: - Dictation Settings

struct DictationSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var devices: [AudioInputDevice] = []
    @State private var systemDefaultName = ""
    @State private var vocabularyText = ""
    @State private var replacements: [ReplacementRow] = []

    /// One editable row. Carries its own identity so SwiftUI does not reshuffle
    /// text fields as the user types a key that collides with another row.
    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Microphone") {
                Picker("Record from", selection: $settings.inputDeviceUID) {
                    Text("System Default (\(systemDefaultName))")
                        .tag(AudioInputDevice.systemDefaultUID)
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                if settings.inputDeviceUID != AudioInputDevice.systemDefaultUID,
                   !devices.contains(where: { $0.uid == settings.inputDeviceUID }) {
                    Label {
                        Text("That device is not connected — recording falls back to the system default.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }

            Section("Recording") {
                // A menu of lengths: the 30-second stepper this replaced took up to
                // 119 clicks to cross its range.
                Picker("Maximum length", selection: $settings.maxRecordingSeconds) {
                    ForEach([60, 120, 300, 600, 900, 1800, 3600], id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes])))
                            .tag(seconds)
                    }
                }

                Text("Recording stops on its own at this point, so a stuck hotkey cannot record forever.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            MeetingAudioSection()

            Section("Vocabulary") {
                Text("Names and jargon you use, one per line. When the recognizer is torn between words, it takes the one on this list, and it spells these the way you write them here: \"type script\" comes out as TypeScript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $vocabularyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .onChange(of: vocabularyText) { _, text in
                        settings.vocabularyHints = text
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }

            DiarizationModelsSection()

            Section("Word Replacements") {
                Text("Applied after transcription, whole words only and ignoring case — so a rule for \"vox\" leaves \"voxel\" alone. Leave the written word blank to delete the heard word instead of replacing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasDuplicateReplacements {
                    Label {
                        Text("Two rows have the same heard word — only one of them will be applied.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }

                ForEach($replacements) { $row in
                    HStack {
                        TextField("Heard", text: $row.spoken, prompt: Text("heard"))
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("Written", text: $row.written, prompt: Text("written"))
                        Button("Remove Replacement", systemImage: "minus.circle") {
                            replacements.removeAll { $0.id == row.id }
                            commitReplacements()
                        }
                        .labelStyle(.iconOnly)
                        .help("Remove Replacement")
                        .buttonStyle(.borderless)
                    }
                    // A grouped form shows a field's title as a label beside it; the
                    // arrow already says which side is which.
                    .labelsHidden()
                    .onChange(of: row) { _, _ in commitReplacements() }
                }

                Button {
                    replacements.append(ReplacementRow(spoken: "", written: ""))
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .task {
            // Picks up a microphone plugged in, or a default switched, while this tab
            // is open. Only these two reload, because `load` also resets the vocabulary
            // and replacements and would throw away edits in progress.
            for await _ in AudioDeviceCatalog.changes() {
                devices = AudioDeviceCatalog.inputDevices()
                systemDefaultName = AudioDeviceCatalog.systemDefaultName()
            }
        }
    }

    private func load() {
        devices = AudioDeviceCatalog.inputDevices()
        systemDefaultName = AudioDeviceCatalog.systemDefaultName()
        vocabularyText = settings.vocabularyHints.joined(separator: "\n")
        replacements = settings.wordReplacements
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ReplacementRow(spoken: $0.key, written: $0.value) }
    }

    /// Whether two rows share a heard word, ignoring case the way matching itself
    /// does. `commitReplacements` below can only keep one value per key, so this is
    /// the one thing about the list a row-by-row glance would not show: the other
    /// row is not saved, and nothing else says so.
    private var hasDuplicateReplacements: Bool {
        let spokenWords = replacements
            .map { $0.spoken.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Set(spokenWords).count != spokenWords.count
    }

    /// Rebuild the stored dictionary from the rows, dropping only rows with no
    /// heard word to match. A blank written word is kept rather than dropped: it
    /// means "delete this word" rather than "do nothing", and TextProcessor
    /// already treats an empty replacement that way.
    private func commitReplacements() {
        var result: [String: String] = [:]
        for row in replacements {
            let spoken = row.spoken.trimmingCharacters(in: .whitespaces)
            let written = row.written.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty else { continue }
            result[spoken] = written
        }
        settings.wordReplacements = result
    }
}

// MARK: - Per-App Profiles

struct AppProfilesSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig

    @State private var profiles: [AppProfile] = []

    var body: some View {
        Form {
            ForEach($profiles) { $profile in
                Section {
                    Toggle(profile.appName, isOn: $profile.isEnabled)
                        .font(.headline)
                        .onChange(of: profile.isEnabled) { _, _ in commit() }

                    Picker("Prompt", selection: Binding(
                        get: { profile.promptId },
                        set: { profile.promptId = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as UUID?)
                        // Every prompt, not just the visible ones: hidden means hidden
                        // from the menu bar dropdown, and a profile already pointing at
                        // one would otherwise show an empty picker.
                        ForEach(promptConfig.prompts) { prompt in
                            Text(prompt.name).tag(prompt.id as UUID?)
                        }
                    }
                    .disabled(!profile.isEnabled)

                    Picker("Output", selection: Binding(
                        get: { profile.outputModeRaw },
                        set: { profile.outputModeRaw = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as String?)
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue as String?)
                        }
                    }
                    .disabled(!profile.isEnabled)

                    Picker("Press Return after typing", selection: Binding(
                        get: { profile.autoSubmit },
                        set: { profile.autoSubmit = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as Bool?)
                        Text("Yes").tag(true as Bool?)
                        Text("No").tag(false as Bool?)
                    }
                    .disabled(!profile.isEnabled)

                    Button("Remove Profile", role: .destructive) {
                        profiles.removeAll { $0.id == profile.id }
                        commit()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                Button("Add App…", systemImage: "plus") {
                    addApp()
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("A profile overrides the prompt or output for one app. The app you start talking in picks the prompt. The app in front when the text is ready decides how it arrives.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        profiles = settings.appProfiles.values
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    private func commit() {
        settings.appProfiles = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0) }
        )
    }

    /// Choose an app from the Applications folder, as System Settings does for login
    /// items, so it need not be running and the user never types a bundle identifier.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        guard !profiles.contains(where: { $0.bundleIdentifier == bundleID }) else { return }

        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        profiles.append(AppProfile(
            bundleIdentifier: bundleID,
            appName: name,
            promptId: nil,
            outputModeRaw: nil,
            autoSubmit: nil
        ))
        profiles.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        commit()
    }
}

// MARK: - Diarization Model Management

/// Status and updates for the CoreML speaker models.
///
/// FluidAudio downloads these once and never looks again — its only test is whether
/// the file exists, so an install keeps whatever the repository held that day forever.
/// This is the missing half: check the installed files against the hashes the
/// repository publishes, and replace them on request.
struct DiarizationModelsSection: View {

    @State private var isInstalled = false
    @State private var sizeLabel = ""
    @State private var installedAt: Date?

    @State private var isChecking = false
    @State private var isUpdating = false
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var checkResult: CheckResult?

    enum CheckResult: Equatable {
        case upToDate(Date?)
        case updateAvailable(Date?, changedFiles: Int)
        case failed(String)
    }

    var body: some View {
        Section("Speaker Models") {
            status
                .onAppear(perform: refresh)

            if isInstalled {
                HStack(spacing: 12) {
                    Button {
                        check()
                    } label: {
                        if isChecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(isChecking || isUpdating)

                    if case .updateAvailable = checkResult {
                        Button(isUpdating ? "Updating…" : "Update Now") { update() }
                            .disabled(isUpdating)
                    } else {
                        // Always reachable: a check that reports a problem must leave
                        // the user something to press.
                        Button(isUpdating ? "Downloading…" : "Re-download Models") { update() }
                            .disabled(isChecking || isUpdating)
                    }
                }

                if let checkResult {
                    resultLabel(checkResult)
                }

                Text("Checking verifies every installed file against the content hash HuggingFace publishes — SHA-256 for model weights, git blob hashes for the rest. No audio or transcript leaves your Mac; it reads public metadata only. Re-downloading fetches fresh copies now and replaces the local ones; if the download fails, the current copies stay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(isInstalling ? "Installing…" : "Install Models") { install() }
                    .disabled(isInstalling)

                if let installError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var status: some View {
        if isInstalled {
            LabeledContent("Installed") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sizeLabel)
                    if let installedAt {
                        Text(installedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Label("Not installed. Meetings record and transcribe without them; installing adds speaker labels, and downloads about 21 MB from HuggingFace.",
                  systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: CheckResult) -> some View {
        switch result {
        case .upToDate(let date):
            Label {
                Text(date.map { "Verified — contents match the models published \($0.formatted(date: .abbreviated, time: .omitted))" }
                    ?? "Verified — contents match the published models")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)

        case .updateAvailable(let date, let changed):
            Label {
                Text(date.map { "\(changed) file\(changed == 1 ? "" : "s") no longer match — published \($0.formatted(date: .abbreviated, time: .omitted))" }
                    ?? "\(changed) file\(changed == 1 ? "" : "s") do not match the published models")
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Actions

    private func refresh() {
        isInstalled = DiarizationModelStore.isInstalled
        sizeLabel = DiarizationModelStore.sizeOnDisk.formatted(.byteCount(style: .file))
        installedAt = DiarizationModelStore.installedAt
    }

    /// Download the models, which is the only moment Inscribe fetches them.
    ///
    /// Recording never does this: a meeting that reached the network would make an
    /// offline app dependent on a connection at the worst possible moment.
    private func install() {
        isInstalling = true
        installError = nil

        Task {
            do {
                try await DiarizationModelStore.install()
                refresh()
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }

    private func check() {
        isChecking = true
        checkResult = nil

        Task {
            do {
                switch try await DiarizationModelStore.compareWithRemote() {
                case .upToDate(let date):
                    checkResult = .upToDate(date)
                case .updateAvailable(let date, let changed):
                    checkResult = .updateAvailable(date, changedFiles: changed)
                }
                refresh()
            } catch {
                checkResult = .failed(error.localizedDescription)
            }
            isChecking = false
        }
    }

    /// Replace the local copies with fresh ones, now.
    ///
    /// This used to remove them and leave the fetch to the next meeting, which is not
    /// allowed to download, so that meeting recorded without speakers.
    private func update() {
        isUpdating = true

        Task {
            do {
                try await DiarizationModelStore.reinstall()
                checkResult = nil
            } catch {
                checkResult = .failed(error.localizedDescription)
            }
            refresh()
            isUpdating = false
        }
    }
}

// MARK: - Meeting Audio

/// Whether meetings keep their recording, and capture system playback as well as the
/// microphone.
struct MeetingAudioSection: View {
    @Environment(AppSettings.self) private var settings

    /// Disk used by saved recordings, measured once when the section appears. Read in
    /// the body, it listed the recordings folder twice on every redraw.
    @State private var recordingsSize: Int64 = 0

    var body: some View {
        @Bindable var settings = settings

        Section("Meetings") {
            Toggle("Keep the recording after a meeting ends", isOn: $settings.keepMeetingAudio)
                .onAppear { recordingsSize = MeetingAudioStore.totalSize() }

            Text("Lets you play back a line to check whether a speaker was attributed correctly. Roughly 30 MB an hour.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if recordingsSize > 0 {
                Text("Recordings currently use \(recordingsSize.formatted(.byteCount(style: .file))).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Toggle("Record system audio during meetings", isOn: $settings.captureSystemAudioInMeetings)

            Text("Without this a meeting captures only your microphone, so on a video call the other participants are never transcribed and speaker separation has nothing to separate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.captureSystemAudioInMeetings {
                // Nothing here tests the permission. The only test creates a tap, and
                // a refused permission may not refuse one, so the test could report
                // access macOS never gave. It also held the main thread while the audio
                // server answered. A meeting reports system audio that stays silent.
                Button("Open System Settings") {
                    SystemAudioCapture.openSystemSettings()
                }
                .buttonStyle(.link)

                Text("This records everyone audible on the call, not only you. Check that the people you are meeting with are content to be recorded.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
