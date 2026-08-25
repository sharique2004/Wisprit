import Foundation
import WispritKit

/// The scorer seam behind `VadMonitor`. The FluidAudio-backed Silero
/// implementation lives in WispritParakeet (the FluidAudio adapter module);
/// tests fake this to pin the monitor's accounting without a model.
public protocol VadScoring: Sendable {
    /// Prepare for one utterance (reset any stream state). false = the scorer
    /// cannot run right now (model absent) — the monitor stays inert and every
    /// published fact stays nil, which every consumer treats as "no witness".
    func begin() async -> Bool
    /// Speech probability 0…1 for one window of 16 kHz mono Int16 PCM, in
    /// stream order. nil on any failure — the monitor is advisory everywhere.
    func score(window: Data) async -> Double?
}

/// A real voice-activity witness beside the RMS meter
/// (docs/research/hearing-and-corrections.md, hearing tier 3).
///
/// The RMS threshold fails BOTH of the program's target scenarios at once:
/// soft speech sits under any fixed floor, and a crowded room's floor sits over
/// it. A trained VAD separates "speech" from "loud" — and everything it
/// publishes here is METADATA. The audio path is untouched by construction:
/// this type receives a second reference to each canonical chunk, never gates,
/// never rewrites, never delays (`feed` is a lock-only enqueue; a wedged
/// scorer only means stale advisory numbers). The engine transcribes at peak
/// 0.003 — any pre-ASR gate would lose exactly the soft speech this program
/// exists to protect.
public final class VadMonitor: @unchecked Sendable {
    /// FluidAudio's Silero port is fixed at 4096-sample windows (256 ms).
    public static let windowFrames = 4096
    static var windowBytes: Int { windowFrames * PcmFormat.bytesPerFrame }
    /// Raw-probability floor for "this window carried speech" — the monitor's
    /// own classification line, deliberately under FluidAudio's segmentation
    /// default (0.85): a witness should err toward seeing speech.
    public static let speechThreshold = 0.5

    private let scorer: any VadScoring
    private let log = WLog.logger("engine.vad")
    private let lock = UnfairLock()
    private var queue: PcmChunkQueue?
    private var pending = Data()
    private var consumer: Task<Void, Never>?
    private var startedAtNs: UInt64 = 0
    private var running = false

    // Published facts, per utterance. All nil/zero until the scorer answers.
    private var latestProbabilityValue: Double?
    private var firstSpeechMsValue: Double?
    private var lastSpeechAtNsValue: UInt64 = 0
    private var speechWindowsValue = 0
    private var totalWindowsValue = 0

    public init(scorer: any VadScoring) {
        self.scorer = scorer
    }

    /// Most recent window's speech probability — the adaptive key-up grace's
    /// arbiter in rooms where RMS-vs-floor lies.
    public var latestProbability: Double? {
        lock.lock(); defer { lock.unlock() }
        return latestProbabilityValue
    }

    /// monitor-start → first window over the speech threshold, in ms.
    public var firstSpeechMs: Double? {
        lock.lock(); defer { lock.unlock() }
        return firstSpeechMsValue
    }

    /// Share of scored windows the VAD called speech; nil before any window.
    public var speechRatio: Double? {
        lock.lock(); defer { lock.unlock() }
        guard totalWindowsValue > 0 else { return nil }
        return Double(speechWindowsValue) / Double(totalWindowsValue)
    }

    /// ms since the last speech-classified window; nil when none ever was.
    public var msSinceLastSpeech: Double? {
        lock.lock(); defer { lock.unlock() }
        guard lastSpeechAtNsValue > 0 else { return nil }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return Double(now - lastSpeechAtNsValue) / 1_000_000.0
    }

    /// Idempotent, like the captures it rides beside: the prestart hook and
    /// the session's own start both call it.
    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        latestProbabilityValue = nil
        firstSpeechMsValue = nil
        lastSpeechAtNsValue = 0
        speechWindowsValue = 0
        totalWindowsValue = 0
        pending.removeAll(keepingCapacity: true)
        startedAtNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let queue = PcmChunkQueue()
        self.queue = queue
        lock.unlock()

        consumer = Task.detached(priority: .utility) { [weak self, scorer] in
            guard await scorer.begin() else { return }   // inert without a model
            while let chunk = await queue.next() {
                await self?.consume(chunk, scorer: scorer)
            }
        }
    }

    /// Render-thread safe: a lock-only enqueue into a bounded drop-oldest
    /// queue. Drops are FINE here — verdicts are advisory.
    public func feed(_ pcm: Data) {
        lock.lock()
        let queue = running ? self.queue : nil
        lock.unlock()
        queue?.enqueue(pcm)
    }

    public func stop() {
        lock.lock()
        running = false
        let queue = self.queue
        self.queue = nil
        lock.unlock()
        // Close, don't discard: the tail windows still score, then the
        // consumer exits on its own. Nothing awaits it — advisory to the end.
        queue?.close()
    }

    private func consume(_ chunk: Data, scorer: any VadScoring) async {
        lock.lock()
        pending.append(chunk)
        lock.unlock()
        // Drain EVERY complete window the accumulator holds: a queued chunk
        // (the head-replay splice, a burst) can carry several, and a window
        // left pending would only score when the next chunk arrived — or
        // never, at end of utterance.
        while true {
            lock.lock()
            var window: Data?
            if pending.count >= Self.windowBytes {
                window = pending.prefix(Self.windowBytes)
                pending.removeFirst(Self.windowBytes)
            }
            lock.unlock()
            guard let window else { return }
            guard let probability = await scorer.score(window: window) else { continue }

            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            lock.lock()
            latestProbabilityValue = probability
            totalWindowsValue += 1
            if probability >= Self.speechThreshold {
                speechWindowsValue += 1
                lastSpeechAtNsValue = now
                if firstSpeechMsValue == nil, startedAtNs > 0 {
                    firstSpeechMsValue = Double(now - startedAtNs) / 1_000_000.0
                }
            }
            lock.unlock()
        }
    }
}
