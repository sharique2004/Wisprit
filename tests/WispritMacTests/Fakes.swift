import Foundation
import WispritEngine
import WispritKit
import WispritMacInput
import WispritMacUI
import WispritPersistence
import WispritRefine
@testable import WispritMac

/// Test doubles for every `SessionPorts` seam.
///
/// Nothing here touches a microphone, an event tap, the pasteboard, a window or
/// the user's `~/.wisprit` — which is the point: the state machine is fully
/// exercisable on a machine with zero TCC grants.

final class FakeAsr: AsrPort, @unchecked Sendable {
    private let lock = NSLock()
    var result = UtteranceResult(text: "hello world", engine: "apple_live", finalizeMs: 120)
    /// Partial strings the engine "delivers" during `begin`.
    var partials: [String] = []
    /// Audio the fake is retaining for the CURRENT utterance. `finalize()`
    /// detaches it into a `RetainedUtterance` and `begin()` bumps the id, exactly
    /// as `AsrManager` does — which is what lets a test move the live buffer on
    /// while an off-path pass is still running.
    var retainedPcm = Data()
    private(set) var beginCount = 0
    private(set) var finalizeCount = 0
    private(set) var cancelCount = 0
    private(set) var reconcileCount = 0
    var reconciliation: VocabularyReconciliation?
    private var utteranceID: UInt64 = 0
    private var lastRetainedValue = RetainedUtterance(id: 0, pcm: Data())
    /// Every reconcile call: the value it was handed, and what the fake was
    /// retaining by the time it looked. Reconciles land on a detached task, so
    /// assertions read the locked `reconcileLog`.
    private var reconciled: [(retained: RetainedUtterance, live: Data)] = []
    /// Park each reconcile as it enters, so the next utterance can overtake it.
    /// Released by `releaseReconciles()`.
    var parkReconciles = false
    /// Called as each reconcile enters, before it parks.
    var onReconcileEnter: (@Sendable () -> Void)?
    private var parked: [CheckedContinuation<Void, Never>] = []
    /// The live callback, retained so `deliverPartial` can use it later.
    private var partialHandler: (@Sendable (String) -> Void)?

    var lastRetained: RetainedUtterance {
        lock.lock(); defer { lock.unlock() }
        return lastRetainedValue
    }

    var reconcileLog: [(retained: RetainedUtterance, live: Data)] {
        lock.lock(); defer { lock.unlock() }
        return reconciled
    }

    var reconcileTally: Int { lock.lock(); defer { lock.unlock() }; return reconcileCount }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async {
        for partial in noteBegin(onPartial) { onPartial(partial) }
    }

    /// Deliver one partial the way the engine really does — after `begin` has
    /// returned and the machine is RECORDING — rather than inline inside
    /// `begin`. `partials` still fires inline, so every test that predates this
    /// seam is unchanged; the difference only matters to a test that asserts on
    /// something the RECORDING state gates, like the pill bubble.
    func deliverPartial(_ text: String) {
        lock.lock(); let handler = partialHandler; lock.unlock()
        handler?(text)
    }

    func finalize() async -> UtteranceResult { noteFinalize() }
    func cancel() async { noteCancel() }

    func reconcileVocabulary(_ retained: RetainedUtterance) async -> VocabularyReconciliation? {
        if let enter = enterReconcile() { enter() }
        await parkIfGated()
        return noteReconcile(retained)
    }

    /// Let every parked reconcile through and stop parking new ones.
    func releaseReconciles() {
        lock.lock()
        parkReconciles = false
        let waiting = parked
        parked = []
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    // NSLock is unavailable from async contexts, so every mutation goes through
    // a synchronous helper.
    private func noteBegin(_ onPartial: @escaping @Sendable (String) -> Void) -> [String] {
        lock.lock(); defer { lock.unlock() }
        beginCount += 1
        utteranceID += 1
        partialHandler = onPartial
        return partials
    }

    private func noteFinalize() -> UtteranceResult {
        lock.lock(); defer { lock.unlock() }
        finalizeCount += 1
        lastRetainedValue = RetainedUtterance(id: utteranceID, pcm: retainedPcm)
        return result
    }

    private func noteCancel() {
        lock.lock(); cancelCount += 1; lock.unlock()
    }

    private func enterReconcile() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return onReconcileEnter
    }

    private func parkIfGated() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard parkReconciles else { lock.unlock(); continuation.resume(); return }
            parked.append(continuation)
            lock.unlock()
        }
    }

    private func noteReconcile(_ retained: RetainedUtterance) -> VocabularyReconciliation? {
        lock.lock(); defer { lock.unlock() }
        reconcileCount += 1
        reconciled.append((retained, retainedPcm))
        return reconciliation
    }
}

final class FakeAudio: AudioPort, @unchecked Sendable {
    private let lock = NSLock()
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var level: Double = 0.4

