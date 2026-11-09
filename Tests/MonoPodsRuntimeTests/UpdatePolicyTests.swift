import Foundation
import Testing

@testable import MonoPodsRuntime

private let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()
private let feed = "https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml"
private let product = "io.github.bernalli.monopods"
private var validInfo: [String: Any] { ["SUFeedURL": feed, "SUPublicEDKey": key] }

@Test func policyAllowsOnlyTheProductChannelOfTheProductOwner() {
  #expect(UpdatePolicy.allows(identifier: product, role: .product, info: validInfo))
  #expect(!UpdatePolicy.allows(identifier: nil, role: .product, info: validInfo))
  #expect(!UpdatePolicy.allows(identifier: product + ".test.x", role: .product, info: validInfo))
  #expect(!UpdatePolicy.allows(identifier: product, role: .isolatedHarness, info: validInfo))
  #expect(!UpdatePolicy.allows(identifier: product, role: .product, info: nil))
  #expect(!UpdatePolicy.allows(identifier: product, role: .product, info: [:]))
  var automatic = validInfo
  automatic["SUEnableAutomaticChecks"] = false
  #expect(!UpdatePolicy.allows(identifier: product, role: .product, info: automatic))
  for feedValue: Any in [
    feed.replacingOccurrences(of: "https", with: "http"), feed + "/", "file:///tmp/appcast.xml",
    "", 1, true, ["a": 1],
  ] {
    var info = validInfo
    info["SUFeedURL"] = feedValue
    #expect(!UpdatePolicy.allows(identifier: product, role: .product, info: info))
  }
  for keyValue: Any in [
    Data(count: 31).base64EncodedString(), Data(count: 33).base64EncodedString(), "", " " + key,
    key.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + "!",
    String(key.dropLast()), 1, false, ["a": 1],
  ] {
    var info = validInfo
    info["SUPublicEDKey"] = keyValue
    #expect(!UpdatePolicy.allows(identifier: product, role: .product, info: info))
  }
  var missingKey = validInfo
  missingKey["SUPublicEDKey"] = nil
  #expect(!UpdatePolicy.allows(identifier: product, role: .product, info: missingKey))
  var missingFeed = validInfo
  missingFeed["SUFeedURL"] = nil
  #expect(!UpdatePolicy.allows(identifier: product, role: .product, info: missingFeed))
}

@Test func updateGateSignalsExactlyOnceAndOnlyWhenAllowed() {
  var gate = UpdateGate()
  let first = gate.ownerAcquired(allowed: true)
  let second = gate.ownerAcquired(allowed: true)
  let refusedLater = gate.ownerAcquired(allowed: false)
  #expect(first && !second && !refusedLater)
  var refused = UpdateGate()
  let answers = (0..<3).map { _ in refused.ownerAcquired(allowed: false) }
  #expect(answers == [false, false, false])
  let allowedAfter = refused.ownerAcquired(allowed: true)
  #expect(allowedAfter)
}

@Test func menuStateEnablesTheCheckOnlyWhenAvailableAndAccepted() {
  let idle = UpdateMenuState(available: true, canCheck: true)
  #expect(idle.showsItems && idle.checkEnabled)
  let busy = UpdateMenuState(available: true, canCheck: false)
  #expect(busy.showsItems && !busy.checkEnabled)
  let absent = UpdateMenuState(available: false, canCheck: true)
  #expect(!absent.showsItems && !absent.checkEnabled)
}

@Test func theOnlyUpdateCommandIsCheckForUpdates() {
  #expect(UpdateText.check == "Check for Updates\u{2026}")
  #expect(!UpdateText.check.contains("..."))
}

// MARK: - Manual checks only, with a fake updater

/// Sparkle's user defaults keys, as an older build of the app left them.
private let checksKey = "SUEnableAutomaticChecks"
private let downloadsKey = "SUAutomaticallyUpdate"
private let oldConsentKey = "MonoPodsUpdateConsentAnswered"

