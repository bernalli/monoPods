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

// MARK: - Automatic downloads off, automatic checks by choice, with a fake updater

/// Sparkle's user defaults keys, as an older build of the app left them.
private let checksKey = "SUEnableAutomaticChecks"
private let downloadsKey = "SUAutomaticallyUpdate"
private let oldConsentKey = "MonoPodsUpdateConsentAnswered"

/// Models Sparkle 2.10.1 with no SUAllowsAutomaticUpdates: its download getter is
/// filtered and its download setter does nothing when checks are off. Raw writes
/// and persistence can fail independently of the effective getters. The question flag is
/// already written, as on every launch after the first, unless a test clears it.
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
  var questionAsked = true
  var replies: [@MainActor (AutomaticUpdateAnswer) -> Void] = []
  var starts = 0
  var checks = 0
  var rawAutomaticDownloads: Any? { values[downloadsKey] }
  var automaticChecks: Bool {
    checksGetterOverride ?? ((values[checksKey] as? Bool) ?? false)
  }
  var automaticDownloads: Bool {
    downloadsGetterOverride ?? (automaticChecks && ((values[downloadsKey] as? Bool) ?? false))
  }
  var automaticUpdateQuestionAsked: Bool { questionAsked }
  func switchOffAutomaticDownloads() {
    events.append("raw \(downloadsKey)=false")
    if !lostWrites.contains(downloadsKey) { values[downloadsKey] = false }
    onWrite?()
    events.append("setter \(downloadsKey)=false")
    if automaticChecks && !lostWrites.contains(downloadsKey) { values[downloadsKey] = false }
    onWrite?()
  }
  func setAutomaticChecks(_ enabled: Bool) {
    events.append("checks=\(enabled)")
    if !lostWrites.contains(checksKey) { values[checksKey] = enabled }
  }
  func markAutomaticUpdateQuestionAsked() {
    events.append("asked")
    questionAsked = true
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

/// A reference that a main-actor closure can change.
@MainActor private final class Box<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// Starts a coordinator whose question records itself and keeps the reply for the test.
@MainActor private func started(_ port: FakePort) -> UpdateCoordinator {
  let coordinator = UpdateCoordinator(port: port)
  coordinator.ask = { [port] reply in
    port.events.append("ask")
    port.replies.append(reply)
  }
  coordinator.start()
  return coordinator
}

private let switchOff = [
  "raw SUAutomaticallyUpdate=false", "setter SUAutomaticallyUpdate=false", "sync",
]
/// First launch: downloads off, checks off, the flag written, the updater started, the question.
private let firstLaunch = switchOff + ["checks=false", "asked", "start", "ask"]

@MainActor @Test func firstLaunchSwitchesDownloadsOffAsksOnceAndStartsTheUpdater() {
  let port = FakePort()
  port.questionAsked = false
  let subject = started(port)
  #expect(port.events == firstLaunch)
  #expect(!port.events.contains { $0.hasSuffix("=true") })
  #expect(port.starts == 1 && port.checks == 0 && port.replies.count == 1)
  #expect(port.questionAsked)
  #expect(!port.automaticChecks && !port.automaticDownloads)
  #expect(subject.state.available && subject.state.canCheck && subject.state.checkEnabled)
  #expect(!subject.state.automaticChecks)
  #expect(!subject.mayPerformCheck(userInitiated: false))
}

@MainActor @Test func startingTwiceStartsTheUpdaterOnce() {
  let port = FakePort()
  let subject = started(port)
  subject.start()
  #expect(port.starts == 1)
}

@MainActor @Test func settingsLeftOnByAnOlderBuildAreSwitchedOffBeforeTheStart() throws {
  for (checks, downloads) in [(true, true), (true, false), (false, true)] {
    let port = FakePort()
    port.questionAsked = false
    port.values = [oldConsentKey: true, checksKey: checks, downloadsKey: downloads]
    let subject = started(port)
    #expect(port.events == firstLaunch)
    #expect(!port.automaticChecks && !port.automaticDownloads)
    #expect(subject.state.checkEnabled && !subject.state.automaticChecks)
    #expect(!subject.mayPerformCheck(userInitiated: false))
    // Checks stay off until the answer; downloads stay off after it.
    let reply = try #require(port.replies.first)
    reply(.enable)
    #expect(port.automaticChecks && !port.automaticDownloads)
    #expect(subject.mayPerformCheck(userInitiated: false))
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
    // Only downloads are switched off again; checks turned on from outside stay and are published.
    #expect(port.events == (downloads ? switchOff : []))
    #expect(port.automaticChecks == checks && !port.automaticDownloads)
    #expect(subject.state.checkEnabled && subject.state.automaticChecks == checks)
    #expect(subject.mayPerformCheck(userInitiated: false) == checks)
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
  port.values[checksKey] = true
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
  port.events.removeAll()
  port.values[downloadsKey] = true
  subject.settingsChanged()
  #expect(port.events == switchOff)
  #expect(observed.count == 2)
  #expect(observed.allSatisfy { !$0.0 && !$0.1 })
  #expect(port.checks == 1)
  #expect(subject.state.checkEnabled)
}

@MainActor @Test func scheduledChecksPassOnlyWithAutomaticChecksOnAndDownloadsOff() {
  let port = FakePort()
  let subject = started(port)
  #expect(!subject.mayPerformCheck(userInitiated: false))
  subject.setAutomaticChecks(true)
  #expect(subject.mayPerformCheck(userInitiated: false))
  #expect(subject.mayPerformCheck(userInitiated: false))
  // A scheduled check does not use up the menu command.
  subject.checkForUpdates()
  #expect(subject.mayPerformCheck(userInitiated: false))
  #expect(subject.mayPerformCheck(userInitiated: true))
  // Downloads switched on and not yet observed: refused until they are seen off again.
  port.values[downloadsKey] = true
  #expect(!subject.mayPerformCheck(userInitiated: false))
  subject.settingsChanged()
  #expect(subject.mayPerformCheck(userInitiated: false))
  subject.setAutomaticChecks(false)
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
  for checks in [true, false] {
    let port = FakePort()
    port.values = [checksKey: checks, downloadsKey: true]
    port.lostWrites = [downloadsKey]
    let subject = started(port)
    #expect((port.values[downloadsKey] as? Bool) == true)
    #expect(!subject.state.canCheck && !subject.state.checkEnabled)
    subject.checkForUpdates()
    #expect(port.checks == 0)
    #expect(!subject.mayPerformCheck(userInitiated: true))
    #expect(!subject.mayPerformCheck(userInitiated: false))
  }
}

@MainActor @Test func theGateReopensOnlyWhenDownloadsAreSeenOff() {
  let port = FakePort()
  port.values = [checksKey: true, downloadsKey: true]
  port.lostWrites = [downloadsKey]
  let subject = started(port)
  #expect(!subject.state.checkEnabled)
  #expect(!subject.mayPerformCheck(userInitiated: false))
  port.lostWrites = []
  port.values = [checksKey: true, downloadsKey: false]
  subject.settingsChanged()
  #expect(subject.state.checkEnabled)
  #expect(subject.mayPerformCheck(userInitiated: false))
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
  let port = FakePort()
  port.values = [checksKey: false, downloadsKey: true]
  port.downloadsGetterOverride = false
  port.lostWrites = [downloadsKey]
  let subject = started(port)
  #expect(!subject.state.checkEnabled)
  subject.checkForUpdates()
  #expect(port.checks == 0 && !subject.mayPerformCheck(userInitiated: true))
  port.lostWrites = []
  subject.settingsChanged()
  #expect((port.values[downloadsKey] as? Bool) == false)
  #expect(subject.state.checkEnabled)
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
  for value in malformed {
    for losesWrite in [false, true] {
      let port = FakePort()
      port.values = [checksKey: false, downloadsKey: false]
      port.values[downloadsKey] = value
      port.downloadsGetterOverride = false
      port.lostWrites = losesWrite ? [downloadsKey] : []
      let subject = started(port)
      #expect(subject.state.checkEnabled == !losesWrite)
      subject.checkForUpdates()
      #expect(port.checks == (losesWrite ? 0 : 1))
      #expect(subject.mayPerformCheck(userInitiated: true) == !losesWrite)
    }
  }
}

@MainActor @Test func trueEffectiveGetterKeepsGateClosedEvenWithFalseRawPreferences() {
  for checks in [false, true] {
    let port = FakePort()
    port.values[checksKey] = checks
    port.downloadsGetterOverride = true
    let subject = started(port)
    #expect((port.values[downloadsKey] as? Bool) == false)
    #expect(!subject.state.checkEnabled)
    subject.checkForUpdates()
    #expect(port.checks == 0 && !subject.mayPerformCheck(userInitiated: true))
    #expect(!subject.mayPerformCheck(userInitiated: false))
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

// MARK: - The question at first launch and the switch

@Test func theQuestionsButtonsGiveTheAnswer() {
  #expect(AutomaticUpdateAnswer(buttonIndex: 0) == .enable)
  #expect(AutomaticUpdateAnswer(buttonIndex: 1) == .decline)
  for index: Int? in [2, -1, nil] {
    #expect(AutomaticUpdateAnswer(buttonIndex: index) == .dismissed)
  }
}

@MainActor @Test func theAnswerTurnsAutomaticChecksOnOnlyForEnable() throws {
  let cases: [(AutomaticUpdateAnswer, Bool)] = [
    (.enable, true), (.decline, false), (.dismissed, false),
  ]
  for (answer, on) in cases {
    let port = FakePort()
    port.questionAsked = false
    let subject = started(port)
    let published = Box(0)
    subject.onChange = { published.value += 1 }
    port.events.removeAll()
    let reply = try #require(port.replies.first)
    reply(answer)
    #expect(port.events == ["checks=\(on)"])
    #expect(port.automaticChecks == on && !port.automaticDownloads)
    #expect(subject.state.automaticChecks == on && published.value == 1)
    #expect(subject.mayPerformCheck(userInitiated: false) == on)
  }
}

@MainActor @Test func theQuestionIsNotAskedAgainOnceTheFlagIsWritten() {
  let port = FakePort()
  port.questionAsked = false
  _ = started(port)
  #expect(port.replies.count == 1 && port.questionAsked)
  // The next launch reads the written flag.
  port.events.removeAll()
  let next = started(port)
  #expect(port.events == switchOff + ["start"])
  #expect(port.replies.count == 1)
  #expect(!next.state.automaticChecks)
}

@MainActor @Test func theFlagIsWrittenBeforeTheQuestion() {
  let port = FakePort()
  port.questionAsked = false
  let subject = UpdateCoordinator(port: port)
  subject.ask = { [port] _ in port.events.append("ask flag=\(port.questionAsked)") }
  subject.start()
  #expect(port.events == switchOff + ["checks=false", "asked", "start", "ask flag=true"])
}

@MainActor @Test func aLateOrRepeatedAnswerChangesNothing() throws {
  let port = FakePort()
  port.questionAsked = false
  let subject = started(port)
  let reply = try #require(port.replies.first)
  reply(.enable)
  port.events.removeAll()
  reply(.decline)
  reply(.dismissed)
  reply(.enable)
  #expect(port.events.isEmpty && port.automaticChecks && subject.state.automaticChecks)
  // The switch used before the answer settles the question.
  let late = FakePort()
  late.questionAsked = false
  let switched = started(late)
  switched.setAutomaticChecks(false)
  late.events.removeAll()
  let lateReply = try #require(late.replies.first)
  lateReply(.enable)
  #expect(late.events.isEmpty && !late.automaticChecks && !switched.state.automaticChecks)
}

@MainActor @Test func scheduledChecksAreRefusedWhileTheQuestionIsPending() throws {
  let port = FakePort()
  port.questionAsked = false
  port.values = [checksKey: true, downloadsKey: false]
  // The write that turns checks off is lost: they stay on while the question waits.
  port.lostWrites = [checksKey]
  let subject = started(port)
  #expect(port.automaticChecks && subject.state.checkEnabled)
  #expect(!subject.mayPerformCheck(userInitiated: false))
  subject.settingsChanged()
  #expect(!subject.mayPerformCheck(userInitiated: false))
  // The menu command still works while the question waits.
  subject.checkForUpdates()
  #expect(subject.mayPerformCheck(userInitiated: true))
  port.lostWrites = []
  let reply = try #require(port.replies.first)
  reply(.enable)
  #expect(subject.mayPerformCheck(userInitiated: false))
}

@MainActor @Test func theSwitchWritesOnlyTheChecksAndTheMenuFollows() {
  let port = FakePort()
  let notStarted = UpdateCoordinator(port: port)
  notStarted.setAutomaticChecks(true)
  #expect(port.events.isEmpty && !notStarted.state.automaticChecks)
  let subject = started(port)
  let published = Box(0)
  subject.onChange = { published.value += 1 }
  port.events.removeAll()
  subject.setAutomaticChecks(true)
  #expect(port.events == ["checks=true"])
  #expect(subject.state.automaticChecks && published.value == 1)
  subject.setAutomaticChecks(false)
  #expect(port.events == ["checks=true", "checks=false"])
  #expect(!subject.state.automaticChecks && published.value == 2)
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

/// Values another process can leave under the downloads key.
@MainActor private let hostileDownloads: [Any?] = [
  nil, 0, 1, NSNumber(value: 1), "false", NSNull(), true,
]

/// Only a property-list boolean false is evidence that downloads are off.
private func isBooleanFalse(_ value: Any?) -> Bool {
  guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
    return false
  }
  return !number.boolValue
}

@MainActor @Test func randomSequencesNeverAllowACheckWithDownloadsOn() {
  var generator = SplitMix64(state: 0x6D6F_6E6F_506F_6473)
  let answers: [AutomaticUpdateAnswer] = [.enable, .decline, .dismissed]
  for _ in 0..<300 {
    let port = FakePort()
    port.questionAsked = generator.below(2) == 0
    port.values = [checksKey: generator.below(2) == 0, downloadsKey: generator.below(2) == 0]
    let subject = started(port)
    var credit = 0
    var applied = 0
    var resolved = port.replies.isEmpty
    for _ in 0..<(1 + generator.below(40)) {
      switch generator.below(11) {
      case 0: subject.settingsChanged()
      case 1: subject.canCheckChanged()
      case 2:
        let before = port.checks
        subject.checkForUpdates()
        if port.checks > before { credit = 1 }
      case 3:
        if subject.mayPerformCheck(userInitiated: true) {
          #expect(credit == 1)  // I2
          credit = 0
        }
      case 4: _ = subject.mayPerformCheck(userInitiated: false)
      case 5:
        subject.setAutomaticChecks(generator.below(2) == 0)
        resolved = true
      case 6:
        if let reply = port.replies.first {
          let start = port.events.count
          reply(answers[generator.below(answers.count)])
          applied += port.events[start...].filter { $0.hasPrefix("checks=") }.count
          resolved = true
        }
      case 7: port.values[downloadsKey] = hostileDownloads[generator.below(hostileDownloads.count)]
      case 8: port.lostWrites.formSymmetricDifference([downloadsKey])
      case 9: port.lostWrites.formSymmetricDifference([checksKey])
      default: port.syncSucceeds.toggle()
      }
      if subject.mayPerformCheck(userInitiated: false) {  // I1
        #expect(port.automaticChecks && resolved)
        #expect(isBooleanFalse(port.rawAutomaticDownloads) && !port.automaticDownloads)
      }
      #expect(applied <= 1)  // I3
      #expect(port.replies.count <= 1)  // I4
    }
  }
}
