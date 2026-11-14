import AppKit
import Foundation
import Sparkle
import Testing

@testable import MonoPods

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

private func strings(_ language: String) throws -> Bundle {
  try #require(
    Bundle(
      path: repositoryRoot.appendingPathComponent("Resources/Localization/\(language).lproj").path))
}

/// Records what the driver would show and open; no window is ever put on screen.
@MainActor private final class Recorder {
  var presented: [(window: NSWindow, activate: Bool)] = []
  var opened: [URL] = []
}

@MainActor private func makeDriver(_ recorder: Recorder, strings: Bundle) -> AppleStyleUpdateDriver
{
  AppleStyleUpdateDriver(
    appName: "MonoPods", currentVersion: "1.1.0", strings: strings,
    present: { recorder.presented.append((window: $0, activate: $1)) },
    openURL: { recorder.opened.append($0) })
}

@MainActor private func click(_ button: NSButton) {
  guard let action = button.action else { return }
  NSApplication.shared.sendAction(action, to: button.target, from: button)
}

@MainActor private func button(_ title: String, of driver: AppleStyleUpdateDriver) throws
  -> NSButton
{
  try #require(driver.alert?.buttons.first { $0.title == title })
}

@MainActor private func bar(of driver: AppleStyleUpdateDriver) throws -> NSProgressIndicator {
  try #require(driver.alert?.accessoryView as? NSProgressIndicator)
}

/// Counts calls of the callbacks handed to the driver.
@MainActor private final class Calls {
  var count = 0
  var choices: [SPUUserUpdateChoice] = []
  func callback() -> () -> Void { { self.count += 1 } }
  func reply() -> (SPUUserUpdateChoice) -> Void { { self.choices.append($0) } }
}

private func notFound(reason: Int?) -> NSError {
  var info: [String: Any] = [
    NSLocalizedDescriptionKey: "Reason \(reason.map(String.init) ?? "none")"
  ]
  if let reason { info[SPUNoUpdateFoundReasonKey] = NSNumber(value: reason) }
  return NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: info)
}

// MARK: - Examples

@MainActor @Test func anUpdateShowsBothVersionsInstallAndLater() throws {
  let recorder = Recorder()
  let driver = makeDriver(recorder, strings: try strings("en"))
  let calls = Calls()
  driver.presentUpdate(
    version: "1.1.1", informationOnly: false, infoURL: nil, userInitiated: true,
    reply: calls.reply())
  let alert = try #require(driver.alert)
  #expect(alert.messageText == "MonoPods 1.1.1 is available (you have 1.1.0).")
  #expect(alert.buttons.map(\.title) == ["Install and Relaunch", "Later"])
  #expect(alert.buttons[0].keyEquivalent == "\r")
  #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
  #expect(recorder.presented.count == 1 && recorder.presented[0].window === alert.window)
  #expect(calls.choices.isEmpty)
}

@MainActor @Test func installRepliesOnceAndClosesTheAlert() throws {
  let driver = makeDriver(Recorder(), strings: try strings("en"))
  let calls = Calls()
  driver.presentUpdate(
    version: "1.1.1", informationOnly: false, infoURL: nil, userInitiated: true,
    reply: calls.reply())
  let install = try button("Install and Relaunch", of: driver)
  let later = try button("Later", of: driver)
  click(install)
  #expect(calls.choices == [.install])
  #expect(driver.alert == nil)
  click(install)
  click(later)
  #expect(calls.choices == [.install])
}

@MainActor @Test func laterRepliesDismiss() throws {
  let driver = makeDriver(Recorder(), strings: try strings("en"))
  let calls = Calls()
  driver.presentUpdate(
    version: "1.1.1", informationOnly: false, infoURL: nil, userInitiated: false,
    reply: calls.reply())
  click(try button("Later", of: driver))
  #expect(calls.choices == [.dismiss] && driver.alert == nil)
}

