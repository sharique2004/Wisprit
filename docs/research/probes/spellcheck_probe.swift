// spellcheck_probe — measure Apple FoundationModels @Generable guided-generation
// for spoken spelling-correction detection.  Reads one transcript per stdin line,
// prints one JSON line with the structured verdict and elapsed ms.

import Foundation
import FoundationModels

@Generable
struct SpellFix {
    @Guide(description: "true only if the speaker spelled out a word letter-by-letter in order to correct an earlier misheard word")
    var isCorrection: Bool
    @Guide(description: "the earlier word in the transcript that is being corrected, copied verbatim; empty string if none")
    var targetWord: String
    @Guide(description: "the corrected word assembled from the spelled letters, normal capitalization; empty string if none")
    var correctedWord: String
}

let instructions = """
You analyse one raw speech-to-text transcript from a dictation app. Decide \
whether the speaker spelled a word out letter-by-letter in order to fix a word \
the recogniser got wrong earlier in the same transcript.

A spelling correction usually looks like a run of single letters, often joined \
by hyphens (for example "S-H-A-R-I-Q-U-E"), sometimes introduced by a phrase \
like "actually it's", "no no", "that's spelled", "spell that", "correction".

Set isCorrection to true ONLY when the letters spell a replacement for an \
earlier word. Set it to false when the letters are ordinary dictated content \
such as an acronym, an initialism, a licence plate, or a password the user \
wants typed literally, and false when there is no letter run at all.

targetWord must be copied exactly as it appears earlier in the transcript. \
correctedWord is the letters joined into one word with ordinary capitalisation.
"""

let session = LanguageModelSession(instructions: instructions)
let opts = GenerationOptions(temperature: 0.0)

while let line = readLine(strippingNewline: true) {
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { continue }
    let t0 = Date()
    do {
        let r = try await session.respond(
            to: "<transcript>\(t)</transcript>",
            generating: SpellFix.self,
            options: opts)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let c = r.content
        let obj: [String: Any] = ["in": t, "isCorrection": c.isCorrection,
                                  "target": c.targetWord, "corrected": c.correctedWord,
                                  "ms": ms]
        let d = try JSONSerialization.data(withJSONObject: obj)
        print(String(data: d, encoding: .utf8)!)
    } catch {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("{\"in\":\"\(t)\",\"error\":\"\(error)\",\"ms\":\(ms)}")
    }
    fflush(stdout)
}
