import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

private let languages = ["en", "it", "es", "fr", "de", "pt-BR", "ja", "zh-Hans"]

/// Deterministic generator with a fixed seed (SplitMix64).
private struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
}

/// The English rows and the symbol of every situation, as approved.
private let approvedRows: [MenuSituation: (String, String?, String)] = [
  .installingUpdate: (
    "Installing Update\u{2026}", "MonoPods restarts when it is done.", "hourglass"
  ),
  .blocked: (
    "Automation Blocked", "Automatic switching is blocked; recovery evidence needs review.",
    "exclamationmark.triangle"
  ),
  .commandFailed: (
    "Audio Change Failed", "See Details for the command result.", "exclamationmark.triangle"
  ),
  .detectionOff: (
    "Automatic Ear Detection Off", "Turn it on in Bluetooth Settings.", "ear.badge.waveform"
  ),
  .detectionUnavailable: (
    "Ear Detection Unavailable", "Waiting for a reliable connection.", "exclamationmark.triangle"
  ),
  .airPodsMax: ("AirPods Max Not Supported", "AirPods Max have no ear detection.", "airpodsmax"),
  .starting: ("Starting\u{2026}", nil, "hourglass"),
  .noOutput: ("No AirPods Audio Output", nil, "airpodspro"),
  .switchingPaused: (
    "Switching Paused", "Mono Audio is on in Accessibility settings.", "airpodspro"
  ),
  .waitingForEarDetection: ("Waiting for Ear Detection", nil, "ear.badge.waveform"),
  .noneInEar: ("No AirPods in Ear", nil, "airpodspro"),
  .oneInEar: ("One AirPod in Use", nil, "airpodspro"),
  .twoInEar: ("Two AirPods in Use", nil, "airpodspro"),
]

/// One input of `MenuPresentation`.
private struct MenuInput {
  var snapshot: EngineSnapshot?
  var route: String
  var model: AirPodsModel?
  var status: String
  var waitingForUpdate: Bool

  var presentation: MenuPresentation {
    MenuPresentation(
      snapshot: snapshot, routeName: route, routeModel: model, status: status,
      waitingForUpdate: waitingForUpdate)
  }
}

private func healthySnapshot() -> EngineSnapshot {
  var snapshot = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  snapshot.operational = true
  snapshot.healthy = true
  snapshot.detection = .on
  snapshot.count = 1
  snapshot.lastCompleted = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  return snapshot
}

private func input(
  _ snapshot: EngineSnapshot? = healthySnapshot(), route: String = "AirPods Pro",
  model: AirPodsModel? = AirPodsModel.model(productID: 0x2014), status: String = "Observing",
  waitingForUpdate: Bool = false
) -> MenuInput {
  MenuInput(
    snapshot: snapshot, route: route, model: model, status: status,
    waitingForUpdate: waitingForUpdate)
}

/// Every status the runtime or a notice can show, and two it never shows.
private let statuses: [String] =
  [
    Notice.detectionDisabled, .detectionQuitReminder, .previousCrash, .persistenceFailed,
    .recoveryBlocked, .stereoNotRestored, .commandFailed,
  ].map { NoticePresenter.message($0) } + [
    "Starting", "Observing", "Waiting for verified stream transport",
    "Automation blocked; recovery evidence needs review", "Waiting for the command owner",
    "Diagnostic persistence failed", UpdateText.installing, RuntimeStatus.invalidConfiguration,
    "Something unexpected", "",
  ]

private func randomInputs() -> [MenuInput] {
  var random = SplitMix64(state: 0x4D6F_6E6F_506F_6473)
  let receipts: [CommandReceipt?] = [
    nil, CommandReceipt(id: 1, target: .mono, exitCode: 0),
    CommandReceipt(id: 2, target: .stereo, exitCode: 0),
    CommandReceipt(id: 3, target: .stereo, exitCode: 7),
    CommandReceipt(id: 4, target: .mono, exitCode: -1),
  ]
  let audio: [AudioReading?] = [
    nil, AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .on),
    AudioReading(generation: 1, mode: .mono, status: 0, systemMono: .off),
    AudioReading(generation: 1, mode: nil, status: -50, systemMono: .unreadable),
  ]
  let routes = [
    "", "No Bluetooth output", "AirPods Pro", String(repeating: "Personal AirPods ", count: 6),
  ]
  let models = [nil, AirPodsModel.model(productID: 0x2014), AirPodsModel.model(productID: 0x200A)]
  return (0..<3000).map { _ in
    var snapshot: EngineSnapshot?
    if random.below(8) != 0 {
      var value = Engine(build: testBuild, run: 1, boot: "boot").snapshot
      value.blocked = random.below(2) == 0
      value.operational = random.below(2) == 0
      value.healthy = random.below(2) == 0
      value.detection = random.pick([Detection.on, .off, .unknown])
      value.count = random.pick([nil, 0, 1, 2, 3, -1])
      value.lastCompleted = random.pick(receipts)
      value.audio = random.pick(audio)
      snapshot = value
    }
    return MenuInput(
      snapshot: snapshot, route: random.pick(routes), model: random.pick(models),
      status: random.pick(statuses), waitingForUpdate: random.below(5) == 0)
  }
}

