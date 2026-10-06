import Foundation
import os
import FoundationModels

// MARK: - Sampling Mode

/// Controls how the model selects tokens during generation
enum SamplingMode: Equatable, Hashable {
    case automatic           // Framework default (random sampling)
    case greedy              // Deterministic — always picks most likely token
    case topP(Double)        // Sample from tokens within cumulative probability threshold
    case topK(Int)           // Sample from top K most likely tokens

    /// Convert to a simple case tag for the picker (ignoring associated values)
    var caseTag: String {
        switch self {
        case .automatic: return "automatic"
        case .greedy: return "greedy"
        case .topP: return "topP"
        case .topK: return "topK"
        }
    }
}

// MARK: - SamplingMode Codable

extension SamplingMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "automatic":
            self = .automatic
        case "greedy":
            self = .greedy
        case "topP":
            let threshold = try container.decode(Double.self, forKey: .value)
            self = .topP(threshold)
        case "topK":
            let k = try container.decode(Int.self, forKey: .value)
            self = .topK(k)
        default:
            self = .automatic
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode("automatic", forKey: .type)
        case .greedy:
            try container.encode("greedy", forKey: .type)
        case .topP(let threshold):
            try container.encode("topP", forKey: .type)
            try container.encode(threshold, forKey: .value)
        case .topK(let k):
            try container.encode("topK", forKey: .type)
            try container.encode(k, forKey: .value)
        }
    }
}

// MARK: - Prompt Model

/// A customizable AI prompt for text processing
struct Prompt: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var systemPrompt: String
    var userTemplate: String  // Instructions for the AI; the transcript is appended after them automatically
    var isBuiltIn: Bool
    var isVisible: Bool

    // Generation settings (per-prompt tuning)
    var temperature: Double
    var samplingMode: SamplingMode

    /// Whether the prompt corrects the speaker's words rather than rewriting them.
    ///
    /// When set, `WordGuard` holds the model to it: any word the model drops comes
    /// back, and only punctuation, capitals, repeats and one-for-one word fixes get
    /// through. Off for prompts whose point is to reword, such as a summary.
    var keepsWords: Bool

    init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String,
        userTemplate: String,
        isBuiltIn: Bool = false,
        isVisible: Bool = true,
        temperature: Double = 0.5,
        samplingMode: SamplingMode = .automatic,
        keepsWords: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userTemplate = userTemplate
        self.isBuiltIn = isBuiltIn
        self.isVisible = isVisible
        self.temperature = temperature
        self.samplingMode = samplingMode
        self.keepsWords = keepsWords
    }

    // Custom decoder for backward compatibility with saved prompts missing new fields
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        userTemplate = try container.decode(String.self, forKey: .userTemplate)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.5
        samplingMode = try container.decodeIfPresent(SamplingMode.self, forKey: .samplingMode) ?? .automatic
        keepsWords = try container.decodeIfPresent(Bool.self, forKey: .keepsWords) ?? false
    }

    /// Apply the prompt template to transcribed text.
    ///
    /// Wraps the transcription in <transcription> tags so the model can clearly
    /// distinguish the instructions from the content to process. Older templates,
    /// and the help text that used to sit next to this editor, asked for a literal
    /// `{text}` placeholder; that substitution hasn't existed for a while, so any
    /// leftover `{text}` is dropped rather than left sitting uselessly next to the
    /// transcript that is now appended after it.
    /// The template, then `note` when there is one, then the transcription.
    func apply(to text: String, note: String? = nil) -> String {
        let withoutPlaceholder = userTemplate.replacingOccurrences(of: "{text}", with: "")
        let trimmed = withoutPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = [trimmed, note].compactMap { $0 }.joined(separator: "\n\n")
        return "\(head)\n\n<transcription>\n\(text)\n</transcription>"
    }

    /// Build GenerationOptions from this prompt's per-prompt settings
    func generationOptions() -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode? = switch samplingMode {
        case .automatic: nil
        case .greedy: .greedy
        case .topP(let threshold): .random(probabilityThreshold: threshold)
        case .topK(let k): .random(top: k)
        }

        // Apple documents temperature as 0 to 1 inclusive; a prompt saved before
        // the Settings slider was capped to that range could still hold a higher
        // value, so it is clamped here rather than trusted.
        return GenerationOptions(
            samplingMode: sampling,
            temperature: min(temperature, 1.0)
        )
    }
}