@MainActor @Test func anInformationOnlyUpdateNeverInstallsAndOpensItsPage() throws {
  let page = try #require(URL(string: "https://example.invalid/release"))
  for infoURL in [page, nil] {
    let recorder = Recorder()
    let driver = makeDriver(recorder, strings: try strings("en"))
    let calls = Calls()
    driver.presentUpdate(
      version: "1.1.1", informationOnly: true, infoURL: infoURL, userInitiated: true,
      reply: calls.reply())
    #expect(driver.alert?.buttons.map(\.title) == ["More Info\u{2026}", "Later"])
    click(try button("More Info\u{2026}", of: driver))
    #expect(recorder.opened == (infoURL.map { [$0] } ?? []))
    #expect(calls.choices == [.dismiss] && driver.alert == nil)
  }
}

@MainActor @Test func onlyAUserCheckActivatesTheApp() throws {
  for userInitiated in [false, true] {
    let recorder = Recorder()
    let driver = makeDriver(recorder, strings: try strings("en"))
    driver.presentUpdate(
      version: "1.1.1", informationOnly: false, infoURL: nil, userInitiated: userInitiated,
      reply: { _ in })
    #expect(recorder.presented.map(\.activate) == [userInitiated])
  }
  let recorder = Recorder()
  let driver = makeDriver(recorder, strings: try strings("en"))
  driver.showUserInitiatedUpdateCheck(cancellation: {})
  #expect(recorder.presented.map(\.activate) == [true])
}

@MainActor @Test func theCheckingAlertCancelsOnce() throws {
  let driver = makeDriver(Recorder(), strings: try strings("en"))
  let calls = Calls()
  driver.showUserInitiatedUpdateCheck(cancellation: calls.callback())
  #expect(driver.alert?.messageText == "Checking for Updates\u{2026}")
  #expect(try bar(of: driver).isIndeterminate)
  let cancel = try button("Cancel", of: driver)
  #expect(cancel.keyEquivalent == "\u{1b}")
  click(cancel)
  click(cancel)
  #expect(calls.count == 1 && driver.alert == nil)
}

@MainActor @Test func noUpdateReasonsSayUpToDateOrShowTheError() throws {
  for reason in [0, 1, 2, nil] as [Int?] {
    let driver = makeDriver(Recorder(), strings: try strings("en"))
    let calls = Calls()
    driver.showUpdateNotFoundWithError(notFound(reason: reason), acknowledgement: calls.callback())
    #expect(driver.alert?.messageText == "MonoPods is up to date.")
    let ok = try button("OK", of: driver)
    click(ok)
    click(ok)
    #expect(calls.count == 1 && driver.alert == nil)
  }
  for reason in [3, 4, 5, 99, -1] {
    let driver = makeDriver(Recorder(), strings: try strings("en"))
    let calls = Calls()
    driver.showUpdateNotFoundWithError(notFound(reason: reason), acknowledgement: calls.callback())
    #expect(driver.alert?.messageText == "Reason \(reason)")
    click(try button("OK", of: driver))
    #expect(calls.count == 1)
  }
}

@MainActor @Test func anUpdaterErrorAcknowledgesOnce() throws {
  let driver = makeDriver(Recorder(), strings: try strings("en"))
  let calls = Calls()
  let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No network."])
  driver.showUpdaterError(error, acknowledgement: calls.callback())
  #expect(driver.alert?.messageText == "The update could not be completed.")
  #expect(driver.alert?.informativeText == "No network.")
  let ok = try button("OK", of: driver)
  click(ok)
  click(ok)
  #expect(calls.count == 1 && driver.alert == nil)
}

