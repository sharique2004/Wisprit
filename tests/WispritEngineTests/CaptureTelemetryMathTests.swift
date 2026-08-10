import XCTest
@testable import WispritEngine

/// The R4 telemetry math: `noise_floor` and `peak_level` must be the same
/// statistic family (RMS × 4, clamped) or the (peak, floor) pair stops being
/// an SNR proxy on one axis. `meanSquare(of:)` + `level(fromMeanSquare:)` are
/// the shared primitives; these pins keep `level(of:)` exactly what it was.
final class CaptureTelemetryMathTests: XCTestCase {

    private func pcm(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let le = UInt16(bitPattern: s).littleEndian
            data.append(UInt8(truncatingIfNeeded: le))
            data.append(UInt8(truncatingIfNeeded: le >> 8))
        }
        return data
    }

    func testLevelIsExactlyTheScaledRootOfMeanSquare() {
        let chunks: [[Int16]] = [
            [0, 0, 0, 0],
            [1000, -1000, 1000, -1000],
            [16384, -16384, 16384, -16384],
            [32767, -32768, 32767, -32768],
        ]
        for samples in chunks {
            let data = pcm(samples)
            XCTAssertEqual(PcmFormat.level(of: data),
                           PcmFormat.level(fromMeanSquare: PcmFormat.meanSquare(of: data)),
                           "one statistic, two spellings")
        }
    }

    func testMeanSquareOfAConstantAmplitudeSquareWave() {
        // ±8192 = 0.25 full scale → mean-square 0.0625 → RMS 0.25 → ×4 = 1.0 (clamped edge).
        let data = pcm([8192, -8192, 8192, -8192])
        XCTAssertEqual(PcmFormat.meanSquare(of: data), 0.0625, accuracy: 1e-6)
        XCTAssertEqual(PcmFormat.level(of: data), 1.0, accuracy: 1e-4)
    }

    func testAveragingWindowsInMeanSquareSpaceMatchesAWholeWindowComputation() {
        // The floor estimate averages three chunk mean-squares; that must equal
        // the mean-square of the concatenated 300 ms window (equal-size chunks).
        let c1: [Int16] = Array(repeating: 400, count: 160)
        let c2: [Int16] = Array(repeating: 1200, count: 160)
        let c3: [Int16] = Array(repeating: 800, count: 160)
        let windowed = (PcmFormat.meanSquare(of: pcm(c1))
                        + PcmFormat.meanSquare(of: pcm(c2))
                        + PcmFormat.meanSquare(of: pcm(c3))) / 3.0
        let whole = PcmFormat.meanSquare(of: pcm(c1 + c2 + c3))
        XCTAssertEqual(windowed, whole, accuracy: 1e-12)
    }

    func testEmptyDataIsSilent() {
        XCTAssertEqual(PcmFormat.meanSquare(of: Data()), 0)
        XCTAssertEqual(PcmFormat.level(of: Data()), 0)
    }
}
