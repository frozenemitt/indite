import SwiftUI

// MARK: - Rewriting Settings

/// Whether the AI rewrites a dictation, and the prompts it can do that with.
///
/// The switch and the default prompt used to sit in General while the prompts
/// themselves sat in a tab of their own.
struct RewritingSettingsView: View {
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(AppSettings.self) private var settings

    /// What the list has selected: the options page, or one prompt.
    private enum Selection: Hashable {
        case options
        case prompt(UUID)
    }

    @State private var selection: Selection? = .options

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selection) {
                    Label("Options", systemImage: "slider.horizontal.3")
                        .tag(Selection.options)

                    Section {
                        ForEach(promptConfig.builtInPromptsList) { prompt in
                            PromptRow(prompt: prompt) {
                                promptConfig.toggleVisibility(promptId: prompt.id)
                            }
                            .tag(Selection.prompt(prompt.id))
                        }
                    } header: {
                        promptsHeader("Built-in Prompts")
                    }

                    if !promptConfig.customPrompts.isEmpty {
                        Section {
                            ForEach(promptConfig.customPrompts) { prompt in
                                PromptRow(prompt: prompt) {
                                    promptConfig.toggleVisibility(promptId: prompt.id)
                                }
                                .tag(Selection.prompt(prompt.id))
                            }
                            .onDelete { indexSet in
                                deletePrompts(at: indexSet)
                            }
                        } header: {
                            promptsHeader("Custom Prompts")
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
                        selection = .prompt(newPrompt.id)
                    }
                    .help("Add Prompt")

                    Button("Delete Prompt", systemImage: "minus") {
                        if let id = selectedPromptId {
                            deletePrompt(id: id)
                        }
                    }
                    .help("Delete Prompt")
                    .disabled(isBuiltIn(selectedPromptId))

                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 240)

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
                            selection = .prompt(newPrompt.id)
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
                    RewritingOptionsView()
                }
            }
            .frame(minWidth: 300)
        }
    }

    private var selectedPromptId: UUID? {
        if case .prompt(let id) = selection { return id }
        return nil
    }

    /// A heading for a list of prompts, naming the switch at the end of each row. On
    /// its own the switch read as "enabled", and what it sets is whether the prompt is
    /// offered in the menu.
    private func promptsHeader(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("In menu")
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
        selection = .options
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

// MARK: - Options

/// Whether dictations are rewritten, with which prompt, and what the AI may read.
private struct RewritingOptionsView: View {
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Toggle("Rewrite dictations", isOn: $settings.aiEnabled)

                if let reason = AIProcessor.unavailabilityReason {
                    Label {
                        Text(reason)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }

                // Nil and the default's own id both mean Clean Up. The menu stores the
                // id when Clean Up is picked there, which a separate row for nil could
                // not show, so the picker went blank.
                Picker("With", selection: Binding(
                    get: { settings.selectedPromptId ?? PromptConfiguration.defaultPromptId },
                    set: { settings.selectedPromptId = $0 }
                )) {
                    ForEach(promptConfig.rewritingPrompts) { prompt in
                        Text(prompt.name).tag(prompt.id)
                    }
                }
                .disabled(!settings.aiEnabled)

                Text("Rewriting uses Apple’s on-device model. Nothing leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Let the AI see what is already in the field", isOn: $settings.useSurroundingContext)
                    .disabled(!settings.aiEnabled)
                    .help("Reads the text around your cursor, so a dictated reply matches the thread it belongs to.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Prompt Row

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

            Toggle("Show in Menu", isOn: Binding(
                get: { prompt.isVisible },
                set: { _ in onToggleVisibility() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(prompt.isVisible ? "Offered in the menu" : "Hidden from the menu")
        }
    }
}

// MARK: - Prompt Editor

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

    @State private var showsAdvanced = false

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
            if !canEdit {
                duplicateSection
            }

            Section {
                TextField("Name", text: $name)
                    .disabled(!canEdit)
            }

            // Instructions to a model are prose, set in the system font as Shortcuts
            // sets them. Monospaced, they read as code.
            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .font(.body)
                    .frame(minHeight: 80)
                    .disabled(!canEdit)
            }

            Section("User Template") {
                TextEditor(text: $userTemplate)
                    .font(.body)
                    .frame(minHeight: 80)
                    .disabled(!canEdit)

                Text("Your dictation is added after these instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep my words", isOn: $keepsWords)
                    .disabled(!canEdit)
                    .help("For prompts that correct rather than reword. Any word the model drops is put back, and only punctuation, capitals, repeated words and one-for-one word fixes get through.")
            }

            // How the model picks its words. Editable for built-in prompts too, and
            // folded away: at the same weight as the name and the instructions, three
            // sampling dials read as things every prompt has to set.
            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
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
            }

            if canEdit {
                duplicateSection
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