@MainActor @Test func downloadProgressFollowsTheBytesWithoutOverflow() throws {
  let english = try strings("en")
  let unknown = makeDriver(Recorder(), strings: english)
  unknown.showDownloadInitiated(cancellation: {})
  #expect(unknown.alert?.messageText == "Downloading Update\u{2026}")
  unknown.showDownloadDidReceiveExpectedContentLength(0)
  unknown.showDownloadDidReceiveData(ofLength: 10)
  #expect(try bar(of: unknown).isIndeterminate)

  let known = makeDriver(Recorder(), strings: english)
  known.showDownloadInitiated(cancellation: {})
  known.showDownloadDidReceiveExpectedContentLength(100)
  known.showDownloadDidReceiveData(ofLength: 50)
  #expect(try !bar(of: known).isIndeterminate && bar(of: known).doubleValue == 0.5)
  // A second length does not reset the bytes received.
  known.showDownloadDidReceiveExpectedContentLength(200)
  #expect(try bar(of: known).doubleValue == 0.25)
  known.showDownloadDidReceiveData(ofLength: 500)
  #expect(try bar(of: known).doubleValue == 1)

  let huge = makeDriver(Recorder(), strings: english)
  huge.showDownloadInitiated(cancellation: {})
  huge.showDownloadDidReceiveExpectedContentLength(1000)
  huge.showDownloadDidReceiveData(ofLength: UInt64.max)
  huge.showDownloadDidReceiveData(ofLength: UInt64.max)
  #expect(try bar(of: huge).doubleValue == 1)
}

@MainActor @Test func theDownloadCancelsOnceAndNotAfterExtractionStarts() throws {
  let english = try strings("en")
  let driver = makeDriver(Recorder(), strings: english)
  let calls = Calls()
  driver.showDownloadInitiated(cancellation: calls.callback())
  let cancel = try button("Cancel", of: driver)
  click(cancel)
  click(cancel)
  #expect(calls.count == 1 && driver.alert == nil)

  let extracting = makeDriver(Recorder(), strings: english)
  let late = Calls()
  extracting.showDownloadInitiated(cancellation: late.callback())
  extracting.showDownloadDidStartExtractingUpdate()
  #expect(extracting.alert?.messageText == "Preparing Update\u{2026}")
  #expect(try bar(of: extracting).isIndeterminate)
  let disabled = try button("Cancel", of: extracting)
  #expect(!disabled.isEnabled)
  click(disabled)
  #expect(late.count == 0 && extracting.alert != nil)
}

@MainActor @Test func extractionProgressIsClampedOrIndeterminate() throws {
  let driver = makeDriver(Recorder(), strings: try strings("en"))
  driver.showDownloadDidStartExtractingUpdate()
  for (progress, expected) in [(-1.0, 0.0), (0.3, 0.3), (2.0, 1.0)] {
    driver.showExtractionReceivedProgress(progress)
    #expect(try !bar(of: driver).isIndeterminate && bar(of: driver).doubleValue == expected)
  }
  for progress in [Double.nan, .infinity, -.infinity] {
    driver.showExtractionReceivedProgress(progress)
    #expect(try bar(of: driver).isIndeterminate)
  }
}

@MainActor @Test func readyToInstallRepliesInstallOrDismiss() throws {
  for (title, choice) in [
    ("Install and Relaunch", SPUUserUpdateChoice.install), ("Later", .dismiss),
  ] {
    let driver = makeDriver(Recorder(), strings: try strings("en"))
    let calls = Calls()
    driver.showReady(toInstallAndRelaunch: calls.reply())
    #expect(driver.alert?.messageText == "MonoPods is ready to install.")
    let pressed = try button(title, of: driver)
    click(pressed)
    click(pressed)
    #expect(calls.choices == [choice] && driver.alert == nil)
  }
}

@MainActor @Test func installingRetriesOnEveryClickOnlyWhileTheAppRuns() throws {
  let driver = makeDriver(Recorder(), strings: try strings("en"))
  let calls = Calls()
  driver.showInstallingUpdate(
    withApplicationTerminated: false, retryTerminatingApplication: calls.callback())
  #expect(driver.alert?.messageText == "Installing Update\u{2026}")
  #expect(try bar(of: driver).isIndeterminate)
  let retry = try button("Install and Relaunch", of: driver)
  for _ in 0..<3 { click(retry) }
  #expect(calls.count == 3 && driver.alert != nil)

  let terminated = makeDriver(Recorder(), strings: try strings("en"))
  let none = Calls()
  terminated.showInstallingUpdate(
    withApplicationTerminated: true, retryTerminatingApplication: none.callback())
  for pressed in terminated.alert?.buttons ?? [] { click(pressed) }
  #expect(none.count == 0)
}

