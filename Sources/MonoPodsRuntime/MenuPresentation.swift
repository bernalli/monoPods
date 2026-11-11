import MonoPodsCore

/// User-facing state for the native menu. Diagnostics stay available without implying that the
/// last successful command is a measurement of the current system audio setting.
public struct MenuPresentation: Equatable, Sendable {
  public let summary: String
  public let symbol: String
  public let warnings: [String]
  public let details: [String]

  public init(
    snapshot: EngineSnapshot?, routeName: String, routeModel: AirPodsModel?, status: String,
    loginCaption: String
  ) {
    let blocked = snapshot?.blocked == true
    let failed = (snapshot?.lastCompleted?.exitCode ?? 0) != 0
    let detectionOff = snapshot?.detection == .off
    let unavailable = snapshot?.operational == true && snapshot?.healthy == false
    let routineStatuses = [
      "Starting", "Observing", "Waiting for verified stream transport",
      "Automation blocked; recovery evidence needs review", "Waiting for the command owner",
    ]
    let notice = !status.isEmpty && !routineStatuses.contains(status)
    let outputPresent = !routeName.isEmpty && routeName != "No Bluetooth output"
    // Only a current output has a model; a stale one is ignored.
    let model = outputPresent ? routeModel : nil
    let withoutEarDetection = model?.earDetection == false
    var warnings: [String] = []
    let blockAlreadyReported = [
      NoticePresenter.message(.recoveryBlocked), NoticePresenter.message(.persistenceFailed),
    ].contains(status)
    if blocked && !blockAlreadyReported {
      warnings.append("Automatic switching is blocked; recovery evidence needs review.")
    }
    if notice { warnings.append(status) }
    if failed && status != NoticePresenter.message(.commandFailed) {
      warnings.append("The last audio change failed. See Details for the command result.")
    }
    if detectionOff && status != NoticePresenter.message(.detectionDisabled) {
      warnings.append("Turn on Automatic Ear Detection in Bluetooth Settings to use MonoPods.")
    }
    if withoutEarDetection {
      warnings.append("AirPods Max have no ear detection, so MonoPods cannot switch.")
    }
    if unavailable {
      warnings.append("Waiting for a reliable ear detection connection.")
    }
    if !loginCaption.isEmpty && loginCaption != LoginText.nextLogin {
      warnings.append(loginCaption)
    }
    if snapshot?.audio?.systemMono == .on {
      warnings.append("System Mono Audio is on; automatic switching is paused.")
    }
    self.warnings = warnings

    if blocked {
      summary = "Automation Blocked"
      symbol = "exclamationmark.triangle"
    } else if failed {
      summary = "Audio Change Failed"
      symbol = "exclamationmark.triangle"
    } else if notice {
      summary = "Needs Attention"
      symbol = "exclamationmark.triangle"
    } else if detectionOff {
      summary = "Automatic Ear Detection Off"
      symbol = "ear.badge.waveform"
    } else if unavailable {
      summary = "Ear Detection Unavailable"
      symbol = "exclamationmark.triangle"
    } else if withoutEarDetection {
      // Only AirPods Max lack ear detection. This outranks startup and the ear count: with this
      // output neither can lead to a switch.
      summary = "AirPods Max Not Supported"
      symbol = "airpodsmax"
    } else if snapshot == nil || snapshot?.operational == false {
      summary = status == "Waiting for the command owner" ? "Waiting for MonoPods…" : "Starting…"
      symbol = "hourglass"
    } else if !outputPresent {
      summary = "No AirPods Audio Output"
      symbol = "airpodspro"
    } else if snapshot?.detection == .unknown || snapshot?.count == nil {
      summary = "Waiting for Ear Detection"
      symbol = "ear.badge.waveform"
    } else {
      switch snapshot?.count {
      case 0: summary = "No AirPods in Ear"
      case 1: summary = "One AirPod in Use"
      case 2: summary = "Two AirPods in Use"
      default: summary = "Waiting for Ear Detection"
      }
      symbol = "airpodspro"
    }
    let detection: String
    switch snapshot?.detection {
    case .on: detection = "On"
    case .off: detection = "Off"
    default: detection = "Unknown"
    }
    let command: String
    if let receipt = snapshot?.lastCompleted {
      command = "\(receipt.target == .mono ? "Mono" : "Stereo") (Exit \(receipt.exitCode))"
    } else {
      command = "None Yet"
    }
    let count: String
    if let value = snapshot?.count {
      count = String(value)
    } else {
      count = "Unknown"
    }
    let systemMono: String
    switch snapshot?.audio?.systemMono {
    case .on: systemMono = "On"
    case .off: systemMono = "Off"
    default: systemMono = "Unavailable (treated as off)"
    }
    let currentAudio =
      snapshot?.audio.map {
        "Current Audio: \($0.mode == .mono ? "Mono" : $0.mode == .stereo ? "Stereo" : "Unknown") (OSStatus \($0.status))"
      } ?? "Current Audio: Unknown"
    details = [
      "Accessibility Mono Audio: \(systemMono)",
      currentAudio,
      "Audio Output: \(routeName.isEmpty ? "None" : routeName)",
      "Model: \(outputPresent ? model?.name ?? "Not Recognized" : "None")",
      "AirPods in Use: \(count)",
      "Automatic Ear Detection: \(detection)",
      "Last Command: \(command)",
      "Status: \(status)",
    ]
  }
}
