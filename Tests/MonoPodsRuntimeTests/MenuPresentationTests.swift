import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private func menuSnapshot() -> EngineSnapshot {
  var snapshot = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  snapshot.operational = true
  snapshot.healthy = true
  snapshot.detection = .on
  snapshot.count = 1
  snapshot.lastCompleted = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  return snapshot
}

private func presentation(
  _ snapshot: EngineSnapshot? = menuSnapshot(), route: String = "AirPods Pro",
  status: String = "Observing",
  login: String = LoginText.nextLogin, model: AirPodsModel? = AirPodsModel.model(productID: 0x2014)
) -> MenuPresentation {
  MenuPresentation(
    snapshot: snapshot, routeName: route, routeModel: model, status: status, loginCaption: login)
}

@Test func healthyMenuKeepsDiagnosticsInDetails() {
  let menu = presentation()
  #expect(menu.summary == "One AirPod in Use")
  #expect(menu.warnings.isEmpty)
  #expect(menu.details.contains("Last Command: Mono (Exit 0)"))
  #expect(menu.details.contains("Automatic Ear Detection: On"))
  #expect(menu.details.contains("AirPods in Use: 1"))
  #expect(!menu.summary.contains("Mono"))
}

@Test func missingCommandReceiptDoesNotCreateAFailureWarning() {
  var snapshot = menuSnapshot()
  snapshot.lastCompleted = nil
  let menu = presentation(snapshot)
  #expect(menu.summary == "One AirPod in Use")
  #expect(menu.warnings.isEmpty)
  #expect(menu.details.contains("Last Command: None Yet"))
  #expect(presentation(nil, status: "Starting").details.contains("Last Command: None Yet"))
}

@Test func detectionOffIsShownAsTheSummary() {
  var snapshot = menuSnapshot()
  snapshot.detection = .off
  let menu = presentation(snapshot)
  #expect(menu.summary == "Automatic Ear Detection Off")
  #expect(menu.warnings.contains { $0.contains("Bluetooth Settings") })
}

@Test func noOutputDoesNotShowStaleEarCountAsCurrent() {
  let menu = presentation(route: "No Bluetooth output")
  #expect(menu.summary == "No AirPods Audio Output")
  #expect(menu.warnings.isEmpty)
}

@Test func blockedEngineWinsWithoutHidingOtherWarnings() {
  var snapshot = menuSnapshot()
  snapshot.blocked = true
  snapshot.detection = .off
  let menu = presentation(snapshot, login: LoginText.failed)
  #expect(menu.summary == "Automation Blocked")
  #expect(menu.warnings.contains { $0.contains("recovery") })
  #expect(menu.warnings.contains { $0.contains("Bluetooth Settings") })
  #expect(menu.warnings.contains(LoginText.failed))
}

@Test func failedCommandIsShownAsTheSummary() {
  var snapshot = menuSnapshot()
  snapshot.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 7)
  let menu = presentation(snapshot)
  #expect(menu.summary == "Audio Change Failed")
  #expect(menu.details.contains("Last Command: Stereo (Exit 7)"))
  #expect(!menu.warnings.isEmpty)
}

@Test func unhealthyStreamIsNotPresentedAsHealthyOrJustOff() {
  var snapshot = menuSnapshot()
  snapshot.healthy = false
  let menu = presentation(snapshot)
  #expect(menu.summary == "Ear Detection Unavailable")
  #expect(!menu.warnings.isEmpty)
}

@Test func startupAndConfigurationFailureWorkWithoutSnapshot() {
  #expect(presentation(nil, status: "Starting").summary == "Starting…")
  let failure = "Configuration, manifest or runtime evidence is invalid. Automation is blocked."
  let menu = presentation(nil, status: failure)
  #expect(menu.summary == "Needs Attention")
  #expect(menu.warnings.contains(failure))
}

