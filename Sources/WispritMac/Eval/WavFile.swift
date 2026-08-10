#if os(macOS)
import Foundation
import WispritEngine

/// Canonical 16 kHz mono Int16 PCM → a WAVE file, and back.
///
/// A 44-byte RIFF header written by hand rather than `AVAudioFile(forWriting:)`,
/// for the same reason `tools/eval/corpus/tts-samantha/generate.sh` asks `say`
/// for `LEI16@16000`: the bytes `MicCapture` hands us are already
/// `PcmFormat.canonical`, and the only correct thing to do with them is store
/// them unchanged. An encoder in the path could resample, dither, or write a
/// float file that reads back as something slightly different — and the file's
/// sha256 is the eval cache key, so "slightly different" means every cached
/// transcript for that clip is describing audio nobody has.
///
/// Pure, so the header is asserted byte by byte instead of by listening.
enum WavFile {

    static let headerBytes = 44
    /// 16 kHz × 2 bytes = 32000. Named because every duration in the corpus is
    /// this number and a wrong one is invisible.
    static var bytesPerSecond: Int { Int(PcmFormat.sampleRate) * PcmFormat.bytesPerFrame }

    /// The file `audio/<speaker>/<id>.wav` holds.
    static func data(pcm: Data) -> Data {
        var out = Data(capacity: headerBytes + pcm.count)
        let dataSize = UInt32(pcm.count)

        out.append(contentsOf: Array("RIFF".utf8))
        out.append(le32(36 + dataSize))
        out.append(contentsOf: Array("WAVE".utf8))

        out.append(contentsOf: Array("fmt ".utf8))
        out.append(le32(16))                                          // PCM chunk size
        out.append(le16(1))                                           // format: PCM
        out.append(le16(UInt16(PcmFormat.channels)))
        out.append(le32(UInt32(PcmFormat.sampleRate)))
        out.append(le32(UInt32(bytesPerSecond)))                      // byte rate
        out.append(le16(UInt16(PcmFormat.bytesPerFrame)))             // block align
        out.append(le16(UInt16(PcmFormat.bytesPerFrame * 8)))         // bits per sample

        out.append(contentsOf: Array("data".utf8))
        out.append(le32(dataSize))
        out.append(pcm)
        return out
    }

    /// Whole milliseconds, by the same integer arithmetic `generate.sh` uses, so
    /// a human clip and a synthetic one of the same length report the same
    /// number. Nothing is scored on this field; it is what makes "why is that
    /// clip 40 ms long" answerable from the manifest alone.
    static func durationMs(pcmBytes: Int) -> Int {
        pcmBytes * 1000 / bytesPerSecond
    }

    static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }
}
#endif