/// The priority of the approved menu, written from the specification and not from the code.
private func expectedSituation(_ input: MenuInput) -> MenuSituation {
  let snapshot = input.snapshot
  let outputPresent = !input.route.isEmpty && input.route != "No Bluetooth output"
  let model = outputPresent ? input.model : nil
  if input.waitingForUpdate { return .installingUpdate }
  if snapshot?.blocked == true || input.status == RuntimeStatus.invalidConfiguration {
    return .blocked
  }
  if let receipt = snapshot?.lastCompleted, receipt.exitCode != 0 { return .commandFailed }
  if snapshot?.detection == .off { return .detectionOff }
  if let snapshot, snapshot.operational, !snapshot.healthy { return .detectionUnavailable }
  if let model, !model.earDetection { return .airPodsMax }
  guard let snapshot, snapshot.operational else { return .starting }
  if !outputPresent { return .noOutput }
  if snapshot.audio?.systemMono == .on { return .switchingPaused }
  if snapshot.detection == .unknown { return .waitingForEarDetection }
  switch snapshot.count {
  case 0: return .noneInEar
  case 1: return .oneInEar
  case 2: return .twoInEar
  default: return .waitingForEarDetection
  }
}

@Test func everySituationHasItsRows() {
  #expect(Set(MenuSituation.allCases) == Set(approvedRows.keys))
  #expect(MenuSituation.allCases.count == 13)
  for situation in MenuSituation.allCases {
    let (summary, reason, symbol) = approvedRows[situation] ?? ("", nil, "")
    #expect(situation.summary == summary, "\(situation)")
    #expect(situation.reason == reason, "\(situation)")
    #expect(situation.symbol == symbol, "\(situation)")
  }
}

@Test func aCanonicalInputReachesEverySituation() {
  var blocked = healthySnapshot()
  blocked.blocked = true
  var failed = healthySnapshot()
  failed.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 7)
  var detectionOff = healthySnapshot()
  detectionOff.detection = .off
  detectionOff.count = nil
  var unavailable = healthySnapshot()
  unavailable.healthy = false
  var paused = healthySnapshot()
  paused.audio = AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .on)
  var unknownCount = healthySnapshot()
  unknownCount.count = nil
  func counted(_ count: Int) -> EngineSnapshot {
    var snapshot = healthySnapshot()
    snapshot.count = count
    return snapshot
  }
  let cases: [(MenuInput, MenuSituation)] = [
    (input(nil, waitingForUpdate: true), .installingUpdate),
    (input(blocked), .blocked),
    (input(failed), .commandFailed),
    (input(detectionOff), .detectionOff),
    (input(unavailable), .detectionUnavailable),
    (input(model: AirPodsModel.model(productID: 0x200A)), .airPodsMax),
    (input(nil, status: "Starting"), .starting),
    (input(route: "No Bluetooth output"), .noOutput),
    (input(paused), .switchingPaused),
    (input(unknownCount), .waitingForEarDetection),
    (input(counted(0)), .noneInEar),
    (input(counted(1)), .oneInEar),
    (input(counted(2)), .twoInEar),
  ]
  #expect(Set(cases.map(\.1)) == Set(MenuSituation.allCases))
  for (input, situation) in cases {
    let menu = input.presentation
    #expect(menu.situation == situation)
    #expect(menu.summary == situation.summary)
    #expect(menu.reason == situation.reason)
    #expect(menu.symbol == situation.symbol)
  }
}

@Test func randomInputsFollowThePriorityOrder() {
  for input in randomInputs() {
    let menu = input.presentation
    let expected = expectedSituation(input)
    #expect(
      menu.situation == expected,
      "\(input.status) \(input.route) \(String(describing: input.snapshot))")
    #expect(menu.summary == expected.summary)
    #expect(menu.reason == expected.reason)
    #expect(menu.symbol == expected.symbol)
  }
}

@Test func noStatusButAnInvalidConfigurationChangesTheSituation() {
  for input in randomInputs() {
    var observing = input
    observing.status = "Observing"
    let reference = observing.presentation.situation
    for status in statuses where status != RuntimeStatus.invalidConfiguration {
      var other = input
      other.status = status
      let menu = other.presentation
      #expect(menu.situation == reference, "\(status)")
      #expect(menu.summary != "Needs Attention")
    }
  }
}

@Test func theSecondRowNeverRepeatsTheFirstInAnyLanguage() throws {
  for language in languages {
    let bundle = try #require(
      Bundle(
        path: repositoryRoot.appendingPathComponent("Resources/Localization/\(language).lproj")
          .path))
    Localized.$bundleOverride.withValue(bundle) {
      for situation in MenuSituation.allCases {
        let summary = situation.summary
        #expect(!summary.isEmpty, "\(language) \(situation)")
        guard let reason = situation.reason else { continue }
        #expect(!reason.isEmpty, "\(language) \(situation)")
        #expect(reason != summary, "\(language) \(situation)")
        #expect(!reason.localizedCaseInsensitiveContains(summary), "\(language) \(situation)")
        #expect(!summary.localizedCaseInsensitiveContains(reason), "\(language) \(situation)")
      }
    }
  }
}

@Test func atMostOneWarningTriangle() {
  let warnings: Set<MenuSituation> = [.blocked, .commandFailed, .detectionUnavailable]
  for situation in MenuSituation.allCases {
    #expect((situation.symbol == "exclamationmark.triangle") == warnings.contains(situation))
  }
}