@Test func earCountsAndUnknownDetectionHaveDistinctStatuses() {
  var snapshot = menuSnapshot()
  snapshot.count = 2
  #expect(presentation(snapshot).summary == "Two AirPods in Use")
  snapshot.count = 0
  #expect(presentation(snapshot).summary == "No AirPods in Ear")
  snapshot.count = nil
  #expect(presentation(snapshot).summary == "Waiting for Ear Detection")
  #expect(presentation(snapshot).details.contains("AirPods in Use: Unknown"))
  snapshot.count = 1
  snapshot.detection = .unknown
  #expect(presentation(snapshot).summary == "Waiting for Ear Detection")
}

@Test func allLoginWarningsRemainVisibleAtFirstLevel() {
  for caption in [LoginText.failed, LoginText.notInstalled, LoginText.unsupervised] {
    #expect(presentation(login: caption).warnings.contains(caption))
  }
}

@Test func longNoticesAndDeviceNamesArePreservedAndWrappable() {
  let notice =
    "An audio command failed repeatedly. Automatic attempts for this target are blocked until the target or connection changes."
  let route = String(repeating: "Personal AirPods ", count: 12).trimmingCharacters(in: .whitespaces)
  let menu = presentation(route: route, status: notice)
  #expect(menu.warnings.contains(notice))
  #expect(menu.details.contains("Audio Output: \(route)"))
  for text in menu.warnings + menu.details {
    let lines = MenuText.lines(text)
    #expect(lines.allSatisfy { $0.count <= MenuText.width })
    #expect(lines.joined(separator: " ") == text)
  }
}

@Test func noticesDoNotRepeatTheSameSnapshotWarning() {
  let cases: [(Notice, Bool, Bool, Bool)] = [
    (.detectionDisabled, false, false, true),
    (.commandFailed, false, true, false),
    (.recoveryBlocked, true, false, false),
    (.persistenceFailed, true, false, false),
  ]
  for (notice, blocked, failed, detectionOff) in cases {
    var snapshot = menuSnapshot()
    snapshot.blocked = blocked
    snapshot.operational = !blocked
    snapshot.detection = detectionOff ? .off : .on
    snapshot.count = detectionOff ? nil : 1
    snapshot.lastCompleted = CommandReceipt(id: 2, target: .mono, exitCode: failed ? 7 : 0)
    let message = NoticePresenter.message(notice)
    #expect(presentation(snapshot, status: message).warnings == [message])
  }
}

@Test func systemMonoOverrideIsAWarningWithoutChangingSummaryOrReceipt() {
  for preference in [SystemMono.on, .off, .unreadable] {
    var snapshot = menuSnapshot()
    snapshot.audio = AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: preference)
    let menu = presentation(snapshot)
    #expect(menu.summary == "One AirPod in Use")
    #expect(menu.details.contains("Last Command: Mono (Exit 0)"))
    #expect(
      menu.warnings.contains("System Mono Audio is on; automatic switching is paused.")
        == (preference == .on))
    let state =
      preference == .on ? "On" : preference == .off ? "Off" : "Unavailable (treated as off)"
    #expect(menu.details.contains("Accessibility Mono Audio: \(state)"))
    #expect(!menu.details.contains { $0.hasPrefix("System Mono Audio") })
    #expect(menu.details.contains("Current Audio: Stereo (OSStatus 0)"))
  }
}

@Test func visibleApplicationNameIsConsistentInWarningsAndStartup() {
  var snapshot = menuSnapshot()
  snapshot.detection = .off
  #expect(presentation(snapshot).warnings.contains { $0.contains("use MonoPods.") })
  #expect(
    presentation(nil, status: "Waiting for the command owner").summary == "Waiting for MonoPods…")
  #expect(LoginText.notInstalled == "Move MonoPods to Applications to launch at login.")
  #expect(NoticePresenter.message(.commandFailed).contains("quit and reopen MonoPods."))
  #expect(NoticePresenter.message(.detectionDisabled).contains("use MonoPods."))
  #expect(NoticePresenter.message(.previousCrash).hasPrefix("MonoPods "))
  #expect(NoticePresenter.message(.detectionQuitReminder).contains("using MonoPods,"))
}

