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
      warnings.append(
        Localized.text("Automatic switching is blocked; recovery evidence needs review."))
    }
    if notice { warnings.append(Localized.text(status)) }
    if failed && status != NoticePresenter.message(.commandFailed) {
      warnings.append(
        Localized.text("The last audio change failed. See Details for the command result."))
    }
    if detectionOff && status != NoticePresenter.message(.detectionDisabled) {
      warnings.append(
        Localized.text("Turn on Automatic Ear Detection in Bluetooth Settings to use MonoPods."))
    }
    if withoutEarDetection {
      warnings.append(
        Localized.text("AirPods Max have no ear detection, so MonoPods cannot switch."))
    }
    if unavailable {
      warnings.append(Localized.text("Waiting for a reliable ear detection connection."))
    }
    if !loginCaption.isEmpty && loginCaption != LoginText.nextLogin {
      warnings.append(Localized.text(loginCaption))
    }
    if snapshot?.audio?.systemMono == .on {
      warnings.append(Localized.text("System Mono Audio is on; automatic switching is paused."))
    }
    self.warnings = warnings

    if blocked {
      summary = Localized.text("Automation Blocked")
      symbol = "exclamationmark.triangle"
    } else if failed {
      summary = Localized.text("Audio Change Failed")
      symbol = "exclamationmark.triangle"
    } else if notice {
      summary = Localized.text("Needs Attention")
      symbol = "exclamationmark.triangle"
    } else if detectionOff {
      summary = Localized.text("Automatic Ear Detection Off")
      symbol = "ear.badge.waveform"
    } else if unavailable {
      summary = Localized.text("Ear Detection Unavailable")
      symbol = "exclamationmark.triangle"
    } else if withoutEarDetection {
      // Only AirPods Max lack ear detection. This outranks startup and the ear count: with this
      // output neither can lead to a switch.
      summary = Localized.text("AirPods Max Not Supported")
      symbol = "airpodsmax"
    } else if snapshot == nil || snapshot?.operational == false {
      summary =
        status == "Waiting for the command owner"
        ? Localized.text("Waiting for MonoPods…") : Localized.text("Starting…")
      symbol = "hourglass"
    } else if !outputPresent {
      summary = Localized.text("No AirPods Audio Output")
      symbol = "airpodspro"
    } else if snapshot?.detection == .unknown || snapshot?.count == nil {
      summary = Localized.text("Waiting for Ear Detection")
      symbol = "ear.badge.waveform"
    } else {
      switch snapshot?.count {
      case 0: summary = Localized.text("No AirPods in Ear")
      case 1: summary = Localized.text("One AirPod in Use")
      case 2: summary = Localized.text("Two AirPods in Use")
      default: summary = Localized.text("Waiting for Ear Detection")
      }
      symbol = "airpodspro"
    }
    let detection: String
    switch snapshot?.detection {
    case .on: detection = Localized.text("On")
    case .off: detection = Localized.text("Off")
    default: detection = Localized.text("Unknown")
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
      output = Localized.text("None")
    } else if routeName == "No Bluetooth output" {
      output = Localized.text(routeName)
    } else {
      output = routeName
    }
    details = [
      Localized.format("Accessibility Mono Audio: %@", systemMono),
      currentAudio,
      Localized.format("Audio Output: %@", output),
      Localized.format(
        "Model: %@",
        outputPresent ? model?.name ?? Localized.text("Not Recognized") : Localized.text("None")),
      Localized.format("AirPods in Use: %@", count),
      Localized.format("Automatic Ear Detection: %@", detection),
      Localized.format("Last Command: %@", command),
      Localized.format("Status: %@", Localized.text(status)),
    ]
  }
}
