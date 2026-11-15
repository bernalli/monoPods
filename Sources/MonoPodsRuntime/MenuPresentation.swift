import MonoPodsCore

/// The state that the first row of the menu names. `MenuPresentation` picks the first case that
/// applies, in the order of the cases.
public enum MenuSituation: CaseIterable, Sendable {
  case installingUpdate, blocked, commandFailed, detectionOff, detectionUnavailable, airPodsMax
  case starting, noOutput, switchingPaused, waitingForEarDetection, noneInEar, oneInEar, twoInEar

  /// The first row.
  public var summary: String {
    switch self {
    case .installingUpdate: return Localized.text("Installing Update\u{2026}")
    case .blocked: return Localized.text("Automation Blocked")
    case .commandFailed: return Localized.text("Audio Change Failed")
    case .detectionOff: return Localized.text("Automatic Ear Detection Off")
    case .detectionUnavailable: return Localized.text("Ear Detection Unavailable")
    case .airPodsMax: return Localized.text("AirPods Max Not Supported")
    case .starting: return Localized.text("Starting\u{2026}")
    case .noOutput: return Localized.text("No AirPods Audio Output")
    case .switchingPaused: return Localized.text("Switching Paused")
    case .waitingForEarDetection: return Localized.text("Waiting for Ear Detection")
    case .noneInEar: return Localized.text("No AirPods in Ear")
    case .oneInEar: return Localized.text("One AirPod in Use")
    case .twoInEar: return Localized.text("Two AirPods in Use")
    }
  }

  /// The second row: only the reason or the remedy, never the first row again.
  public var reason: String? {
    switch self {
    case .installingUpdate: return Localized.text("MonoPods restarts when it is done.")
    case .blocked:
      return Localized.text("Automatic switching is blocked; recovery evidence needs review.")
    case .commandFailed: return Localized.text("See Details for the command result.")
    case .detectionOff: return Localized.text("Turn it on in Bluetooth Settings.")
    case .detectionUnavailable: return Localized.text("Waiting for a reliable connection.")
    case .airPodsMax: return Localized.text("AirPods Max have no ear detection.")
    case .switchingPaused: return Localized.text("Mono Audio is on in Accessibility settings.")
    case .starting, .noOutput, .waitingForEarDetection, .noneInEar, .oneInEar, .twoInEar:
      return nil
    }
  }

  /// The symbol of the first row. Only three cases show the warning triangle.
  public var symbol: String {
    switch self {
    case .blocked, .commandFailed, .detectionUnavailable: return "exclamationmark.triangle"
    case .detectionOff, .waitingForEarDetection: return "ear.badge.waveform"
    case .airPodsMax: return "airpodsmax"
    case .installingUpdate, .starting: return "hourglass"
    case .noOutput, .switchingPaused, .noneInEar, .oneInEar, .twoInEar: return "airpodspro"
    }
  }
}

/// User-facing state for the native menu. Diagnostics stay available without implying that the
/// last successful command is a measurement of the current system audio setting.
public struct MenuPresentation: Equatable, Sendable {
  public let situation: MenuSituation
  public let summary: String
  public let reason: String?
  public let symbol: String
  public let details: [String]

  public init(
    snapshot: EngineSnapshot?, routeName: String, routeModel: AirPodsModel?, status: String,
    waitingForUpdate: Bool
  ) {
    let outputPresent = !routeName.isEmpty && routeName != "No Bluetooth output"
    // Only a current output has a model; a stale one is ignored.
    let model = outputPresent ? routeModel : nil
    situation = Self.situation(
      snapshot: snapshot, outputPresent: outputPresent, model: model, status: status,
      waitingForUpdate: waitingForUpdate)
    summary = situation.summary
    reason = situation.reason
    symbol = situation.symbol
    details = Self.details(
      snapshot: snapshot, routeName: routeName, outputPresent: outputPresent, model: model,
      status: status)
  }

  /// The first rule that applies. A notice in `status` never replaces the summary; only a failed
  /// start, which persists, counts as blocked.
  private static func situation(
    snapshot: EngineSnapshot?, outputPresent: Bool, model: AirPodsModel?, status: String,
    waitingForUpdate: Bool
  ) -> MenuSituation {
    if waitingForUpdate { return .installingUpdate }
    if snapshot?.blocked == true || status == RuntimeStatus.invalidConfiguration {
      return .blocked
    }
    if (snapshot?.lastCompleted?.exitCode ?? 0) != 0 { return .commandFailed }
    if snapshot?.detection == .off { return .detectionOff }
    if snapshot?.operational == true && snapshot?.healthy == false {
      return .detectionUnavailable
    }
    // Only AirPods Max lack ear detection. This outranks startup and the ear count: with this
    // output neither can lead to a switch.
    if model?.earDetection == false { return .airPodsMax }
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

  private static func details(
    snapshot: EngineSnapshot?, routeName: String, outputPresent: Bool, model: AirPodsModel?,
    status: String
  ) -> [String] {
    // Whole-sentence keys: a fixed value must agree with the noun of its label in each language.
    let detection: String
    switch snapshot?.detection {
    case .on: detection = Localized.text("Automatic Ear Detection: On")
    case .off: detection = Localized.text("Automatic Ear Detection: Off")
    default: detection = Localized.text("Automatic Ear Detection: Unknown")
    }
    let command: String
    if let receipt = snapshot?.lastCompleted {
      command = Localized.format(
        "%@ (Exit %@)", receipt.target == .mono ? Localized.text("Mono") : Localized.text("Stereo"),
        String(receipt.exitCode))
    } else {
      command = Localized.text("None Yet")
    }
    let count: String
    if let value = snapshot?.count {
      count = String(value)
    } else {
      count = Localized.text("Unknown")
    }
    let systemMono: String
    switch snapshot?.audio?.systemMono {
    case .on: systemMono = Localized.text("On")
    case .off: systemMono = Localized.text("Off")
    default: systemMono = Localized.text("Unavailable (treated as off)")
    }
    let currentAudio =
      snapshot?.audio.map {
        let mode =
          $0.mode == .mono
          ? Localized.text("Mono")
          : $0.mode == .stereo ? Localized.text("Stereo") : Localized.text("Unknown")
        return Localized.format("Current Audio: %@ (OSStatus %@)", mode, String($0.status))
      } ?? Localized.format("Current Audio: %@", Localized.text("Unknown"))
    let output: String
    if routeName.isEmpty {
      output = Localized.text("Audio Output: None")
    } else if routeName == "No Bluetooth output" {
      output = Localized.format("Audio Output: %@", Localized.text(routeName))
    } else {
      output = Localized.format("Audio Output: %@", routeName)
    }
    return [
      output,
      outputPresent
        ? Localized.format("Model: %@", model?.name ?? Localized.text("Not Recognized"))
        : Localized.text("Model: None"),
      detection,
      Localized.format("AirPods in Use: %@", count),
      currentAudio,
      Localized.format("Mono Audio: %@", systemMono),
      Localized.format("Last Command: %@", command),
      Localized.format("Status: %@", Localized.text(status)),
    ]
  }
}
