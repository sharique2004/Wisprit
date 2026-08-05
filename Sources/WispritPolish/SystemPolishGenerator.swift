#if canImport(FoundationModels)
import Foundation
import FoundationModels
import WispritKit

/// The real generator: Apple Intelligence, in-process, on-device.
///
/// This is the whole point of the target. `polish.py` shelled out to the user's
/// `claude` CLI, which sent every dictated transcript to a cloud model on a
/// personal subscription. That tier is gone: Wisprit makes zero network calls,
/// so polish runs on the same on-device model as the on-path cleanup stage.
///
/// An actor because `LanguageModelSession` is a non-Sendable class that must be
/// touched from one place at a time. Serializing costs nothing — requests
/// serialize on the system model daemon anyway (measured).
public actor SystemPolishGenerator: PolishGenerating {

    /// Permissive transformation guardrails: Apple's documented mode for apps
    /// that transform user-provided content. Dictated words must be rewritten,
    /// not judged — under `.default` guardrails, benign dictations sporadically
    /// throw `guardrailViolation`, which for polish means a visible failure
    /// notice rather than a silent verbatim fallback.
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private var session: LanguageModelSession?
    private let log = WLog.logger("polish")

    public init() {}

    public func probe() async -> PolishAvailability {
        // `SystemLanguageModel.default` reports the same asset/enablement state
        // as the permissive instance; guardrails are a request-time policy, not
        // a capability.
        switch SystemLanguageModel.default.availability {
        case .available:
            return PolishAvailability(available: true)
        case .unavailable(let reason):
            return PolishAvailability(available: false, reason: String(describing: reason))
        }
    }

    public func generate(_ transcript: String, mode: PolishMode) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PolishError.emptyResponse }
        if case .unavailable(let reason) = model.availability {
            throw PolishError.unavailable(String(describing: reason))
        }

        // One session per request: instructions are per-mode, and a reused
        // session would spend the shared 4096-token context on the previous
        // transcript. There is no prewarm — polish starts the moment the user
        // picks a mode, so there is no hold to warm up during.
        let live = LanguageModelSession(model: model,
                                        instructions: PolishInstructions.text(for: mode))
        session = live
        defer { session = nil }

        do {
            let options = GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: PolishPrompt.maximumResponseTokens(for: text, mode: mode))
            let response = try await live.respond(to: PolishPrompt.userTurn(for: text),
                                                  options: options)
            let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { throw PolishError.emptyResponse }
            return out
        } catch let error as PolishError {
            throw error
        } catch {
            // guardrailViolation, exceededContextWindowSize, rateLimited, … —
            // the cage turns these into a user-visible failure notice.
            throw PolishError.fromFramework(error)
        }
    }

    public func discard() async {
        session = nil
    }
}

extension PolishError {
    /// Framework errors keep their own description because the cage keys the
    /// "Apple Intelligence went away" recovery off the word "unavailable".
    static func fromFramework(_ error: any Error) -> PolishError {
        let text = String(describing: error).prefix(300).description
        if text.lowercased().contains("unavailable") { return .unavailable(text) }
        return .generationFailed(text)
    }
}
#endif