// MARK: - Prompt Manager

/// Manages custom AI prompts, kept in local preferences.
@Observable
final class PromptConfiguration {

    // MARK: - Published State

    private(set) var prompts: [Prompt] = []

    // MARK: - Storage Keys

    private let localKey = "customPrompts"
    private let visibilityKey = "promptVisibility"
    private let generationSettingsKey = "promptGenerationSettings"

    // MARK: - Built-in Prompts

    static let builtInPrompts: [Prompt] = [
        Prompt(
            id: defaultPromptId,
            name: "Clean Up",
            systemPrompt: "You are an expert editor specializing in cleaning spoken transcriptions into polished written prose.",
            userTemplate: """
            Clean up the following transcribed speech into polished written text.

            - Remove filler words (um, uh, like, you know, so, basically, I mean)
            - Rewrite confusing or poorly worded phrases for clarity
            - Eliminate repetitions, false starts, and tangents
            - Combine run-on sentences into clear, concise ones
            - Add paragraph breaks where the topic shifts
            - Improve grammar, punctuation, and sentence structure
            - Add proper punctuation marks throughout
            - Preserve the original meaning, tone, and intent
            """,
            isBuiltIn: true
        ),
        // Began as a custom prompt and became built-in on 2026-10-05. It keeps that
        // prompt's id, so a selection or app profile that pointed at it still does,
        // and `loadPrompts` drops the stored custom copy.
        Prompt(
            id: UUID(uuidString: "E21F58B2-BF22-4CD2-9E28-61815D574548")!,
            name: "Simple Clean",
            systemPrompt: "You correct transcription errors and change nothing else.",
            userTemplate: """
            Fix only what the transcriber got wrong:
            - A misheard word: a sound-alike that makes the sentence wrong (there/their, to/too). Replace only that word.
            - A word repeated by accident ("the the").
            - Punctuation and sentence breaks that don't fit how the words are meant.
            - An ellipsis (…) at a pause: replace it with the punctuation the sentence needs, or remove it.

            Keep every other word exactly as spoken, in the same order, including filler.
            Do not rephrase, add, drop or reorder words, and do not change the tone.
            When unsure, leave the text as it is.
            """,
            isBuiltIn: true,
            temperature: 0.3,
            samplingMode: .greedy,
            keepsWords: true
        ),
        Prompt(
            id: summarizePromptId,
            name: "Summarize",
            systemPrompt: "You are an expert summarizer specializing in distilling spoken transcriptions into concise, structured summaries.",
            userTemplate: """
            Summarize the following transcribed speech into a concise, structured summary.

            - Identify the key points and main ideas
            - Group related points by theme or topic
            - Use a bulleted list format for clarity
            - Preserve important details, names, numbers, and decisions
            - Remove filler words, repetitions, and tangents
            - Keep the original meaning and intent intact
            - Be concise — aim for roughly 20-30% of the original length
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Make Formal",
            systemPrompt: "You are an expert editor specializing in transforming casual spoken transcriptions into polished, professional written prose.",
            userTemplate: """
            Rewrite the following transcribed speech in a formal, professional tone.

            - Elevate vocabulary and use precise, professional language
            - Replace slang, colloquialisms, and casual expressions with formal equivalents
            - Use complete, well-structured sentences
            - Maintain a professional and authoritative tone throughout
            - Preserve the original meaning and key information
            - Add proper structure with paragraph breaks at topic changes
            - Improve grammar, punctuation, and sentence flow
            - Remove filler words, repetitions, and false starts
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Make Casual",
            systemPrompt: "You are an expert editor specializing in transforming formal or stiff transcriptions into natural, conversational written prose.",
            userTemplate: """
            Rewrite the following transcribed speech in a casual, friendly tone.

            - Use everyday, conversational language
            - Replace jargon or overly formal words with simpler alternatives
            - Keep a friendly, approachable tone throughout
            - Use contractions naturally (don't, can't, it's, etc.)
            - Preserve the original meaning and key information
            - Clean up filler words, repetitions, and false starts
            - Add paragraph breaks where the topic shifts
            - Improve grammar and punctuation while keeping it relaxed
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Fix Punctuation",
            systemPrompt: "You are an expert punctuation editor specializing in adding proper punctuation to spoken transcriptions without altering any words.",
            userTemplate: """
            Add proper punctuation to the following transcribed speech.

            - Add periods, commas, question marks, and exclamation points where appropriate
            - Add paragraph breaks where the topic or thought changes
            - Use em dashes, semicolons, and colons where they improve readability
            - Capitalize the first word of each sentence and proper nouns
            - Do NOT change, add, or remove any words — only add punctuation and capitalization
            - Preserve the exact wording and order of the original text
            """,
            isBuiltIn: true,
            keepsWords: true
        ),
        // Not a prompt anyone picks from a list of prompts: it is how "Off" is stored
        // where a prompt id is expected, such as an app profile that turns rewriting
        // off for one app. `rewritingPrompts` leaves it out.
        Prompt(
            id: rawPromptId,
            name: "Off",
            systemPrompt: "",
            userTemplate: "",
            isBuiltIn: true
        )
    ]

    /// The id that stands for "no rewriting", where a prompt id is expected.
    static let rawPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The default "Clean Up" prompt ID
    static let defaultPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The built-in "Summarize" prompt ID
    static let summarizePromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Initialization

    init() {
        loadPrompts()
        Log.prompts.notice("Initialized with \(self.prompts.count, privacy: .public) prompts")
    }

    // MARK: - Public API

    /// Get a prompt by ID
    func prompt(withId id: UUID) -> Prompt? {
        prompts.first { $0.id == id }
    }

    /// Get all custom (non-built-in) prompts
    var customPrompts: [Prompt] {
        prompts.filter { !$0.isBuiltIn }
    }

    /// Every prompt that rewrites, which is all of them but the stand-in for "Off".
    var rewritingPrompts: [Prompt] {
        prompts.filter { $0.id != Self.rawPromptId }
    }

    /// Get all built-in prompts
    var builtInPromptsList: [Prompt] {
        rewritingPrompts.filter { $0.isBuiltIn }
    }

    /// Toggle visibility for a prompt (works for both built-in and custom)
    func toggleVisibility(promptId: UUID) {
        guard let index = prompts.firstIndex(where: { $0.id == promptId }) else { return }
        prompts[index].isVisible.toggle()
        saveVisibility()
        if !prompts[index].isBuiltIn {
            savePrompts()
        }
    }

    /// Update generation settings for any prompt (including built-in)
    func updateGenerationSettings(
        promptId: UUID,
        temperature: Double,
        samplingMode: SamplingMode
    ) {
        guard let index = prompts.firstIndex(where: { $0.id == promptId }) else { return }
        prompts[index].temperature = temperature
        prompts[index].samplingMode = samplingMode

        if prompts[index].isBuiltIn {
            saveGenerationSettings()
        } else {
            savePrompts()
        }
        Log.prompts.debug("Updated generation settings for: \(self.prompts[index].name)")
    }

    /// Add a new custom prompt
    func addPrompt(_ prompt: Prompt) {
        let newPrompt = Prompt(
            id: prompt.id,
            name: prompt.name,
            systemPrompt: prompt.systemPrompt,
            userTemplate: prompt.userTemplate,
            isBuiltIn: false,
            isVisible: prompt.isVisible,
            temperature: prompt.temperature,
            samplingMode: prompt.samplingMode,
            keepsWords: prompt.keepsWords
        )
        prompts.append(newPrompt)
        savePrompts()
        Log.prompts.notice("Added prompt: \(newPrompt.name)")
    }

    /// Update an existing prompt (only custom prompts can be updated)
    func updatePrompt(_ prompt: Prompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else {
            Log.prompts.error("Prompt not found for update: \(prompt.id)")
            return
        }

        guard !prompts[index].isBuiltIn else {
            Log.prompts.notice("Cannot update built-in prompt: \(prompt.name)")
            return
        }

        prompts[index] = prompt
        savePrompts()
        Log.prompts.debug("Updated prompt: \(prompt.name)")
    }

    /// Delete a prompt (only custom prompts can be deleted)
    func deletePrompt(withId id: UUID) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else {
            Log.prompts.error("Prompt not found for deletion: \(id, privacy: .public)")
            return
        }

        guard !prompts[index].isBuiltIn else {
            Log.prompts.notice("Cannot delete built-in prompt")
            return
        }

        let removed = prompts.remove(at: index)
        savePrompts()
        Log.prompts.notice("Deleted prompt: \(removed.name)")
    }

    // MARK: - Persistence

    private func loadPrompts() {
        // Start with built-in prompts
        var loadedPrompts = Self.builtInPrompts

        if let data = UserDefaults.standard.data(forKey: localKey) {
            let customPrompts = Self.decodePromptsSkippingFailures(from: data)
            // A custom prompt that has since become built-in is kept under its old id,
            // and the built-in copy wins.
            let builtInIds = Set(Self.builtInPrompts.map(\.id))
            loadedPrompts.append(contentsOf: customPrompts.filter { !$0.isBuiltIn && !builtInIds.contains($0.id) })
            Log.prompts.notice("Loaded \(customPrompts.count, privacy: .public) custom prompts")
        }

        // Apply saved visibility settings (for built-in prompts)
        let savedVisibility = loadVisibility()
        for (index, prompt) in loadedPrompts.enumerated() {
            if let visible = savedVisibility[prompt.id.uuidString] {
                loadedPrompts[index].isVisible = visible
            }
        }

        // Apply saved generation settings (for built-in prompts)
        let savedGenSettings = loadGenerationSettings()
        for (index, prompt) in loadedPrompts.enumerated() where prompt.isBuiltIn {
            if let settings = savedGenSettings[prompt.id.uuidString] {
                loadedPrompts[index].temperature = settings.temperature
                loadedPrompts[index].samplingMode = settings.samplingMode
            }
        }

        self.prompts = loadedPrompts
    }

    /// Decode each stored prompt on its own, rather than the array as a whole.
    ///
    /// `JSONDecoder` fails an entire `[Prompt]` decode the moment one element is
    /// malformed, and the only thing left to load then is an empty list — which the
    /// next call to `savePrompts` would write back, permanently wiping every custom
    /// prompt the user had, not just the corrupt one. Decoding element by element
    /// means one bad prompt is dropped and logged instead of taking the rest down
    /// with it.
    private static func decodePromptsSkippingFailures(from data: Data) -> [Prompt] {
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            Log.prompts.error("Custom prompts data is not a JSON array; ignoring it")
            return []
        }

        return rawArray.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else {
                Log.prompts.error("Could not re-serialize a stored prompt; skipping it")
                return nil
            }
            do {
                return try JSONDecoder().decode(Prompt.self, from: elementData)
            } catch {
                Log.prompts.error("Skipping a corrupt custom prompt: \(error, privacy: .public)")
                return nil
            }
        }
    }

    private func saveVisibility() {
        // Save visibility map for all prompts (keyed by UUID string)
        var visibilityMap: [String: Bool] = [:]
        for prompt in prompts {
            visibilityMap[prompt.id.uuidString] = prompt.isVisible
        }
        UserDefaults.standard.set(visibilityMap, forKey: visibilityKey)
    }

    private func loadVisibility() -> [String: Bool] {
        return UserDefaults.standard.dictionary(forKey: visibilityKey) as? [String: Bool] ?? [:]
    }

    // MARK: - Generation Settings Persistence (for built-in prompts)

    /// Codable container for persisting per-prompt generation settings
    private struct StoredGenerationSettings: Codable {
        var temperature: Double
        var samplingMode: SamplingMode
    }

    private func saveGenerationSettings() {
        var settingsMap: [String: StoredGenerationSettings] = [:]
        for prompt in prompts where prompt.isBuiltIn {
            settingsMap[prompt.id.uuidString] = StoredGenerationSettings(
                temperature: prompt.temperature,
                samplingMode: prompt.samplingMode
            )
        }
        if let data = try? JSONEncoder().encode(settingsMap) {
            UserDefaults.standard.set(data, forKey: generationSettingsKey)
        }
    }

    private func loadGenerationSettings() -> [String: StoredGenerationSettings] {
        guard let data = UserDefaults.standard.data(forKey: generationSettingsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredGenerationSettings].self, from: data)) ?? [:]
    }

    private func savePrompts() {
        // Only save custom prompts
        let customPrompts = prompts.filter { !$0.isBuiltIn }

        do {
            let data = try JSONEncoder().encode(customPrompts)

            UserDefaults.standard.set(data, forKey: localKey)

            Log.prompts.debug("Saved \(customPrompts.count, privacy: .public) custom prompts")
        } catch {
            Log.prompts.error("Error encoding prompts: \(error, privacy: .public)")
        }
    }
}
