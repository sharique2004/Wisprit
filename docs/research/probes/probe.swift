import Foundation
import Speech
import AVFoundation

@main struct P {
  static func main() async {
    print("SpeechTranscriber.isAvailable:", SpeechTranscriber.isAvailable)
    let st = await SpeechTranscriber.supportedLocales
    print("SpeechTranscriber.supportedLocales (\(st.count)):", st.map{$0.identifier(.bcp47)}.sorted().joined(separator: ","))
    let si = await SpeechTranscriber.installedLocales
    print("SpeechTranscriber.installedLocales (\(si.count)):", si.map{$0.identifier(.bcp47)}.sorted().joined(separator: ","))
    let dt = await DictationTranscriber.supportedLocales
    print("DictationTranscriber.supportedLocales (\(dt.count)):", dt.map{$0.identifier(.bcp47)}.sorted().joined(separator: ","))
    let di = await DictationTranscriber.installedLocales
    print("DictationTranscriber.installedLocales (\(di.count)):", di.map{$0.identifier(.bcp47)}.sorted().joined(separator: ","))
    print("maximumReservedLocales:", AssetInventory.maximumReservedLocales)
    print("reservedLocales:", await AssetInventory.reservedLocales.map{$0.identifier(.bcp47)})

    let t = SpeechTranscriber(locale: Locale(identifier:"en-US"), preset: .progressiveTranscription)
    print("ST progressiveTranscription reporting:", SpeechTranscriber.Preset.progressiveTranscription.reportingOptions)
    print("ST progressiveTranscription transcription:", SpeechTranscriber.Preset.progressiveTranscription.transcriptionOptions)
    print("ST progressiveTranscription attributes:", SpeechTranscriber.Preset.progressiveTranscription.attributeOptions)
    let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
    print("ST bestAvailableAudioFormat:", f as Any)
    print("ST availableCompatibleAudioFormats:", await t.availableCompatibleAudioFormats)

    let d = DictationTranscriber(locale: Locale(identifier:"en-US"), preset: .progressiveShortDictation)
    for p in [("phrase",DictationTranscriber.Preset.phrase),("shortDictation",.shortDictation),("progressiveShortDictation",.progressiveShortDictation),("progressiveLongDictation",.progressiveLongDictation),("longDictation",.longDictation)] {
      print("DT preset \(p.0): hints=\(p.1.contentHints) trans=\(p.1.transcriptionOptions) report=\(p.1.reportingOptions) attr=\(p.1.attributeOptions)")
    }
    let fd = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [d])
    print("DT bestAvailableAudioFormat:", fd as Any)
    print("DT availableCompatibleAudioFormats:", await d.availableCompatibleAudioFormats)
    print("supportedPhonemes en-US count:", SFCustomLanguageModelData.supportedPhonemes(locale: Locale(identifier:"en_US")).count)
    print("supportedPhonemes en-US:", SFCustomLanguageModelData.supportedPhonemes(locale: Locale(identifier:"en_US")).joined(separator:" "))
    print("supportedPhonemes fr-FR count:", SFCustomLanguageModelData.supportedPhonemes(locale: Locale(identifier:"fr_FR")).count)
    print("supportedPhonemes de-DE count:", SFCustomLanguageModelData.supportedPhonemes(locale: Locale(identifier:"de_DE")).count)
    print("supportedPhonemes hi-IN count:", SFCustomLanguageModelData.supportedPhonemes(locale: Locale(identifier:"hi_IN")).count)
    print("supportedPhonemes es-ES count:", SFCustomLanguageModelData.supportedPhonemes(locale: Locale(identifier:"es_ES")).count)
    print("SFSpeechRecognizer.supportedLocales count:", SFSpeechRecognizer.supportedLocales().count)
  }
}
