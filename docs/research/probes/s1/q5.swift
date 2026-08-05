import Foundation
import Speech
@main struct M { static func main() async {
  print("SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")
  let st = SpeechTranscriber(locale: Locale(identifier:"en-US"), preset: .progressiveTranscription)
  let dt = DictationTranscriber(locale: Locale(identifier:"en-US"), preset: .progressiveShortDictation)
  print("ST status = \(await AssetInventory.status(forModules: [st]))")
  print("DT status = \(await AssetInventory.status(forModules: [dt]))")
  print("ST+DT status = \(await AssetInventory.status(forModules: [st, dt]))")
  print("ST installed = \((await SpeechTranscriber.installedLocales).map{$0.identifier})")
  print("DT installed = \((await DictationTranscriber.installedLocales).map{$0.identifier})")
  print("reserved = \((await AssetInventory.reservedLocales).map{$0.identifier}) max=\(AssetInventory.maximumReservedLocales)")
  print("progressiveTranscription reporting = \(SpeechTranscriber.Preset.progressiveTranscription.reportingOptions)")
  print("progressiveShortDictation reporting = \(DictationTranscriber.Preset.progressiveShortDictation.reportingOptions) hints=\(DictationTranscriber.Preset.progressiveShortDictation.contentHints) opts=\(DictationTranscriber.Preset.progressiveShortDictation.transcriptionOptions)")
  exit(0)
}}