    func start() -> Bool {
        lock.lock(); startCount += 1; let ok = startSucceeds; lock.unlock()
        return ok
    }

    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
}

final class FakeRefiner: RefinePort, @unchecked Sendable {
    private let lock = NSLock()
    /// Transform applied when the interrupt hook stays `.none`.
    var transform: @Sendable (String) -> RefineResult = {
        RefineResult(text: $0, outcome: .applied)
    }
    /// Honour the interrupt hook: poll it once and map cancel/hurry the way the
    /// real cage does (verbatim text, `cancelled` / `preempted`).
    var honoursInterrupt = true
    private(set) var beginCount = 0
    private(set) var cancelCount = 0
    private(set) var refineCount = 0
    private(set) var lastInput: String?
    var availabilityValue: Bool?

    func begin() async { bump(&beginCount) }
    func cancel() async { bump(&cancelCount) }
    func availability() async -> Bool? { readAvailability() }

    func refine(_ raw: String,
                interrupt: @escaping @Sendable () -> InterruptSignal) async -> RefineResult {
        let (honours, transform) = noteRefine(raw)
        if honours {
            switch interrupt() {
            case .cancel: return RefineResult(text: raw, outcome: .cancelled)
            case .hurry: return RefineResult(text: raw, outcome: .preempted)
            case .none: break
            }
        }
        return transform(raw)
    }

    private func bump(_ counter: inout Int) {
        lock.lock(); counter += 1; lock.unlock()
    }

    private func readAvailability() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return availabilityValue
    }

    private func noteRefine(_ raw: String) -> (Bool, @Sendable (String) -> RefineResult) {
        lock.lock(); defer { lock.unlock() }
        refineCount += 1
        lastInput = raw
        return (honoursInterrupt, transform)
    }
}

final class FakeInserter: InsertPort, @unchecked Sendable {
    private let lock = NSLock()
    var result = InsertResult(ok: true, method: .paste, detail: "clipboard restored")
    private(set) var inserted: [String] = []
    /// Snapshot of `FakeHistory.added.count` at each insert — proves the
    /// history-before-insert ordering.
    var historyDepthAtInsert: [Int] = []
    var history: FakeHistory?
    /// Snapshot of `FakeAsr.reconcileTally` at each insert. The reconciliation
    /// pass costs seconds and is contractually off the paste path, so this stays
    /// all zeroes.
    var reconcileDepthAtInsert: [Int] = []
    var asr: FakeAsr?
    /// The session's parked-work label at each insert. A retro edit is planned
    /// seconds after this moment and applied later still, so this stays all nils
    /// — the other half of "nothing off-path runs before the text lands".
    var deferredAtInsert: [String?] = []
    var deferredLabel: (@Sendable () -> String?)?

    func insert(_ text: String) -> InsertResult {
        lock.lock()
        inserted.append(text)
        historyDepthAtInsert.append(history?.addedCount ?? -1)
        reconcileDepthAtInsert.append(asr?.reconcileTally ?? -1)
        deferredAtInsert.append(deferredLabel?())
        let result = self.result
        lock.unlock()
        return result
    }
}

final class FakeHistory: HistoryPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var added: [(text: String, engine: String, durationMs: Double?)] = []
    var last: String?

    var addedCount: Int { lock.lock(); defer { lock.unlock() }; return added.count }

    @discardableResult
    func add(text: String, engine: String, durationMs: Double?) -> Int64 {
        lock.lock()
        added.append((text, engine, durationMs))
        last = text
        let id = Int64(added.count)
        lock.unlock()
        return id
    }

    func lastText() -> String? { lock.lock(); defer { lock.unlock() }; return last }
}

final class FakeMetrics: MetricsPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [MetricsRecord] = []

    func write(_ record: MetricsRecord) {
        lock.lock(); records.append(record); lock.unlock()
    }

    var last: MetricsRecord? { lock.lock(); defer { lock.unlock() }; return records.last }
}

final class FakePill: PillPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    private(set) var errors: [String] = []
    private(set) var notices: [String] = []
    private(set) var partials: [String] = []

    private func record(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }

    func showRecording() { record("showRecording") }
    func updateLevel(_ level: Double) { record("updateLevel") }
    func livePartial(_ text: String) {
        lock.lock(); partials.append(text); calls.append("livePartial"); lock.unlock()
    }
    func showFinalizing() { record("showFinalizing") }
    func flashSuccess() { record("flashSuccess") }
    func flashError(_ message: String) {
        lock.lock(); errors.append(message); calls.append("flashError"); lock.unlock()
    }
    func transientNotice(_ text: String) {
        lock.lock(); notices.append(text); calls.append("transientNotice"); lock.unlock()
    }
    func hide() { record("hide") }

    // The three states §2.4 adds. Recorded separately from `errors` on purpose:
    // `blockedSecure` is a distinct outcome with its own copy and its own
    // dwell, and folding it back into an error flash is what the redesign
    // undid.
    func showPrewarming() { record("showPrewarming") }
    func showRefining() { record("showRefining") }
    func flashBlockedSecure() { record("flashBlockedSecure") }

    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