/// Models Sparkle 2.10.1 with no SUAllowsAutomaticUpdates: its download getter is
/// filtered and its download setter does nothing when checks are off. Raw writes
/// and persistence can fail independently of the effective getters.
@MainActor private final class FakePort: UpdaterPort {
  var values: [String: Any] = [:]
  var events: [String] = []
  var canCheckForUpdates = true
  var startSucceeds = true
  var syncSucceeds = true
  var checksGetterOverride: Bool?
  var downloadsGetterOverride: Bool?
  var lostWrites: Set<String> = []
  var onWrite: (() -> Void)?
  var starts = 0
  var checks = 0
  var rawAutomaticChecks: Any? { values[checksKey] }
  var rawAutomaticDownloads: Any? { values[downloadsKey] }
  var automaticChecks: Bool {
    checksGetterOverride ?? ((values[checksKey] as? Bool) ?? false)
  }
  var automaticDownloads: Bool {
    downloadsGetterOverride ?? (automaticChecks && ((values[downloadsKey] as? Bool) ?? false))
  }
  func switchOffAutomatic() {
    for key in [downloadsKey, checksKey] {
      events.append("raw \(key)=false")
      if !lostWrites.contains(key) { values[key] = false }
      onWrite?()
    }
    for key in [downloadsKey, checksKey] {
      events.append("setter \(key)=false")
      if (key != downloadsKey || automaticChecks) && !lostWrites.contains(key) {
        values[key] = false
      }
      onWrite?()
    }
  }
  func synchronizeAutomaticPreferences() -> Bool {
    events.append("sync")
    return syncSucceeds
  }
  func startUpdater() -> Bool {
    starts += 1
    events.append("start")
    return startSucceeds
  }
  func checkForUpdates() {
    checks += 1
    events.append("check")
  }
}

@MainActor private func started(_ port: FakePort) -> UpdateCoordinator {
  let coordinator = UpdateCoordinator(port: port)
  coordinator.start()
  return coordinator
}

private let switchOff = [
  "raw SUAutomaticallyUpdate=false", "raw SUEnableAutomaticChecks=false",
  "setter SUAutomaticallyUpdate=false", "setter SUEnableAutomaticChecks=false", "sync",
]

@MainActor @Test func firstLaunchAsksNothingSwitchesBothSettingsOffAndStartsTheUpdater() {
  let port = FakePort()
  let subject = started(port)
  #expect(port.events == switchOff + ["start"])
  #expect(!port.events.contains { $0.hasSuffix("=true") })
  #expect(port.starts == 1 && port.checks == 0)
  #expect(!port.automaticChecks && !port.automaticDownloads)
  #expect(subject.state.available && subject.state.canCheck && subject.state.checkEnabled)
}

@MainActor @Test func startingTwiceStartsTheUpdaterOnce() {
  let port = FakePort()
  let subject = started(port)
  subject.start()
  #expect(port.starts == 1)
}

@MainActor @Test func settingsLeftOnByAnOlderBuildAreSwitchedOffBeforeTheStart() {
  for (checks, downloads) in [(true, true), (true, false), (false, true)] {
    let port = FakePort()
    port.values = [oldConsentKey: true, checksKey: checks, downloadsKey: downloads]
    let subject = started(port)
    #expect(port.events == switchOff + ["start"])
    #expect(!port.automaticChecks && !port.automaticDownloads)
    #expect(subject.state.checkEnabled)
    #expect(!subject.mayPerformCheck(userInitiated: false))
  }
}

@MainActor @Test func anExternalSwitchOnIsSwitchedOffAgain() {
  for (checks, downloads) in [(true, true), (true, false), (false, true)] {
    let port = FakePort()
    let subject = started(port)
    port.events.removeAll()
    port.values[checksKey] = checks
    port.values[downloadsKey] = downloads
    subject.settingsChanged()
    #expect(port.events == switchOff)
    #expect(!port.automaticChecks && !port.automaticDownloads)
    #expect(subject.state.checkEnabled)
    #expect(!subject.mayPerformCheck(userInitiated: false))
  }
}

@MainActor @Test func aSettingStillOffNeedsNoWrite() {
  let port = FakePort()
  let subject = started(port)
  port.events.removeAll()
  subject.settingsChanged()
  #expect(port.events.isEmpty)
  #expect(subject.state.checkEnabled)
}

