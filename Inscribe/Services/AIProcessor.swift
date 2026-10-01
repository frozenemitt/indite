import Foundation
import os
import FoundationModels

// MARK: - Structured Output

/// Constrains the model to return only the processed text — no commentary or preamble.
/// The @Generable macro enforces a JSON schema at the token level, so the model
/// physically cannot produce output outside this single field.
@Generable
struct TranscriptionResult {
    @Guide(description: "The rewritten transcription text only, with no commentary or explanation")
    var text: String
}

/// A meeting's title, constrained the same way.
@Generable
struct MeetingTitle {
    @Guide(description: "A title of three to seven words naming what the meeting was about")
    var title: String
}

/// AI-powered text processor using Apple's on-device FoundationModels
@MainActor
final class AIProcessor {

    // MARK: - State

    /// A session built and loaded while the user was still speaking.
    ///
    /// The model has to be in memory before it can answer, and that load used to begin
    /// only once the dictation had finished — seconds the user spends watching a
    /// spinner, when they had just spent seconds talking. Starting it at the same
    /// moment as the recording hides the whole thing behind speech.
    ///
    /// Used once and dropped. A `LanguageModelSession` carries its own transcript, so
    /// keeping one across dictations would let the last one see the one before it.
    /// Keyed on the instructions text as well as the prompt id: editing a prompt
    /// keeps its id, and a session already warmed with the old wording would
    /// otherwise run those stale instructions on the next dictation.
    private var warmSession: LanguageModelSession?
    private var warmPromptId: UUID?
    private var warmInstructions: String?

    // MARK: - Configuration

    let promptConfiguration: PromptConfiguration

    // MARK: - Initialization

    init(promptConfiguration: PromptConfiguration) {
        self.promptConfiguration = promptConfiguration
    }

    // MARK: - Public API

    /// Process text with the specified prompt
    /// - Parameters:
    ///   - text: The transcribed text to process
    ///   - promptId: The ID of the prompt to use (nil = use default)
    /// - Returns: Processed text
    /// - Parameter surroundingText: What is already in the field being dictated into.
    ///   Given to the model as background so a reply matches the thread it belongs to.
    ///   It is explicitly marked as context to be read but not rewritten.
    /// - Parameter usesWarmSession: True only for the dictation that called `prewarm`.
    ///   Every other request builds its own session and leaves the warm one alone.
    /// - Parameter onPartial: Called with the rewrite so far, each time it grows, for
    ///   a caller that shows it while the model is still writing.
    func process(
        text: String,
        promptId: UUID? = nil,
        surroundingText: String? = nil,
        usesWarmSession: Bool = false,
        onPartial: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        // Get the prompt
        let effectivePromptId = promptId ?? PromptConfiguration.defaultPromptId
        guard let prompt = promptConfiguration.prompt(withId: effectivePromptId) else {
            throw AIProcessorError.promptNotFound
        }

        // Skip processing for "Raw" prompt
        if prompt.id == PromptConfiguration.rawPromptId {
            Log.ai.notice("Using raw prompt, returning text unchanged")
            return text
        }

        return try await processWithPrompt(
            text: text,
            prompt: prompt,
            surroundingText: surroundingText,
            usesWarmSession: usesWarmSession,
            onPartial: onPartial
        )
    }

