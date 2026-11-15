import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

private func table(_ language: String) throws -> Bundle {
  try #require(
    Bundle(
      path: repositoryRoot.appendingPathComponent("Resources/Localization/\(language).lproj").path))
}

private func details(
  detection: Detection, route: String = "AirPods Pro",
  model: AirPodsModel? = AirPodsModel.model(productID: 0x2014)
) -> [String] {
  var snapshot = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  snapshot.operational = true
  snapshot.healthy = true
  snapshot.detection = detection
  snapshot.count = 1
  return MenuPresentation(
    snapshot: snapshot, routeName: route, routeModel: model, status: "Observing",
    loginCaption: LoginText.nextLogin
  ).details
}

/// The Details lines that join a label and a fixed value, per language: detection on, off and
/// unknown, then no audio output and no model. The value agrees with the label's noun.
private let expectedLines: [String: [String]] = [
  "en": [
    "Automatic Ear Detection: On", "Automatic Ear Detection: Off",
    "Automatic Ear Detection: Unknown", "Audio Output: None", "Model: None",
  ],
  "it": [
    "Rilevamento automatico dell’orecchio: Attivato",
    "Rilevamento automatico dell’orecchio: Disattivato",
    "Rilevamento automatico dell’orecchio: Sconosciuto", "Uscita audio: Nessuna",
    "Modello: Nessuno",
  ],
  "es": [
    "Detección automática de oreja: Activada", "Detección automática de oreja: Desactivada",
    "Detección automática de oreja: Desconocida", "Salida de audio: Ninguna", "Modelo: Ninguno",
  ],
  "fr": [
    "Détection automatique des oreilles : Activée",
    "Détection automatique des oreilles : Désactivée",
    "Détection automatique des oreilles : Inconnue", "Sortie audio : Aucune", "Modèle : Aucun",
  ],
  "de": [
    "Automatische Ohrerkennung: Ein", "Automatische Ohrerkennung: Aus",
    "Automatische Ohrerkennung: Unbekannt", "Audioausgang: Keiner", "Modell: Keines",
  ],
  "pt-BR": [
    "Detecção automática de ouvido: Ativada", "Detecção automática de ouvido: Desativada",
    "Detecção automática de ouvido: Desconhecida", "Saída de áudio: Nenhuma", "Modelo: Nenhum",
  ],
  "ja": ["自動耳検出: オン", "自動耳検出: オフ", "自動耳検出: 不明", "オーディオ出力: なし", "モデル: なし"],
  "zh-Hans": ["自动人耳检测：开启", "自动人耳检测：关闭", "自动人耳检测：未知", "音频输出：无", "型号：无"],
]

@Test func detailsLinesAgreeWithTheirLabelInEveryLanguage() throws {
  for (language, lines) in expectedLines {
    let bundle = try table(language)
    Localized.$bundleOverride.withValue(bundle) {
      for (index, detection) in [Detection.on, .off, .unknown].enumerated() {
        #expect(details(detection: detection).contains(lines[index]), "\(language) \(detection)")
      }
      let missing = details(detection: .on, route: "")
      #expect(missing.contains(lines[3]), "\(language) no output")
      #expect(missing.contains(lines[4]), "\(language) no model")
      #expect(
        details(detection: .on, route: "No Bluetooth output").contains(lines[4]), "\(language)")
    }
  }
}

/// A generated table where every value is its key in brackets shows which keys a line was built
/// from: a fixed value inside a label would read `[Label: [Value]]`.
@Test func detailsNeverPutAFixedValueIntoALabel() throws {
  let english = try table("en")
  let source = try #require(
    english.url(forResource: "Localizable", withExtension: "strings"))
  let keys = try #require(NSDictionary(contentsOf: source) as? [String: String]).keys
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "monopods-marked-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let marked = Dictionary(uniqueKeysWithValues: keys.map { ($0, "[\($0)]") })
  try PropertyListSerialization.data(fromPropertyList: marked, format: .xml, options: 0)
    .write(to: directory.appendingPathComponent("Localizable.strings"))
  let bundle = try #require(Bundle(path: directory.path))
  let models = [nil, AirPodsModel.model(productID: 0x2014), AirPodsModel.model(productID: 0x200A)]
  Localized.$bundleOverride.withValue(bundle) {
    for (detection, word) in [(Detection.on, "On"), (.off, "Off"), (.unknown, "Unknown")] {
      #expect(details(detection: detection).contains("[Automatic Ear Detection: \(word)]"))
      for route in ["", "AirPods Pro", "No Bluetooth output"] {
        for model in models {
          let lines = details(detection: detection, route: route, model: model)
          for line in lines {
            for label in ["[Automatic Ear Detection: ", "[Audio Output: ", "[Model: "] {
              for value in ["[On]", "[Off]", "[Unknown]", "[None]"] {
                #expect(!(line.hasPrefix(label) && line.contains(value)), "\(line)")
              }
            }
          }
          if route.isEmpty { #expect(lines.contains("[Audio Output: None]")) }
          if route != "AirPods Pro" { #expect(lines.contains("[Model: None]")) }
        }
      }
    }
  }
}