@MainActor @Test func noCheckIsAllowedWhileTheSettingsAreBeingWritten() {
  let port = FakePort()
  let subject = started(port)
  subject.checkForUpdates()
  var observed: [(Bool, Bool)] = []
  port.onWrite = {
    // Synchronous observation from inside a setter, as KVO delivers it.
    subject.settingsChanged()
    subject.canCheckChanged()
    #expect(!subject.state.checkEnabled)
    subject.checkForUpdates()
    observed.append(
      (subject.mayPerformCheck(userInitiated: false), subject.mayPerformCheck(userInitiated: true)))
  }
  port.values[checksKey] = true
  subject.settingsChanged()
  #expect(observed.count == 4)
  #expect(observed.allSatisfy { !$0.0 && !$0.1 })
  #expect(port.checks == 1)
  #expect(subject.state.checkEnabled)
}

@MainActor @Test func scheduledChecksAreAlwaysRefused() {
  let port = FakePort()
  let subject = started(port)
  #expect(!subject.mayPerformCheck(userInitiated: false))
  subject.checkForUpdates()
  #expect(!subject.mayPerformCheck(userInitiated: false))
  // Even with both settings on and not yet observed, a scheduled check does not pass.
  port.values[checksKey] = true
  port.values[downloadsKey] = true
  #expect(!subject.mayPerformCheck(userInitiated: false))
  subject.settingsChanged()
  #expect(!subject.mayPerformCheck(userInitiated: false))
}

@MainActor @Test func theMenuCommandAllowsExactlyOneUserCheck() {
  let port = FakePort()
  let subject = started(port)
  #expect(!subject.mayPerformCheck(userInitiated: true))
  subject.checkForUpdates()
  #expect(port.checks == 1)
  #expect(subject.mayPerformCheck(userInitiated: true))
  #expect(!subject.mayPerformCheck(userInitiated: true))
  subject.checkForUpdates()
  #expect(port.checks == 2)
  #expect(subject.mayPerformCheck(userInitiated: true))
  #expect(!subject.mayPerformCheck(userInitiated: true))
}

@MainActor @Test func theMenuCommandWaitsUntilSparkleAcceptsACheck() {
  let port = FakePort()
  port.canCheckForUpdates = false
  let subject = started(port)
  #expect(!subject.state.checkEnabled)
  subject.checkForUpdates()
  #expect(port.checks == 0 && !subject.mayPerformCheck(userInitiated: true))
  port.canCheckForUpdates = true
  subject.canCheckChanged()
  #expect(subject.state.checkEnabled)
  port.canCheckForUpdates = false
  subject.canCheckChanged()
  #expect(!subject.state.checkEnabled)
}

@MainActor @Test func aFailedWriteKeepsTheGateClosedAndTheMenuDisabled() {
  for lost in [[checksKey], [downloadsKey], [checksKey, downloadsKey]] {
    let port = FakePort()
    port.values = [checksKey: true, downloadsKey: true]
    port.lostWrites = Set(lost)
    let subject = started(port)
    #expect(lost.contains { (port.values[$0] as? Bool) == true })
    #expect(!subject.state.canCheck && !subject.state.checkEnabled)
    subject.checkForUpdates()
    #expect(port.checks == 0)
    #expect(!subject.mayPerformCheck(userInitiated: true))
    #expect(!subject.mayPerformCheck(userInitiated: false))
  }
}

@MainActor @Test func theGateReopensOnlyWhenBothSettingsAreSeenOff() {
  let port = FakePort()
  port.values = [checksKey: true, downloadsKey: true]
  port.lostWrites = [checksKey, downloadsKey]
  let subject = started(port)
  #expect(!subject.state.checkEnabled)
  port.lostWrites = []
  port.values = [checksKey: false, downloadsKey: false]
  subject.settingsChanged()
  #expect(subject.state.checkEnabled)
  subject.checkForUpdates()
  #expect(port.checks == 1 && subject.mayPerformCheck(userInitiated: true))
}

