#if canImport(FoundationModels)
import Foundation
import FoundationModels
import WispritKit

/// The real generator: Apple Intelligence, in-process, no subprocess.
///
/// Replaces the `wisprit_refine` helper the Python drove over a pipe. The
/// subprocess existed only because Python cannot link FoundationModels; every
/// behavior it carried (permissive guardrails, prewarm-on-press, greedy
/// sampling, the token budget) lives here unchanged.
///
/// An actor because `LanguageModelSession` is a non-Sendable class that must be
/// touched from one place at a time. Serializing here costs nothing: requests
/// serialize on the system daemon anyway, so parallel sessions do not help.
public actor SystemModelGenerator: RefineGenerating {

    // Permissive transformation guardrails: Apple's documented mode for apps
    // that transform user-provided content. Dictated words must be cleaned, not
    // judged — under .default guardrails, benign dictations sporadically throw
    // guardrailViolation (widely reported), which would force verbatim fallback.
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private var session: LanguageModelSession?
    private let log = WLog.logger("refine")

    public init() {}

    public func probe() async -> RefineAvailability {
        // SystemLanguageModel.default reports the same asset/enablement state as
        // the permissive-guardrails instance; guardrails are a request-time
        // policy, not a capability.
        switch SystemLanguageModel.default.availability {
        case .available:
            return RefineAvailability(available: true)
        case .unavailable(let reason):
            return RefineAvailability(available: false, reason: String(describing: reason))
        }
    }

    /// Build + prewarm at record START so the model loads while the user is
    /// still speaking and `generate` starts producing with no warm-up cost. The
    /// promptPrefix lets the framework pre-process the shared prompt tokens (KV
    /// cache) too.
    public func prewarm() async {
        session = nil
        let fresh = LanguageModelSession(model: model, instructions: RefineInstructions.text)
        fresh.prewarm(promptPrefix: Prompt("<transcript>"))
        session = fresh
    }

    public func generate(_ transcript: String) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RefineError.emptyResponse }
        if case .unavailable(let reason) = model.availability {
            throw RefineError.unavailable(String(describing: reason))
        }

        // One session per utterance: LanguageModelSession accumulates a
        // transcript, so reusing it would spend the shared 4096-token context on
        // previous dictations. Not prewarmed (first run after enabling) means
        // paying the setup cost inline, exactly like the old spawn-on-demand.
        let live = session ?? LanguageModelSession(model: model,
                                                   instructions: RefineInstructions.text)
        session = nil

        do {
            let options = GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: RefinePrompt.maximumResponseTokens(for: text))
            let response = try await live.respond(to: RefinePrompt.userTurn(for: text),
                                                  options: options)
            let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { throw RefineError.emptyResponse }
            return out
        } catch let error as RefineError {
            throw error
        } catch {
            // guardrailViolation, exceededContextWindowSize, rateLimited, … —
            // the cage falls back to the deterministic pipeline.
            throw RefineError.fromFramework(error)
        }
    }

    public func discard() async {
        session = nil
    }
}

extension RefineError {
    /// Generation errors carry the framework's own description because the cage
    /// keys the "Apple Intelligence went away" recovery off the word
    /// "unavailable" in it, exactly as the Python did over the JSON protocol.
    static func fromFramework(_ error: any Error) -> RefineError {
        let text = String(describing: error).prefix(300).description
        if text.lowercased().contains("unavailable") { return .unavailable(text) }
        return .generationFailed(text)
    }
}
#endif
