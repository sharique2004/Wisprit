// ST vs DT accuracy on neutral sentences (no dictionary terms), + WER vs known ground truth
import Foundation
import Speech
import AVFoundation

let TRUTH: [Int: String] = [
  1: "Hi Sharique, please add this to Wisprit and InsForge.",
  2: "The quarterly report shows a significant increase in customer retention across all regions.",
  3: "Please schedule a meeting with the engineering team for Thursday afternoon at three o'clock.",
  4: "I think we should refactor the authentication module before the next release.",
  5: "Sharique Khatri is the lead developer on the Wisprit project.",
  6: "Could you send me the updated documentation and the deployment checklist by tomorrow morning."
]

func norm(_ s: String) -> [String] {
    let lowered = s.lowercased()
    let cleaned = lowered.map { ch -> Character in
        (ch.isLetter || ch.isNumber || ch == " " || ch == "'") ? ch : " "
    }
    return String(cleaned).split(separator: " ").map(String.init)
}

func wer(_ ref: [String], _ hyp: [String]) -> (Int, Int) {
    var d = Array(repeating: Array(repeating: 0, count: hyp.count + 1), count: ref.count + 1)
    for i in 0...ref.count { d[i][0] = i }
    for j in 0...hyp.count { d[0][j] = j }
    for i in 1...max(ref.count,1) where ref.count > 0 {
        for j in 1...max(hyp.count,1) where hyp.count > 0 {
            d[i][j] = ref[i-1] == hyp[j-1] ? d[i-1][j-1]
                    : 1 + min(d[i-1][j-1], min(d[i-1][j], d[i][j-1]))
        }
    }
    return (d[ref.count][hyp.count], ref.count)
}

func stRun(_ f: URL) async throws -> String {
    let m = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
    let a = SpeechAnalyzer(modules: [m])
    let c = Task { () -> String in var s = ""; for try await r in m.results where r.isFinal { s += String(r.text.characters) }; return s }
    let af = try AVAudioFile(forReading: f)
    if let last = try await a.analyzeSequence(from: af) { try await a.finalizeAndFinish(through: last) } else { await a.cancelAndFinishNow() }
    return (try await c.value).trimmingCharacters(in: .whitespaces)
}

func dtRun(_ f: URL) async throws -> String {
    let m = DictationTranscriber(locale: Locale(identifier: "en-US"),
                                 contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    let a = SpeechAnalyzer(modules: [m])
    let c = Task { () -> String in var s = ""; for try await r in m.results where r.isFinal { s += String(r.text.characters) }; return s }
    let af = try AVAudioFile(forReading: f)
    if let last = try await a.analyzeSequence(from: af) { try await a.finalizeAndFinish(through: last) } else { await a.cancelAndFinishNow() }
    return (try await c.value).trimmingCharacters(in: .whitespaces)
}

@main struct M {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        var stE = 0, stN = 0, dtE = 0, dtN = 0
        for i in 1...6 {
            let f = URL(fileURLWithPath: "\(dir)/c\(i).wav")
            let ref = norm(TRUTH[i]!)
            let st = try await stRun(f); try? await Task.sleep(nanoseconds: 1_500_000_000)
            let dt = try await dtRun(f); try? await Task.sleep(nanoseconds: 1_500_000_000)
            let (e1, n1) = wer(ref, norm(st)); let (e2, n2) = wer(ref, norm(dt))
            stE += e1; stN += n1; dtE += e2; dtN += n2
            print("c\(i) [\(n1) words]  ST err=\(e1)  DT err=\(e2)")
            print("   TRUTH: \(TRUTH[i]!)")
            print("   ST   : \(st)")
            print("   DT   : \(dt)")
        }
        print(String(format: "\nAGGREGATE  ST WER = %.1f%% (%d/%d)   DT WER = %.1f%% (%d/%d)",
                     Double(stE)/Double(stN)*100, stE, stN, Double(dtE)/Double(dtN)*100, dtE, dtN))
        print("DONE"); exit(0)
    }
}
