import Foundation

/// Bounded drop-oldest PCM hand-off between the audio callback and the analyzer
/// pump. Ported from the `queue.Queue(maxsize=_FEED_QUEUE_CHUNKS)` + drop-oldest
/// dance in `asr.py`: `enqueue` is lock-only and never waits, so the CoreAudio
/// render thread can never be blocked by a stalled transcriber.
public final class PcmChunkQueue: @unchecked Sendable {
    /// 100 chunks = 10 s at 100 ms/chunk, same depth as `_FEED_QUEUE_CHUNKS`.
    public static let defaultCapacity = 100

    private let capacity: Int
    private let lock = UnfairLock()
    private var storage: [Data] = []
    private var head = 0
    private var closed = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var dropped = 0

    public init(capacity: Int = PcmChunkQueue.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Chunks discarded under backpressure since construction.
    public var droppedChunks: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count - head
    }

    /// Non-blocking. Drops the OLDEST queued chunk when full — a dropped chunk
    /// costs a few ms of captions; a blocked audio callback costs the utterance.
    public func enqueue(_ chunk: Data) {
        lock.lock()
        if closed { lock.unlock(); return }
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: chunk)
            return
        }
        storage.append(chunk)
        if storage.count - head > capacity {
            head += 1
            dropped += 1
        }
        compactLocked()
        lock.unlock()
    }

    /// Single-consumer. Returns nil once closed AND drained.
    public func next() async -> Data? {
        lock.lock()
        if head < storage.count {
            let d = storage[head]; head += 1
            compactLocked()
            lock.unlock()
            return d
        }
        if closed { lock.unlock(); return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            waiter = c
            lock.unlock()   // handed over from the caller above
        }
    }

    /// End of utterance: queued chunks still drain, then `next()` returns nil.
    public func close() {
        lock.lock()
        closed = true
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: nil)
            return
        }
        lock.unlock()
    }

    /// Cancel: drop everything still queued and close.
    public func discardAll() {
        lock.lock()
        storage.removeAll(); head = 0
        closed = true
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: nil)
            return
        }
        lock.unlock()
    }

    private func compactLocked() {
        guard head > 64, head * 2 > storage.count else { return }
        storage.removeFirst(head); head = 0
    }
}

/// Full-utterance PCM retention: the batch fallback and the off-path vocabulary
/// channel both re-read the whole utterance, so it is kept until the next
/// `begin()`. Mirrors `AudioCapture._buffers` in `audio.py`.
public final class PcmRetentionBuffer: @unchecked Sendable {
    private let lock = UnfairLock()
    private var chunks: [Data] = []
    private var bytes = 0

    public init() {}

    public func reset() {
        lock.lock(); chunks.removeAll(); bytes = 0; lock.unlock()
    }

    public func append(_ chunk: Data) {
        lock.lock(); chunks.append(chunk); bytes += chunk.count; lock.unlock()
    }

    public var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    /// Seconds of 16 kHz mono Int16 audio retained.
    public var durationSeconds: Double {
        Double(byteCount) / (PcmFormat.sampleRate * 2.0)
    }

    public var data: Data {
        lock.lock(); defer { lock.unlock() }
        var out = Data(capacity: bytes)
        for c in chunks { out.append(c) }
        return out
    }
}