@MainActor @Test func aFailedStartKeepsTheMenuDisabled() {
  let port = FakePort()
  port.startSucceeds = false
  let subject = started(port)
  #expect(subject.state.available && !subject.state.checkEnabled)
  subject.checkForUpdates()
  #expect(port.checks == 0)
  #expect(!subject.mayPerformCheck(userInitiated: true))
}

@MainActor @Test func filteredDownloadGetterCannotHideAnOldBuildsRawPreference() {
  let port = FakePort()
  port.values = [checksKey: false, downloadsKey: true]
  #expect(!port.automaticDownloads)
  let subject = started(port)
  #expect(port.events == switchOff + ["start"])
  #expect((port.values[checksKey] as? Bool) == false)
  #expect((port.values[downloadsKey] as? Bool) == false)
  #expect(subject.state.checkEnabled)
}

@MainActor @Test func lyingGettersCannotOpenTheGateWhileRawPreferencesRemainOn() {
  for key in [checksKey, downloadsKey] {
    let port = FakePort()
    port.values = [checksKey: false, downloadsKey: false]
    port.values[key] = true
    port.checksGetterOverride = false
    port.downloadsGetterOverride = false
    port.lostWrites = [key]
    let subject = started(port)
    #expect(!subject.state.checkEnabled)
    subject.checkForUpdates()
    #expect(port.checks == 0 && !subject.mayPerformCheck(userInitiated: true))
    port.lostWrites = []
    subject.settingsChanged()
    #expect((port.values[key] as? Bool) == false)
    #expect(subject.state.checkEnabled)
  }
}

@MainActor @Test func failedSynchronizationCannotBeBypassedByObservingFalseValues() {
  let port = FakePort()
  port.syncSucceeds = false
  let subject = started(port)
  #expect(!subject.state.checkEnabled)
  subject.settingsChanged()
  subject.canCheckChanged()
  subject.checkForUpdates()
  #expect(!subject.state.checkEnabled && port.checks == 0)
  #expect(!subject.mayPerformCheck(userInitiated: true))
  port.syncSucceeds = true
  subject.settingsChanged()
  #expect(subject.state.checkEnabled)
}

@MainActor @Test func missingOrMalformedRawPreferencesAreRewrittenAndMustReadBackAsBooleans() {
  let malformed: [Any?] = [
    nil, 0, 1, NSNumber(value: 0), NSNumber(value: 1),
    0.0, "false", "0", NSNull(), [], ["value": false],
  ]
  for key in [checksKey, downloadsKey] {
    for value in malformed {
      for losesWrite in [false, true] {
        let port = FakePort()
        port.values = [checksKey: false, downloadsKey: false]
        port.values[key] = value
        port.checksGetterOverride = false
        port.downloadsGetterOverride = false
        port.lostWrites = losesWrite ? [key] : []
        let subject = started(port)
        #expect(subject.state.checkEnabled == !losesWrite)
        subject.checkForUpdates()
        #expect(port.checks == (losesWrite ? 0 : 1))
        #expect(subject.mayPerformCheck(userInitiated: true) == !losesWrite)
      }
    }
  }
}

@MainActor @Test func trueEffectiveGetterKeepsGateClosedEvenWithFalseRawPreferences() {
  for checks in [false, true] {
    let port = FakePort()
    port.checksGetterOverride = checks
    port.downloadsGetterOverride = !checks
    let subject = started(port)
    #expect(!subject.state.checkEnabled)
    subject.checkForUpdates()
    #expect(port.checks == 0 && !subject.mayPerformCheck(userInitiated: true))
  }
}

@MainActor @Test func unobservedRawChangesBlockMenuAndAnAlreadyPendingManualCheck() {
  let port = FakePort()
  port.checksGetterOverride = false
  port.downloadsGetterOverride = false
  let subject = started(port)
  subject.checkForUpdates()
  port.values[downloadsKey] = true
  #expect(!subject.mayPerformCheck(userInitiated: true))
  subject.checkForUpdates()
  #expect(port.checks == 1)
  subject.canCheckChanged()
  #expect(!subject.state.checkEnabled)
  subject.settingsChanged()
  #expect(subject.state.checkEnabled)
}