@MainActor @Test func installedAcknowledgesAtOnceWithoutAWindow() throws {
  let recorder = Recorder()
  let driver = makeDriver(recorder, strings: try strings("en"))
  driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
  let calls = Calls()
  driver.showUpdateInstalledAndRelaunched(true, acknowledgement: calls.callback())
  #expect(calls.count == 1 && driver.alert == nil && recorder.presented.count == 1)
}

@MainActor @Test func permissionIsAnsweredWithChecksOffAndNoWindow() throws {
  let recorder = Recorder()
  let driver = makeDriver(recorder, strings: try strings("en"))
  var responses: [SUUpdatePermissionResponse] = []
  driver.show(SPUUpdatePermissionRequest(systemProfile: [])) { responses.append($0) }
  #expect(responses.count == 1)
  #expect(responses.first?.automaticUpdateChecks == false)
  #expect(responses.first?.sendSystemProfile == false)
  #expect(recorder.presented.isEmpty && driver.alert == nil)
}

@MainActor @Test func dismissingClosesAndDiscardsEveryCallback() throws {
  let driver = makeDriver(Recorder(), strings: try strings("en"))
  let calls = Calls()
  driver.presentUpdate(
    version: "1.1.1", informationOnly: false, infoURL: nil, userInitiated: true,
    reply: calls.reply())
  let install = try button("Install and Relaunch", of: driver)
  driver.dismissUpdateInstallation()
  #expect(driver.alert == nil)
  click(install)
  #expect(calls.choices.isEmpty)
}

@MainActor @Test func focusPresentsTheCurrentAlertAgain() throws {
  let recorder = Recorder()
  let driver = makeDriver(recorder, strings: try strings("en"))
  driver.showUpdateInFocus()
  #expect(recorder.presented.isEmpty)
  driver.showDownloadInitiated(cancellation: {})
  driver.showUpdateInFocus()
  #expect(recorder.presented.map(\.activate) == [false, true])
  #expect(recorder.presented[1].window === driver.alert?.window)
}

@MainActor @Test func theItalianTableGivesTheDictatedTexts() throws {
  let italian = try strings("it")
  let driver = makeDriver(Recorder(), strings: italian)
  driver.presentUpdate(
    version: "1.1.1", informationOnly: false, infoURL: nil, userInitiated: true, reply: { _ in })
  #expect(driver.alert?.messageText == "È disponibile MonoPods 1.1.1 (hai la 1.1.0).")
  #expect(driver.alert?.buttons.map(\.title) == ["Installa e riavvia", "Più tardi"])
  driver.presentNotFound(reason: 1, description: "", acknowledgement: {})
  #expect(driver.alert?.messageText == "MonoPods è aggiornata.")
}

// MARK: - Random sequences

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
}

/// Every callback handed to the driver, with how often it was called.
@MainActor private final class Ledger {
  var counts: [Int] = []
  var retries: Set<Int> = []
  var informationOnly: Set<Int> = []
  var choices: [(id: Int, choice: SPUUserUpdateChoice)] = []
  var frozen: [Int: Int] = [:]

  func callback(retry: Bool = false) -> () -> Void {
    let id = counts.count
    counts.append(0)
    if retry { retries.insert(id) }
    return { self.counts[id] += 1 }
  }
  func reply(informationOnly: Bool) -> (SPUUserUpdateChoice) -> Void {
    let id = counts.count
    counts.append(0)
    if informationOnly { self.informationOnly.insert(id) }
    return { choice in
      self.counts[id] += 1
      self.choices.append((id: id, choice: choice))
    }
  }
  /// After a dismissal no callback handed out before it may be called again.
  func freeze() {
    for id in counts.indices { frozen[id] = counts[id] }
  }
}