/// A `PillPort` backed by the REAL `PillModel` — `MainThreadPill` with the
/// AppKit half removed.
///
/// `FakePill` is the right double nearly everywhere: it records the calls, and
/// the calls are the contract. This one exists for the claims that are about
/// what is *on screen* — the live self-correction tests assert the rendered
/// tail, which is `PartialTail`'s windowing of what the session emitted, and
/// asserting the emitted string instead would prove the wrong half of it.
final class ModelPill: PillPort, @unchecked Sendable {
    private let lock = NSLock()
    private let model = PillModel()
    private(set) var partials: [String] = []

    /// The rendered tail: what the bubble actually says.
    var bubble: String { lock.lock(); defer { lock.unlock() }; return model.bubble }

    func showRecording() { lock.lock(); model.showRecording(); lock.unlock() }
    func updateLevel(_ level: Double) { lock.lock(); model.updateLevel(level); lock.unlock() }
    func livePartial(_ text: String) {
        lock.lock(); partials.append(text); model.livePartial(text); lock.unlock()
    }
    func showFinalizing() { lock.lock(); model.showFinalizing(); lock.unlock() }
    func flashSuccess() { lock.lock(); model.flashSuccess(); lock.unlock() }
    func flashError(_ message: String) { lock.lock(); model.flashError(message); lock.unlock() }
    func transientNotice(_ text: String) { lock.lock(); model.transientNotice(text); lock.unlock() }
    func hide() { lock.lock(); model.hide(); lock.unlock() }
    func showPrewarming() { lock.lock(); model.showPrewarming(); lock.unlock() }
    func showRefining() { lock.lock(); model.showRefining(); lock.unlock() }
    func flashBlockedSecure() { lock.lock(); model.flashBlockedSecure(); lock.unlock() }
}

final class FakeVocabulary: VocabularyPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reloadCount = 0
    private(set) var learned: [LearnedTerm] = []
    private(set) var pending: [(term: String, observation: String)] = []
    private(set) var uses: [String] = []
    /// Canonical terms the dictionary already holds, matched case-insensitively
    /// like `DictionaryStore.isKnownTerm`. Empty by default, so the retro
    /// fallback stays inert unless a test says otherwise.
    var known: Set<String> = []

    @discardableResult
    func maybeReload() -> Bool { lock.lock(); reloadCount += 1; lock.unlock(); return false }
    func add(_ learned: LearnedTerm) { lock.lock(); self.learned.append(learned); lock.unlock() }
    func addPending(term: String, observation: String) {
        lock.lock(); pending.append((term, observation)); lock.unlock()
    }
    func recordUse(term: String) { lock.lock(); uses.append(term); lock.unlock() }
    func isKnownTerm(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let needle = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return known.contains { $0.lowercased() == needle }
    }
}

final class FakeGate: RecordingGate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var transitions: [Bool] = []
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return transitions.last ?? false }

    func setRecording(_ recording: Bool) {
        lock.lock(); transitions.append(recording); lock.unlock()
    }
}

/// The sentence from the feature request, as the engine delivers it:
/// cumulative, windowed, several partials a second, and only resolvable on the
/// last one — "no" alone is not a correction marker, so the tail stays verbatim
/// right up until "actually friday" arrives.
///
/// Shared by both surfaces' tests so they cannot drift apart: the claim is that
/// the pill bubble and the input method's marked text show the same words.
enum LiveCorrectionScript {
    static let partials = [
        "i want to have a meeting",
        "i want to have a meeting with person x on thuersday",
        "i want to have a meeting with person x on thuersday umm no",
        "i want to have a meeting with person x on thuersday umm no actually friday",
    ]

    /// What both surfaces must be showing once the last partial lands. Lower
    /// case, exactly as the partial had it — self-correction resolves the
    /// *words*; casing is the final pipeline's business, not the preview's.
    static let corrected = "i want to have a meeting with person x on friday"
}

/// A minimal in-memory `CorrectionApplying` + `VocabularySource` for the
/// postprocess stage and the letter-run detector's known-term check.
final class FakeDictionary: CorrectionApplying, VocabularySource, @unchecked Sendable {
    var substitutions: [String: String] = [:]
    var knownTerms: Set<String> = []

    func applyCorrections(to text: String) -> String {
        var out = text
        for (from, to) in substitutions {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    func vocabularyTerms() -> [String] { Array(knownTerms) }
    func isKnownTerm(_ word: String) -> Bool { knownTerms.contains(word) }
}