    /// Write a short title for a meeting from the start of its transcript.
    ///
    /// The opening only: a meeting's subject is nearly always named in its first
    /// minutes, and 5,000 characters fit the smallest context the model has. Tried on
    /// nine recorded meetings of 2,000 to 18,000 characters, each title took about a
    /// second and named that meeting's own subject. Asking for sentence case made the
    /// titles worse, so the model's capitals are left as they come.
    ///
    /// Greedy, so the same meeting gets the same title.
    func title(forMeetingTranscript transcript: String) async throws -> String {
        guard FoundationModelsHelper.isCurrentLocaleSupported() else {
            throw AIProcessorError.languageNotSupported
        }
        if let reason = FoundationModelsHelper.unavailabilityReason() {
            throw AIProcessorError.appleIntelligenceUnavailable(reason)
        }

        let session = FoundationModelsHelper.createSession(
            instructions: "You name meetings. Given what was said in one, you write a short, specific title that tells it apart from other meetings."
        )
        let prompt = """
            Write a title for this meeting, three to seven words. Name the subject that was discussed. \
            Do not use the words meeting, discussion, conversation or call. No quotation marks and no full stop.

            <transcript>
            \(transcript.prefix(5000))
            </transcript>
            """
        let result = try await FoundationModelsHelper.generateStructured(
            session: session,
            prompt: prompt,
            generating: MeetingTitle.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        let title = result.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”."))
        guard !title.isEmpty else { throw AIProcessorError.emptyResult }
        return title
    }

    /// Load the model for the prompt this dictation will use, while it is being spoken.
    ///
    /// Silent about failure on purpose: this is an optimisation, and a dictation whose
    /// prewarm did not happen simply takes as long as it used to.
    func prewarm(promptId: UUID?) {
        guard FoundationModelsHelper.isCurrentLocaleSupported() else { return }
        guard let prompt = resolvedPrompt(for: promptId) else { return }
        guard warmPromptId != prompt.id || warmInstructions != prompt.systemPrompt else { return }

        let session = FoundationModelsHelper.createSession(instructions: prompt.systemPrompt)
        session.prewarm()
        warmSession = session
        warmPromptId = prompt.id
        warmInstructions = prompt.systemPrompt
        Log.ai.notice("prewarmed the model")
    }

    /// The prompt a dictation with this id will actually run, or nothing when it will
    /// not run one at all.
    private func resolvedPrompt(for promptId: UUID?) -> Prompt? {
        let id = promptId ?? PromptConfiguration.defaultPromptId
        guard let prompt = promptConfiguration.prompt(withId: id) else { return nil }
        guard prompt.id != PromptConfiguration.rawPromptId else { return nil }
        return prompt
    }

    /// Warm the loaded session on the words already confirmed, while more are spoken.
    ///
    /// The request that follows the key release starts with exactly this text — the
    /// same template, context and transcript, up to where the recognizer has got to —
    /// so the model has already read most of it when the request arrives. Measured
    /// saving: 0.2–0.3 s on a 733-character dictation with four fifths of it warmed.
    /// Writing the answer is the rest of the wait, and nothing here shortens it.
    ///
    /// Does nothing when no session was warmed at the start, or when it was warmed for
    /// a different prompt.
    func warmPrefix(promptId: UUID?, transcriptSoFar: String, surroundingText: String?) {
        guard let warmSession, let prompt = resolvedPrompt(for: promptId),
              warmPromptId == prompt.id, warmInstructions == prompt.systemPrompt else { return }

        let full = Self.userPrompt(for: prompt, text: transcriptSoFar, surroundingText: surroundingText)
        let closing = "\n</transcription>"
        let prefix = full.hasSuffix(closing) ? String(full.dropLast(closing.count)) : full
        warmSession.prewarm(promptPrefix: FoundationModels.Prompt(prefix))
    }

    /// Forget a warmed session that will not be used.
    func discardPrewarm() {
        warmSession = nil
        warmPromptId = nil
        warmInstructions = nil
    }

    // MARK: - Private Implementation

    private func processWithPrompt(
        text: String,
        prompt: Prompt,
        surroundingText: String? = nil,
        usesWarmSession: Bool = false,
        onPartial: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        guard !text.isEmpty else {
            throw AIProcessorError.emptyInput
        }

        // Check language support
        guard FoundationModelsHelper.isCurrentLocaleSupported() else {
            throw AIProcessorError.languageNotSupported
        }

        // Fail with a clear reason before spending any time on a session that can
        // never answer, rather than letting the request reach the model and come
        // back with whatever generic error the SDK happens to throw.
        if let reason = FoundationModelsHelper.unavailabilityReason() {
            throw AIProcessorError.appleIntelligenceUnavailable(reason)
        }

        Log.ai.notice("Processing with prompt: \(prompt.name)")

        // The session warmed while this was being spoken, if it was warmed for this
        // prompt with its current instructions. Taken rather than borrowed: a
        // session carries its own transcript, so the next dictation gets a fresh one.
        // Only the dictation that loaded it may take it. Any other request, such as a
        // meeting summary running while the user dictates, builds its own session even
        // when its prompt is the same one.
        let session: LanguageModelSession
        if usesWarmSession, let warmSession,
           warmPromptId == prompt.id, warmInstructions == prompt.systemPrompt {
            session = warmSession
            discardPrewarm()
        } else {
            session = FoundationModelsHelper.createSession(instructions: prompt.systemPrompt)
        }

        let userPrompt = Self.userPrompt(for: prompt, text: text, surroundingText: surroundingText)

        // Use per-prompt generation settings with structured output
        let options = prompt.generationOptions()

        do {
            let result: TranscriptionResult
            if let onPartial {
                let started = ContinuousClock.now
                var reportedFirst = false
                result = try await FoundationModelsHelper.streamTranscription(
                    session: session,
                    prompt: userPrompt,
                    options: options
                ) { partial in
                    if !reportedFirst {
                        reportedFirst = true
                        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
                        Log.ai.notice("First rewritten words after \(ms, privacy: .public) ms")
                    }
                    onPartial(partial)
                }
            } else {
                result = try await FoundationModelsHelper.generateStructured(
                    session: session,
                    prompt: userPrompt,
                    generating: TranscriptionResult.self,
                    options: options
                )
            }
            return keepingWords(of: text, in: try cleaned(result.text), for: prompt)

        // macOS 27 throws the top-level LanguageModelError for these failures, not the
        // deprecated LanguageModelSession.GenerationError.
        } catch LanguageModelError.contextSizeExceeded {
            throw AIProcessorError.contextWindowExceeded
        } catch LanguageModelError.unsupportedLanguageOrLocale {
            throw AIProcessorError.languageNotSupported
        } catch LanguageModelError.guardrailViolation {
            // Guided generation doesn't benefit from the permissive guardrail level
            // (see the comment on `permissiveModel`), so before giving up, ask once
            // more for plain text, which does.
            do {
                let retried = try await FoundationModelsHelper.generateTextAfterGuardrailViolation(
                    instructions: prompt.systemPrompt,
                    prompt: userPrompt,
                    options: options
                )
                let result = keepingWords(of: text, in: try cleaned(retried), for: prompt)
                Log.ai.notice("Recovered from a guardrail violation by asking for plain text")
                return result
            } catch {
                throw AIProcessorError.guardrailViolation
            }
        } catch let error as AIProcessorError {
            // An empty result from `cleaned` reaches the caller as itself, not
            // wrapped by the clause below as a generic processing failure.
            throw error
        } catch {
            throw AIProcessorError.processingFailed(error.localizedDescription)
        }
    }

    /// The request the model receives: the template, the transcript, and any
    /// surrounding text.
    ///
    /// One function for the real request and for warming, so the warmed prefix is the
    /// request's own opening, character for character. Any difference and the warming
    /// buys nothing.
    private static func userPrompt(for prompt: Prompt, text: String, surroundingText: String?) -> String {
        let request = prompt.apply(to: text)

        // Prepended, and fenced off in its own tags, so the model treats it as
        // background rather than as more text to rewrite. Without the fencing the
        // model tends to "clean up" the surrounding document too and hand it back.
        guard let surroundingText, !surroundingText.isEmpty else { return request }
        return """
            <context>
            The user is dictating into a text field that already contains the \
            following. Use it only to match tone, terminology and the thread of \
            the conversation. Do not repeat it, summarise it, or include any of \
            it in your reply.

            \(surroundingText)
            </context>

            \(request)
            """
    }

    /// Hold a prompt that keeps the speaker's words to it; see `WordGuard`.
    private func keepingWords(of said: String, in rewrite: String, for prompt: Prompt) -> String {
        guard prompt.keepsWords else { return rewrite }
        let outcome = WordGuard.apply(said: said, rewrite: rewrite)
        if outcome.restored > 0 || outcome.removed > 0 {
            Log.ai.notice("Word check put back \(outcome.restored, privacy: .public) words and took out \(outcome.removed, privacy: .public) added ones")
        }
        return outcome.text
    }

    /// Strip tags the model sometimes echoes back, and fail loudly on an empty
    /// result rather than handing the caller nothing to paste. The raw transcript
    /// exists nowhere else once this returns, so silence here would lose the
    /// dictation outright rather than merely skip the rewrite.
    private func cleaned(_ text: String) throws -> String {
        let cleaned = text
            .replacingOccurrences(of: "<transcription>", with: "")
            .replacingOccurrences(of: "</transcription>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            throw AIProcessorError.emptyResult
        }

        Log.ai.notice("Processing complete, result length: \(cleaned.count, privacy: .public)")
        return cleaned
    }

    // MARK: - Model Information

    /// Why Apple Intelligence cannot answer right now, or nil when it can.
    ///
    /// For Settings, so a user who has switched AI processing on but never turned
    /// on Apple Intelligence — or whose Mac cannot run it at all — sees why, rather
    /// than discovering it as a mysterious failure the first time they dictate.
    static var unavailabilityReason: String? {
        FoundationModelsHelper.unavailabilityReason()
    }
}

// MARK: - Errors

enum AIProcessorError: Error, LocalizedError {
    case promptNotFound
    case emptyInput
    case emptyResult
    case languageNotSupported
    case appleIntelligenceUnavailable(String)
    case contextWindowExceeded
    case guardrailViolation
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .promptNotFound:
            return "The selected prompt could not be found"
        case .emptyInput:
            return "No text to process"
        case .emptyResult:
            return "The AI returned no text, so nothing was changed."
        case .languageNotSupported:
            return "The current language is not supported for AI processing"
        case .appleIntelligenceUnavailable(let reason):
            return reason
        case .contextWindowExceeded:
            return "The text is too long to process"
        case .guardrailViolation:
            return "Apple's on-device model declined to process this text."
        case .processingFailed(let reason):
            return "Processing failed: \(reason)"
        }
    }
}
