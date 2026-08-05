import XCTest
@testable import WispritEngine

final class PcmChunkQueueTests: XCTestCase {

    private func chunk(_ n: UInt8) -> Data { Data([n, n, n, n]) }

    func testFifoOrder() async {
        let q = PcmChunkQueue(capacity: 8)
        for i in 0..<5 { q.enqueue(chunk(UInt8(i))) }
        q.close()
        var seen: [UInt8] = []
        while let d = await q.next() { seen.append(d[0]) }
        XCTAssertEqual(seen, [0, 1, 2, 3, 4])
    }

    func testDropsOldestWhenFull() async {
        let q = PcmChunkQueue(capacity: 3)
        for i in 0..<6 { q.enqueue(chunk(UInt8(i))) }
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(q.droppedChunks, 3)
        q.close()
        var seen: [UInt8] = []
        while let d = await q.next() { seen.append(d[0]) }
        // The NEWEST three survive — a dropped chunk costs old captions, never the tail.
        XCTAssertEqual(seen, [3, 4, 5])
    }

    func testEnqueueNeverBlocksWellPastCapacity() {
        let q = PcmChunkQueue(capacity: 4)
        let start = Date()
        for i in 0..<20_000 { q.enqueue(chunk(UInt8(i % 251))) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertEqual(q.count, 4)
        XCTAssertEqual(q.droppedChunks, 19_996)
    }

    func testCloseDrainsThenReturnsNil() async {
        let q = PcmChunkQueue()
        q.enqueue(chunk(7))
        q.close()
        let first = await q.next()
        XCTAssertEqual(first?[0], 7)
        let second = await q.next()
        XCTAssertNil(second)
        let third = await q.next()
        XCTAssertNil(third)
    }

    func testDiscardAllDropsQueuedChunks() async {
        let q = PcmChunkQueue()
        for i in 0..<10 { q.enqueue(chunk(UInt8(i))) }
        q.discardAll()
        let next = await q.next()
        XCTAssertNil(next)
    }

    func testEnqueueAfterCloseIsIgnored() async {
        let q = PcmChunkQueue()
        q.close()
        q.enqueue(chunk(1))
        let next = await q.next()
        XCTAssertNil(next)
    }

    func testParkedConsumerIsResumedByEnqueue() async {
        let q = PcmChunkQueue()
        let waiter = Task { await q.next() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        q.enqueue(chunk(42))
        let got = await waiter.value
        XCTAssertEqual(got?[0], 42)
    }

    func testParkedConsumerIsResumedByClose() async {
        let q = PcmChunkQueue()
        let waiter = Task { await q.next() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        q.close()
        let got = await waiter.value
        XCTAssertNil(got)
    }

    func testConcurrentProducerAndConsumerLoseNothingBelowCapacity() async {
        let q = PcmChunkQueue(capacity: 4096)
        let total = 2_000
        let consumer = Task { () -> Int in
            var n = 0
            while await q.next() != nil { n += 1 }
            return n
        }
        for i in 0..<total { q.enqueue(chunk(UInt8(i % 251))) }
        q.close()
        let received = await consumer.value
        XCTAssertEqual(q.droppedChunks, 0)
        XCTAssertEqual(received, total)
    }
}

final class PcmRetentionBufferTests: XCTestCase {

    func testAccumulatesAndReports16kInt16Duration() {
        let buf = PcmRetentionBuffer()
        // 1 s of 16 kHz mono Int16 = 32000 bytes.
        for _ in 0..<10 { buf.append(Data(count: 3_200)) }
        XCTAssertEqual(buf.byteCount, 32_000)
        XCTAssertEqual(buf.durationSeconds, 1.0, accuracy: 1e-9)
        XCTAssertEqual(buf.data.count, 32_000)
    }

    func testResetClears() {
        let buf = PcmRetentionBuffer()
        buf.append(Data(count: 100))
        buf.reset()
        XCTAssertEqual(buf.byteCount, 0)
        XCTAssertTrue(buf.data.isEmpty)
    }

    func testConcatenationOrderIsPreserved() {
        let buf = PcmRetentionBuffer()
        buf.append(Data([1, 2])); buf.append(Data([3, 4])); buf.append(Data([5, 6]))
        XCTAssertEqual(Array(buf.data), [1, 2, 3, 4, 5, 6])
    }
}
