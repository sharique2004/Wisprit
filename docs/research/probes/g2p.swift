import Foundation
import AppKit
import AVFoundation

let synth = NSSpeechSynthesizer(voice: nil)
for w in ["Sharique","Shariq","Sharik","Cherie","Krzysztof","InsForge","Wisprit","Siobhan","Nguyen"] {
    let p = synth?.phonemes(from: w) ?? "nil"
    print("\(w)\t\(p)")
}
// Does SFCustomLanguageModelData exist / supportedPhonemes on macOS?