@MainActor @Test func randomSequencesKeepTheDriverInvariants() throws {
  let english = try strings("en")
  let page = try #require(URL(string: "https://example.invalid/release"))
  let lengths: [UInt64] = [0, 1, 100, 4096, UInt64.max]
  let progress: [Double] = [-1, 0, 0.5, 1, 2, .nan, .infinity, -.infinity]
  let reasons: [Int?] = [nil, 0, 1, 2, 3, 4, 5, 99, -1]
  var generator = SplitMix64(state: 0x6472_6976_6572_0001)
  for _ in 0..<300 {
    let recorder = Recorder()
    let driver = makeDriver(recorder, strings: english)
    let ledger = Ledger()
    var seen: [NSButton] = []
    for _ in 0..<(1 + generator.below(40)) {
      switch generator.below(18) {
      case 0:
        driver.show(SPUUpdatePermissionRequest(systemProfile: [])) { _ in }
      case 1: driver.showUserInitiatedUpdateCheck(cancellation: ledger.callback())
      case 2:
        let informationOnly = generator.below(2) == 0
        driver.presentUpdate(
          version: "1.1.1", informationOnly: informationOnly,
          infoURL: generator.below(2) == 0 ? page : nil, userInitiated: generator.below(2) == 0,
          reply: ledger.reply(informationOnly: informationOnly))
      case 3: driver.showUpdateReleaseNotesFailedToDownloadWithError(notFound(reason: nil))
      case 4:
        driver.showUpdateNotFoundWithError(
          notFound(reason: reasons[generator.below(reasons.count)]),
          acknowledgement: ledger.callback())
      case 5: driver.showUpdaterError(notFound(reason: nil), acknowledgement: ledger.callback())
      case 6: driver.showDownloadInitiated(cancellation: ledger.callback())
      case 7:
        driver.showDownloadDidReceiveExpectedContentLength(lengths[generator.below(lengths.count)])
      case 8: driver.showDownloadDidReceiveData(ofLength: lengths[generator.below(lengths.count)])
      case 9: driver.showDownloadDidStartExtractingUpdate()
      case 10: driver.showExtractionReceivedProgress(progress[generator.below(progress.count)])
      case 11: driver.showReady(toInstallAndRelaunch: ledger.reply(informationOnly: false))
      case 12:
        driver.showInstallingUpdate(
          withApplicationTerminated: generator.below(2) == 0,
          retryTerminatingApplication: ledger.callback(retry: true))
      case 13:
        driver.showUpdateInstalledAndRelaunched(
          generator.below(2) == 0, acknowledgement: ledger.callback())
      case 14: driver.showUpdateInFocus()
      case 15:
        driver.dismissUpdateInstallation()
        ledger.freeze()
        #expect(driver.alert == nil)  // D-I3
      case 16:
        if let buttons = driver.alert?.buttons, !buttons.isEmpty {
          click(buttons[generator.below(buttons.count)])
        }
      default:
        if !seen.isEmpty { click(seen[generator.below(seen.count)]) }
      }
      seen.append(contentsOf: driver.alert?.buttons ?? [])
      if let alert = driver.alert {  // D-I1
        #expect(recorder.presented.last?.window === alert.window)
      }
      for (id, count) in ledger.counts.enumerated() where !ledger.retries.contains(id) {
        #expect(count <= 1)  // D-I2
      }
      for (id, count) in ledger.frozen {
        #expect(ledger.counts[id] == count)  // D-I3
      }
      #expect(
        !ledger.choices.contains { $0.choice == .install && ledger.informationOnly.contains($0.id) }
      )  // D-I4
      if let bar = driver.alert?.accessoryView as? NSProgressIndicator {  // D-I5
        #expect(bar.isIndeterminate || (0...1).contains(bar.doubleValue))
      }
      #expect(!ledger.choices.contains { $0.choice == .skip })  // D-I6
    }
  }
}
