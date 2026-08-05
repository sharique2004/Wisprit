import AVFoundation
import Foundation
import Speech
@main struct FCV {
  static func main() async {
    let a = Array(CommandLine.arguments.dropFirst())
    var ctx: [String] = []
    if a.count >= 3, let d = FileManager.default.contents(atPath: a[2]),
       let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
       let s = o["strings"] as? [String] { ctx = s }
    let mode = a[1]
    let loc = Locale(identifier: "en-US")
    var mods: [any SpeechModule] = []
    var st: SpeechTranscriber? = nil; var dt: DictationTranscriber? = nil
    if mode != "dict" { let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []); st = t; mods.append(t) }
    if mode != "speech" { let t = DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: []); dt = t; mods.append(t) }
    do {
      if let r = try await AssetInventory.assetInstallationRequest(supporting: mods) { try await r.downloadAndInstall() }
      let c = AnalysisContext(); if !ctx.isEmpty { c.contextualStrings[.general] = ctx }
      let f = try AVAudioFile(forReading: URL(fileURLWithPath: a[0]))
      let an = try await SpeechAnalyzer(inputAudioFile: f, modules: mods, options: nil, analysisContext: c, finishAfterFile: true)
      var so = ""; var dof = ""
      await withTaskGroup(of: Void.self) { g in
        if let s = st { g.addTask { do { for try await r in s.results { so += "|" + String(r.text.characters) } } catch {} } }
        if let d = dt { g.addTask { do { for try await r in d.results { dof += String(r.text.characters) } } catch {} } }
        g.addTask { try? await an.finalizeAndFinishThroughEndOfInput() }
      }
      print("ST[\(ctx.count)]: \(so)\nDT[\(ctx.count)]: \(dof)")
    } catch { print("err \(error)") }
  }
}
