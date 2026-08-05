import Foundation
import WispritEngine
import WispritKit
import WispritMacInput
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
    private(set) var beginCount = 0
    private(set) var finalizeCount = 0
    private(set) var cancelCount = 0
    private(set) var reconcileCount = 0
    var reconciliation: VocabularyReconciliation?

    func begin(onPartial: @escaping @Sendable (String) -> Void) async {
        for partial in noteBegin() { onPartial(partial) }
    }

    func finalize() async -> UtteranceResult { noteFinalize() }
    func cancel() async { noteCancel() }
    func reconcileVocabulary() async -> VocabularyReconciliation? { noteReconcile() }

    // NSLock is unavailable from async contexts, so every mutation goes through
    // a synchronous helper.
    private func noteBegin() -> [String] {
        lock.lock(); defer { lock.unlock() }
        beginCount += 1
        return partials
    }

    private func noteFinalize() -> UtteranceResult {
        lock.lock(); defer { lock.unlock() }
        finalizeCount += 1
        return result
    }

    private func noteCancel() {
        lock.lock(); cancelCount += 1; lock.unlock()
    }

    private func noteReconcile() -> VocabularyReconciliation? {
        lock.lock(); defer { lock.unlock() }
        reconcileCount += 1
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

    func insert(_ text: String) -> InsertResult {
        lock.lock()
        inserted.append(text)
        historyDepthAtInsert.append(history?.addedCount ?? -1)
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

    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

final class FakeVocabulary: VocabularyPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reloadCount = 0
    private(set) var learned: [LearnedTerm] = []
    private(set) var uses: [String] = []

    @discardableResult
    func maybeReload() -> Bool { lock.lock(); reloadCount += 1; lock.unlock(); return false }
    func add(_ learned: LearnedTerm) { lock.lock(); self.learned.append(learned); lock.unlock() }
    func recordUse(term: String) { lock.lock(); uses.append(term); lock.unlock() }
}

final class FakeGate: RecordingGate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var transitions: [Bool] = []
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return transitions.last ?? false }

    func setRecording(_ recording: Bool) {
        lock.lock(); transitions.append(recording); lock.unlock()
    }
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
