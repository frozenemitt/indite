import Foundation
import FoundationModels

/// A helper class for working with Foundation Models framework
/// Provides convenient methods for text generation, structured output, and session management
@MainActor
class FoundationModelsHelper {

    // MARK: - Model Configuration

    /// The shared language model configured with permissive guardrails.
    /// This allows the model to faithfully process user content that contains
    /// profanity or other language that default guardrails would reject.
    /// Apple's `.permissiveContentTransformations` is designed specifically for
    /// apps that transform existing user content (e.g. cleaning up transcriptions) —
    /// but Apple documents that it only relaxes the checks applied to a plain `String`
    /// response. Any other response type is screened as strictly as the default
    /// guardrails, and on macOS 27 that screen throws `LanguageModelError.refusal`.
    static let permissiveModel = SystemLanguageModel(
        guardrails: .permissiveContentTransformations
    )

    // MARK: - Session Management

    /// Creates a new session with custom instructions using permissive guardrails
    /// - Parameter instructions: The system instructions for the session
    /// - Returns: A configured LanguageModelSession
    static func createSession(instructions: String) -> LanguageModelSession {
        return LanguageModelSession(model: permissiveModel, instructions: instructions)
    }

    // MARK: - Text Generation

    /// Generate a plain-text response
    /// - Parameters:
    ///   - session: The language model session
    ///   - prompt: The user prompt
    ///   - options: Generation options for controlling sampling
    /// - Returns: Generated text content
    static func generateText(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions
    ) async throws -> String {
        try await session.respond(to: prompt, options: options).content
    }

    /// Generate structured output using Generable types
    /// - Parameters:
    ///   - session: The language model session
    ///   - prompt: The user prompt
    ///   - type: The Generable type to generate
    ///   - options: Generation options for controlling sampling
    /// - Returns: An instance of the specified Generable type
    static func generateStructured<T: Generable>(
        session: LanguageModelSession,
        prompt: String,
        generating type: T.Type,
        options: GenerationOptions
    ) async throws -> T {
        try await session.respond(to: prompt, generating: type, options: options).content
    }

    /// Generate a plain-text answer, handing each partial version to `onPartial`
    /// as it is written.
    ///
    /// Takes as long as asking for the whole answer at once — measured at 3.0–3.1 s
    /// either way for 733 characters — but the first words exist after about 0.7 s
    /// instead of at the end, so the panel can show them while the rest is written.
    ///
    /// The answer is returned as written. Measured on the macOS 27 model, 164
    /// plain-text Clean Up and Summarize answers never opened with a preamble such
    /// as "Here is the text:". A first line ending in a colon was always the user's
    /// own content, like "Agenda for tomorrow:", so stripping one would delete real
    /// text.
    static func streamText(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        onPartial: @MainActor (String) -> Void
    ) async throws -> String {
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            // A pass the deadline cancelled stops here, even if the stream goes on
            // yielding. Otherwise the old rewrite kept streaming into the next
            // dictation's panel.
            try Task.checkCancellation()
            if !snapshot.content.isEmpty {
                onPartial(snapshot.content)
            }
        }
        return try await stream.collect().content
    }

    // MARK: - Language Support

    /// Check if the current locale is supported by Foundation Models.
    ///
    /// Uses the framework's own `supportsLocale`, which accounts for regional
    /// fallbacks — a locale like `en-CA` that is not itself a member of
    /// `supportedLanguages` but falls back to a supported base language — where
    /// testing set membership directly would wrongly reject it.
    /// - Returns: True if the current locale is supported
    static func isCurrentLocaleSupported() -> Bool {
        permissiveModel.supportsLocale()
    }

    // MARK: - Model Availability

    /// Why Apple Intelligence cannot answer right now, or nil when it can.
    ///
    /// Distinct from the language check above: a supported locale on a Mac where
    /// Apple Intelligence was never turned on, or is still downloading its model,
    /// would otherwise fail the same way a real request does — with whatever
    /// generic error the SDK happens to throw once the request is already under
    /// way, rather than a message that explains why up front.
    static func unavailabilityReason() -> String? {
        switch permissiveModel.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                return "Apple Intelligence is still downloading its model. Try again shortly."
            @unknown default:
                return "Apple Intelligence is not available right now."
            }
        }
    }

}
