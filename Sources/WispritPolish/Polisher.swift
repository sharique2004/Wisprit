import Foundation
import WispritKit
import WispritRefine

/// Off-path Apple Intelligence rewriting of the LAST transcript — the Swift
/// replacement for `wisprit/polish.py`, with the `claude` CLI subprocess
/// replaced by the on-device model. No network call is made, ever.
///
/// Placement: **nowhere near the dictation path.** Verbatim text is inserted
/// instantly by the session; polish is a deliberate, per-invocation menu action
/// (Polish Last ▸ Clean up / Make formal / Make casual / As an AI prompt) that
/// transforms the last transcript and hands the caller a string to put on the
/// clipboard. Nothing here can delay, block, or alter an utterance.
///
/// Failure policy is the INVERSE of `Refiner`'s. Refine is automatic, so it
/// falls back to verbatim and the user never notices. Polish is opt-in against
/// text the user already has, so a doubtful result is reported as
/// `.failure(reason:kind:)`; the caller shows the notice and leaves the
/// clipboard alone (exactly what `polish.polish()`'s `(False, message)` meant).
/// Silently pasting a rewrite the cage does not trust would be worse than
/// doing nothing.
///
/// Requests serialize: two menu clicks chain instead of racing. Parallel
/// FoundationModels requests were measured NOT to help — they serialize on the
/// system model daemon anyway — and one session per request is mandatory
/// because a `LanguageModelSession` accumulates a transcript and the mode
/// instructions differ per request.
public actor Polisher {

    /// Measured on M4 (macOS 26.5): ~20 ms per output word + ~0.5 s fixed.
    /// Polish is off-path and user-initiated, so the budget is generous —
    /// it exists to bound a hung daemon, not to keep dictation snappy.
    static let timeoutBase: Double = 5.0
    static let timeoutPerWord: Double = 0.08

    /// How often the poll loop wakes to check the deadline and the interrupt.
    static let pollInterval: Duration = .milliseconds(50)

    /// Re-probe cadence while Apple Intelligence is unavailable (assets still
    /// downloading, setting off), so the menu recovers without a relaunch.
    static let probeRetryInterval: Duration = .seconds(300)

    private let generator: any PolishGenerating
    private let configuration: @Sendable () -> PolishConfiguration
    private let log = WLog.logger("polish")

    /// nil = unknown (probe still running), true/false = probed. Same tri-state
    /// as `Refiner.availability`, so the menu renders both with one code path:
    /// nil ⇒ show the submenu, false ⇒ disabled row with the reason (this is
    /// where `polish.available()`'s "claude CLI not found" title used to go).
    private var available: Bool?
    private var reason: String = ""

    /// Tail of the serialization chain; each request awaits the previous one.
    private var tail: Task<Void, Never>?

    public init(generator: any PolishGenerating,
                configuration: @escaping @Sendable () -> PolishConfiguration = {
                    PolishConfiguration()
                },
                startProbe: Bool = true) {
        self.generator = generator
        self.configuration = configuration
        if startProbe {
            // `self` is held only for the duration of each probe, never across
            // the sleep, so the loop dies with the Polisher.
            Task { [weak self] in
                while true {
                    guard let resolved = await self?.probeNow() else { return }
                    if resolved { return }
                    do { try await Task.sleep(for: Polisher.probeRetryInterval) }
                    catch { return }
                }
            }
        }
    }

    // MARK: - availability

    public var availability: Bool? { available }
    public var unavailableReason: String { reason }

    @discardableResult
    public func probeNow() async -> Bool {
        let probed = await generator.probe()
        available = probed.available
        reason = probed.reason
        if !probed.available {
            log.warning("polish unavailable: \(probed.reason, privacy: .public)")
        }
        return probed.available
    }

    // MARK: - the cage

    /// Rewrite `raw` in `mode`.
    ///
    /// Never throws. On success the text is safe to put on the clipboard; on
    /// failure the caller shows `reason` and changes nothing.
    ///
    /// `interrupt` is polled ~20×/s and lets a caller abandon a request (menu
    /// dismissed, app quitting). It is optional because, unlike refine, nothing
    /// is waiting on this result.
    public func polish(_ raw: String,
                       mode: PolishMode,
                       interrupt: (@Sendable () -> Bool)? = nil) async -> PolishResult {
        // Chain onto the previous request. Actor reentrancy alone would let two
        // menu clicks interleave inside `run`, which would hand the daemon two
        // sessions for no gain.
        let previous = tail
        let work = Task { [self] () -> PolishResult in
            await previous?.value
            return await run(raw, mode: mode, interrupt: interrupt)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func run(_ raw: String,
                     mode: PolishMode,
                     interrupt: (@Sendable () -> Bool)?) async -> PolishResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if available == false { return .failure(.unavailable(reason)) }

        let config = configuration()
        // Word count that stays meaningful for space-free scripts (CJK), reused
        // from the refine guards.
        let words = RefineGuards.estimatedWords(text)
        if words > config.maxWords { return .failure(.tooLong(config.maxWords)) }

        let budget = min(Double(config.timeoutMs) / 1000.0,
                         Self.timeoutBase + Self.timeoutPerWord * Double(words))

        switch await race(text, mode: mode, deadlineSeconds: budget, interrupt: interrupt) {
        case .interrupted(let kind):
            await generator.discard()
            if kind == .timeout {
                log.warning("polish timed out (\(words, privacy: .public) words)")
            }
            return .failure(kind)

        case .failed(let error):
            let kind = await failureKind(for: error)
            await generator.discard()
            return .failure(kind)

        case .produced(let generated):
            let polished = PolishGuards.launder(generated)
            if polished.isEmpty { return .failure(.emptyOutput) }
            if PolishGuards.refused(polished) {
                log.warning("polish refused by the model")
                return .failure(.refused)
            }
            guard PolishGuards.plausible(raw: text, polished: polished, mode: mode) else {
                log.warning("polished text implausible for mode \(mode.rawValue, privacy: .public)")
                return .failure(.implausible)
            }
            return .success(polished)
        }
    }

    /// Drop any live session (app quitting, request abandoned).
    public func cancel() async {
        await generator.discard()
    }

    // MARK: - internals

    private enum RaceResult {
        case produced(String)
        case failed(any Error)
        case interrupted(PolishFailureKind)
    }

    private func race(_ text: String,
                      mode: PolishMode,
                      deadlineSeconds: Double,
                      interrupt: (@Sendable () -> Bool)?) async -> RaceResult {
        enum Leg: Sendable {
            case generation(Result<String, any Error>)
            case interrupted(PolishFailureKind)
            case pollerStopped
        }
        let generator = self.generator
        return await withTaskGroup(of: Leg.self) { group in
            group.addTask {
                do { return .generation(.success(try await generator.generate(text, mode: mode))) }
                catch { return .generation(.failure(error)) }
            }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(deadlineSeconds))
                while !Task.isCancelled {
                    if ContinuousClock.now >= deadline { return .interrupted(.timeout) }
                    if interrupt?() == true { return .interrupted(.cancelled) }
                    do { try await Task.sleep(for: Polisher.pollInterval) } catch { break }
                }
                return .pollerStopped
            }

            var result: RaceResult = .interrupted(.timeout)
            while let leg = await group.next() {
                switch leg {
                case .pollerStopped:
                    continue                       // only reachable after cancelAll
                case .generation(.success(let produced)):
                    result = .produced(produced)
                case .generation(.failure(let error)):
                    result = .failed(error)
                case .interrupted(let kind):
                    result = .interrupted(kind)
                }
                break
            }
            group.cancelAll()
            return result
        }
    }

    private func failureKind(for error: any Error) async -> PolishFailureKind {
        if let polishError = error as? PolishError {
            switch polishError {
            case .setupFailed(let detail):
                log.warning("polish session setup failed: \(detail, privacy: .public)")
                return .setupFailed(detail)
            case .unavailable(let detail):
                // Apple Intelligence got disabled / assets evicted mid-session:
                // stop offering polish until a probe or relaunch recovers.
                available = false
                reason = String(detail.prefix(120))
                return .unavailable(reason)
            case .emptyResponse:
                return .emptyOutput
            case .generationFailed(let detail):
                log.warning("polish model error: \(detail, privacy: .public)")
                return .modelError(detail)
            }
        }
        let described = String(describing: error)
        log.error("polish failed: \(described, privacy: .public)")
        if described.lowercased().contains("unavailable") {
            available = false
            reason = String(described.prefix(120))
            return .unavailable(reason)
        }
        return .modelError(String(described.prefix(300)))
    }
}