@Test func everyNoticeIsPlainEnglish() {
  let notices: [Notice] = [
    .detectionDisabled, .detectionQuitReminder, .previousCrash, .persistenceFailed,
    .recoveryBlocked, .stereoNotRestored, .commandFailed,
  ]
  for notice in notices {
    let message = NoticePresenter.message(notice)
    let ascii = message.unicodeScalars.allSatisfy { $0.isASCII }
    #expect(ascii, "\(notice)")
    for word in ["è ", "riapri", "ripartita", "confermato", " il ", " non "] {
      #expect(!message.lowercased().contains(word), "\(notice): \(word)")
    }
  }
}
private func knownModel(_ id: Int) -> AirPodsModel? {
  AirPodsModel.model(productID: id)
}

private let maxWarning = "AirPods Max have no ear detection, so MonoPods cannot switch."

@Test func detailsNameTheRecognisedModelRightAfterTheAudioOutput() throws {
  let details = presentation(model: knownModel(0x2014)).details
  let output = try #require(details.firstIndex(of: "Audio Output: AirPods Pro"))
  #expect(details[output + 1] == "Model: AirPods Pro 2")
  #expect(details.count == 8)
}

@Test func unrecognisedProductIDIsReportedAndStillWorks() {
  let menu = presentation(model: nil)
  #expect(menu.details.contains("Model: Not Recognized"))
  #expect(menu.summary == "One AirPod in Use")
  #expect(menu.symbol == "airpodspro")
  #expect(menu.warnings.isEmpty)
}

@Test func missingOutputShowsNoModelEvenIfOneIsStale() {
  for route in ["", "No Bluetooth output"] {
    for model in [nil, knownModel(0x2014), knownModel(0x200A)] {
      let menu = presentation(route: route, model: model)
      #expect(menu.details.contains("Model: None"))
      #expect(menu.summary == "No AirPods Audio Output")
      #expect(!menu.warnings.contains(maxWarning))
    }
  }
}

@Test func airPodsMaxAreFlaggedAsUnsupported() {
  for id in [0x200A, 0x201F, 0x202D] {
    let model = knownModel(id)
    let menu = presentation(route: "Headphones", model: model)
    #expect(menu.summary == "AirPods Max Not Supported")
    #expect(menu.symbol == "airpodsmax")
    #expect(menu.warnings == [maxWarning])
    #expect(menu.details.contains("Model: \(model?.name ?? "")"))
  }
}

@Test func earDetectionModelsAreNeverFlaggedAsMax() {
  for model in AirPodsModel.known where model.earDetection {
    let menu = presentation(model: model)
    #expect(menu.summary == "One AirPod in Use")
    #expect(!menu.warnings.contains(maxWarning))
  }
}

@Test func existingAttentionStatesStayAboveAirPodsMax() {
  let max = knownModel(0x200A)
  var blocked = menuSnapshot()
  blocked.blocked = true
  var failed = menuSnapshot()
  failed.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 7)
  var detectionOff = menuSnapshot()
  detectionOff.detection = .off
  var unavailable = menuSnapshot()
  unavailable.healthy = false
  let cases: [(EngineSnapshot, String, String)] = [
    (blocked, "Observing", "Automation Blocked"),
    (failed, "Observing", "Audio Change Failed"),
    (menuSnapshot(), "Something unexpected", "Needs Attention"),
    (detectionOff, "Observing", "Automatic Ear Detection Off"),
    (unavailable, "Observing", "Ear Detection Unavailable"),
  ]
  for (snapshot, status, summary) in cases {
    let menu = presentation(snapshot, status: status, model: max)
    #expect(menu.summary == summary)
    #expect(menu.warnings.contains(maxWarning))
  }
}

@Test func airPodsMaxWinOverStartupAndEarCountStatuses() {
  let max = knownModel(0x200A)
  var waiting = menuSnapshot()
  waiting.count = nil
  for snapshot in [menuSnapshot(), waiting] {
    #expect(presentation(snapshot, model: max).summary == "AirPods Max Not Supported")
  }
  #expect(presentation(nil, status: "Starting", model: max).summary == "AirPods Max Not Supported")
}
