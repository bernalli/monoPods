import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private let manifest = String(repeating: "a", count: 64)
private let transition = UpdateTransition(id: 7, sourceBuild: 3, destinationBuild: 4)

private func handoffJSON(
  _ fields: [String: String] = [:], drop: String? = nil, extra: String? = nil
) -> Data {
  var values: [(String, String)] = [
    ("v", "1"), ("id", "7"), ("sourceBuild", "3"), ("destinationBuild", "4"),
    ("sourceManifest", "\"\(manifest)\""), ("outcome", "\"stereoConfirmed\""),
    ("phase", "\"armed\""),
  ]
  values = values.filter { $0.0 != drop }.map { ($0.0, fields[$0.0] ?? $0.1) }
  var text = "{" + values.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
  if let extra { text += "," + extra }
  return Data((text + "}").utf8)
}

// MARK: - Handoff file

@Test func handoffDecodesOnlyTheClosedSchema() throws {
  let handoff = try UpdateHandoff.decode(handoffJSON())
  #expect(handoff.transition == transition && handoff.outcome == .stereoConfirmed)
  #expect(try UpdateHandoff.decode(JSONEncoder().encode(handoff)) == handoff)
  let noop = try UpdateHandoff.decode(handoffJSON(["outcome": "\"nothingToRestore\""]))
  #expect(noop.outcome == .nothingToRestore)
  var invalid: [Data] = [
    handoffJSON(["v": "2"]), handoffJSON(["v": "true"]), handoffJSON(["v": "\"1\""]),
    handoffJSON(["id": "0"]), handoffJSON(["id": "-1"]), handoffJSON(["id": "1.5"]),
    handoffJSON(["sourceBuild": "0"]), handoffJSON(["sourceBuild": "4"]),
    handoffJSON(["destinationBuild": "3"]), handoffJSON(["destinationBuild": "1000000000"]),
    handoffJSON(["sourceBuild": "\"3\""]), handoffJSON(["sourceManifest": "\"abc\""]),
    handoffJSON(["sourceManifest": "\"\(String(repeating: "A", count: 64))\""]),
    handoffJSON(["outcome": "\"unconfirmed\""]), handoffJSON(["outcome": "\"other\""]),
    handoffJSON(["phase": "\"safe\""]), handoffJSON(["phase": "null"]),
    handoffJSON(extra: "\"extra\":1"), handoffJSON(extra: "\"id\":7"),
    Data("[]".utf8), Data("not json".utf8), Data(),
  ]
  for key in ["v", "id", "sourceBuild", "destinationBuild", "sourceManifest", "outcome", "phase"] {
    invalid.append(handoffJSON(drop: key))
  }
  let valid = handoffJSON()
  for end in 0..<valid.count { invalid.append(valid.prefix(end)) }
  for data in invalid {
    #expect(throws: (any Error).self) { try UpdateHandoff.decode(data) }
  }
}

@Test func startupRoleFollowsTheHandoffAndTheRunningBuild() throws {
  let handoff = try UpdateHandoff.decode(handoffJSON())
  #expect(HandoffRole.classify(.success(nil), runningBuild: 3, runningManifest: manifest) == .none)
  #expect(
    HandoffRole.classify(.success(handoff), runningBuild: 3, runningManifest: manifest)
      == .waiting(handoff))
  #expect(
    HandoffRole.classify(.success(handoff), runningBuild: 4, runningManifest: "b")
      == .destination(handoff))
  let other = String(repeating: "c", count: 64)
  for (build, identity) in [(3, other), (5, manifest), (2, manifest), (nil, manifest)] {
    #expect(
      HandoffRole.classify(.success(handoff), runningBuild: build, runningManifest: identity)
        == .invalid)
  }
  #expect(
    HandoffRole.classify(.failure(RuntimeError.invalid), runningBuild: 3, runningManifest: manifest)
      == .invalid)
}

@Test func onlyAValidatedDestinationAfterRecoveryActivatesTheUpdater() throws {
  let handoff = try UpdateHandoff.decode(handoffJSON())
  let ready = UpdateActivation(
    role: .destination(handoff), ownsLock: true, bundleValid: true, engineOperational: true,
    recoveryPending: false, handoffCleared: true)
  #expect(ready.automationAllowed && ready.updatesAllowed)
  #expect(ready.clearsHandoff == false)
  var pending = ready
  pending.handoffCleared = false
  #expect(pending.clearsHandoff && !pending.automationAllowed && !pending.updatesAllowed)
  for change in 0..<4 {
    var blocked = pending
    switch change {
    case 0: blocked.ownsLock = false
    case 1: blocked.bundleValid = false
    case 2: blocked.engineOperational = false
    default: blocked.recoveryPending = true
    }
    #expect(!blocked.clearsHandoff && !blocked.automationAllowed && !blocked.updatesAllowed)
  }
  for role in [HandoffRole.waiting(handoff), .invalid] {
    let waiting = UpdateActivation(
      role: role, ownsLock: true, bundleValid: true, engineOperational: true,
      recoveryPending: false, handoffCleared: false)
    #expect(!waiting.clearsHandoff && !waiting.automationAllowed && !waiting.updatesAllowed)
  }
  let normal = UpdateActivation(
    role: .none, ownsLock: true, bundleValid: true, engineOperational: true,
    recoveryPending: true, handoffCleared: false)
  #expect(normal.automationAllowed && !normal.updatesAllowed)
  var recovered = normal
  recovered.recoveryPending = false
  #expect(recovered.updatesAllowed && !recovered.clearsHandoff)
  recovered.ownsLock = false
  #expect(!recovered.updatesAllowed)
}

// MARK: - Gate state machine

private func authorizations(_ effects: [InstallationEffect]) -> Int {
  effects.filter { if case .authorizeInstaller = $0 { true } else { false } }.count
}

@Test func happyPathArmsOnlyAfterPersistence() {
  var gate = InstallationGate(sourceManifest: manifest)
  #expect(gate.handle(.proposed(transition)) == [.prepareAudio(transition)])
  #expect(gate.state == .preparing)
  let effects = gate.handle(.prepared(id: 7, .stereoConfirmed))
  let handoff = UpdateHandoff(
    transition: transition, sourceManifest: manifest, outcome: .stereoConfirmed)
  #expect(effects == [.persistHandoff(handoff)])
  #expect(gate.state == .safe && !gate.authorizes(id: 7))
  #expect(gate.handle(.persisted(id: 7, success: true)) == [.authorizeInstaller(id: 7)])
  #expect(gate.state == .armed && gate.authorizes(id: 7) && !gate.authorizes(id: 8))
  #expect(gate.handle(.installerStarted(id: 7)).isEmpty)
  // A finished cycle after the installer started keeps the handoff: termination installs.
  #expect(gate.handle(.cycleFinished(id: 7)).isEmpty)
  #expect(gate.state == .armed)
}

@Test func unconfirmedDeadlineCancelAndFailedPersistenceNeverArm() {
  for event in [
    InstallationEvent.prepared(id: 7, .unconfirmed), .deadlineReached(id: 7), .cancelled(id: 7),
  ] {
    var gate = InstallationGate(sourceManifest: manifest)
    _ = gate.handle(.proposed(transition))
    #expect(gate.handle(event) == [.refuseInstaller(id: 7), .releaseAudio(id: 7)])
    #expect(gate.state == .deferred)
    // A late confirmation is refused; the deferred update does not prepare again in this run.
    #expect(gate.handle(.prepared(id: 7, .stereoConfirmed)).isEmpty)
    #expect(gate.handle(.proposed(transition)) == [.refuseInstaller(id: 7)])
    #expect(gate.state == .deferred)
  }
  var failed = InstallationGate(sourceManifest: manifest)
  _ = failed.handle(.proposed(transition))
  _ = failed.handle(.prepared(id: 7, .nothingToRestore))
  #expect(failed.handle(.persisted(id: 7, success: false)) == [.refuseInstaller(id: 7)])
  #expect(failed.state == .blocked)
  #expect(failed.handle(.persisted(id: 7, success: true)).isEmpty)
  #expect(!failed.authorizes(id: 7))
}

@Test func aCycleWithoutTheInstallerRemovesTheHandoffBeforeReleasingAudio() {
  var gate = InstallationGate(sourceManifest: manifest)
  _ = gate.handle(.proposed(transition))
  _ = gate.handle(.prepared(id: 7, .stereoConfirmed))
  _ = gate.handle(.persisted(id: 7, success: true))
  #expect(gate.handle(.cycleFinished(id: 7)) == [.removeHandoff(id: 7)])
  #expect(gate.state == .deferred && !gate.authorizes(id: 7))
  #expect(gate.handle(.removed(id: 7, success: true)) == [.releaseAudio(id: 7)])
  var stuck = InstallationGate(sourceManifest: manifest)
  _ = stuck.handle(.proposed(transition))
  _ = stuck.handle(.prepared(id: 7, .stereoConfirmed))
  _ = stuck.handle(.persisted(id: 7, success: true))
  _ = stuck.handle(.cancelled(id: 7))
  #expect(stuck.handle(.removed(id: 7, success: false)).isEmpty)
  #expect(stuck.state == .blocked)
}

@Test func foreignDuplicateAndOutOfOrderEventsAuthorizeNothing() {
  var gate = InstallationGate(sourceManifest: manifest)
  #expect(gate.handle(.persisted(id: 7, success: true)).isEmpty)
  #expect(gate.handle(.prepared(id: 7, .stereoConfirmed)).isEmpty)
  #expect(
    gate.handle(.proposed(UpdateTransition(id: 8, sourceBuild: 4, destinationBuild: 4))) == [
      .refuseInstaller(id: 8)
    ])
  _ = gate.handle(.proposed(transition))
  #expect(gate.handle(.proposed(transition)).isEmpty)
  #expect(gate.handle(.prepared(id: 8, .stereoConfirmed)).isEmpty)
  #expect(gate.handle(.persisted(id: 7, success: true)).isEmpty)
  #expect(gate.state == .preparing)
}

/// Every prefix of a deterministic stream of hostile events keeps the invariants.
@Test func everyPrefixOfHostileEventsKeepsTheInvariants() {
  var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
  func next(_ bound: Int) -> Int {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((seed >> 33) % UInt64(bound))
  }
  for _ in 0..<400 {
    var gate = InstallationGate(sourceManifest: manifest)
    var confirmed = false
    var persistedAfterSafe = false
    var authorized = 0
    for _ in 0..<12 {
      let id = UInt64(6 + next(3))
      let results: [UpdatePreparationResult] = [.stereoConfirmed, .nothingToRestore, .unconfirmed]
      let event: InstallationEvent
      switch next(8) {
      case 0:
        event = .proposed(UpdateTransition(id: id, sourceBuild: 3, destinationBuild: 3 + next(2)))
      case 1: event = .prepared(id: id, results[next(3)])
      case 2: event = .deadlineReached(id: id)
      case 3: event = .persisted(id: id, success: next(2) == 0)
      case 4: event = .installerStarted(id: id)
      case 5: event = .cycleFinished(id: id)
      case 6: event = .cancelled(id: id)
      default: event = .removed(id: id, success: next(2) == 0)
      }
      let before = gate.state
      let effects = gate.handle(event)
      if case .prepared(let eventID, let result) = event, before == .preparing,
        eventID == gate.transition?.id, result != .unconfirmed
      {
        confirmed = true
      }
      if case .persisted(_, true) = event, before == .safe, gate.state == .armed {
        persistedAfterSafe = true
      }
      authorized += authorizations(effects)
      #expect(authorized <= 1)
      if authorized == 1 { #expect(confirmed && persistedAfterSafe) }
      if gate.state == .armed { #expect(confirmed && persistedAfterSafe) }
    }
  }
}

// MARK: - Coordinator with fake ports and an injected clock

@MainActor private final class FakeAudio: UpdateAudioPort {
  var prepared: [UInt64] = []
  var released: [UInt64] = []
  var reply: (@MainActor (UpdatePreparationResult) -> Void)?
  func prepareForUpdate(
    id: UInt64, deadline: UpdatePreparationDeadline,
    result: @escaping @MainActor (UpdatePreparationResult) -> Void
  ) {
    prepared.append(id)
    reply = result
  }
  func endUpdateHold(id: UInt64) { released.append(id) }
}

private final class FakeHandoffStore: HandoffStore {
  var data: Data?
  var failWrite = false
  var failRemove = false
  var writes = 0
  func writeHandoff(_ data: Data) throws {
    writes += 1
    if failWrite { throw RuntimeError.io(EIO) }
    self.data = data
  }
  func removeHandoff() throws {
    if failRemove { throw RuntimeError.io(EIO) }
    data = nil
  }
  func readHandoff() throws -> Data? { data }
}

@MainActor private final class Harness {
  let audio = FakeAudio()
  let store = FakeHandoffStore()
  let clock = QuitClock()
  var backgroundChecks = 0
  lazy var installer: UpdateInstaller = {
    let installer = UpdateInstaller(
      sourceBuild: 3, sourceManifest: manifest, audio: audio, store: store,
      clock: { [clock] in clock.now }, schedule: clock.schedule)
    installer.requestBackgroundCheck = { [unowned self] in backgroundChecks += 1 }
    return installer
  }()
  func advance(milliseconds: UInt64) {
    clock.advance(milliseconds)
  }
}

@MainActor @Test func manualInstallWaitsForStereoAndThePersistedHandoff() throws {
  let harness = Harness()
  var replies: [Bool] = []
  harness.installer.propose(destinationBuild: 4) { replies.append($0) }
  #expect(harness.audio.prepared.count == 1 && replies.isEmpty && harness.store.data == nil)
  harness.audio.reply?(.stereoConfirmed)
  #expect(replies == [true])
  let handoff = try UpdateHandoff.decode(#require(harness.store.data))
  #expect(handoff.transition.destinationBuild == 4 && handoff.transition.sourceBuild == 3)
  #expect(harness.installer.installsNow)
  harness.installer.installerWillStart()
  harness.installer.cycleFinished()
  #expect(harness.store.data != nil && harness.audio.released.isEmpty)
}

@MainActor @Test func preparationDeadlinesFollowTheQuitBoundaries() {
  for (milliseconds, accepted) in [(1499, true), (1500, true), (1999, true), (2000, false)] {
    let harness = Harness()
    var replies: [Bool] = []
    harness.installer.propose(destinationBuild: 4) { replies.append($0) }
    harness.advance(milliseconds: UInt64(milliseconds))
    harness.audio.reply?(.stereoConfirmed)
    #expect(replies == [accepted], "\(milliseconds)")
    #expect((harness.store.data != nil) == accepted)
    #expect(harness.audio.released == (accepted ? [] : [harness.audio.prepared[0]]))
    harness.audio.reply?(.stereoConfirmed)
    #expect(replies.count == 1)
  }
}

@MainActor @Test func failuresDeferWithoutAHandoffOrAnInstaller() {
  let unconfirmed = Harness()
  var replies: [Bool] = []
  unconfirmed.installer.propose(destinationBuild: 4) { replies.append($0) }
  unconfirmed.audio.reply?(.unconfirmed)
  #expect(replies == [false] && unconfirmed.store.writes == 0)
  #expect(unconfirmed.audio.released.count == 1 && !unconfirmed.installer.installsNow)
  unconfirmed.installer.propose(destinationBuild: 4) { replies.append($0) }
  #expect(replies == [false, false] && unconfirmed.audio.prepared.count == 1)
  let failing = Harness()
  failing.store.failWrite = true
  failing.installer.propose(destinationBuild: 4) { replies.append($0) }
  failing.audio.reply?(.nothingToRestore)
  #expect(replies.last == false && !failing.installer.installsNow)
  // Persistence failed: audio stays held, nothing is released without proof.
  #expect(failing.audio.released.isEmpty)
  let stale = Harness()
  stale.installer.propose(destinationBuild: 3) { replies.append($0) }
  #expect(replies.last == false && stale.audio.prepared.isEmpty)
}

@MainActor @Test func automaticInstallUsesTwoChecksForTheSameItem() throws {
  let harness = Harness()
  #expect(!harness.installer.shouldProceed(destinationBuild: 4))
  #expect(harness.audio.prepared.count == 1)
  #expect(!harness.installer.shouldProceed(destinationBuild: 4))
  harness.audio.reply?(.stereoConfirmed)
  #expect(harness.store.data != nil && harness.backgroundChecks == 0)
  // The second check starts only after the vetoed cycle has finished.
  harness.installer.cycleFinished()
  #expect(harness.backgroundChecks == 1)
  #expect(!harness.installer.shouldProceed(destinationBuild: 5))
  #expect(harness.store.data == nil && harness.audio.released.count == 1)
  let second = Harness()
  _ = second.installer.shouldProceed(destinationBuild: 4)
  second.installer.cycleFinished()
  second.audio.reply?(.nothingToRestore)
  #expect(second.backgroundChecks == 1)
  #expect(second.installer.shouldProceed(destinationBuild: 4))
  #expect(second.installer.installsNow)
  // The approved cycle ends without the installer: the handoff goes, then audio.
  second.installer.cycleFinished()
  #expect(second.store.data == nil && second.audio.released.count == 1)
}

@MainActor @Test func switchingOffStopsOnlyWhatSparkleHasNotStarted() {
  let preparing = Harness()
  _ = preparing.installer.shouldProceed(destinationBuild: 4)
  preparing.installer.cancel()
  #expect(preparing.audio.released.count == 1 && preparing.store.writes == 0)
  let waitingSecond = Harness()
  _ = waitingSecond.installer.shouldProceed(destinationBuild: 4)
  waitingSecond.audio.reply?(.stereoConfirmed)
  waitingSecond.installer.cancel()
  #expect(waitingSecond.store.data == nil && waitingSecond.audio.released.count == 1)
  // Once Sparkle may download, the handoff and the held audio stay until its cycle ends.
  for manual in [true, false] {
    let released = Harness()
    if manual {
      released.installer.propose(destinationBuild: 4) { _ in }
      released.audio.reply?(.stereoConfirmed)
    } else {
      _ = released.installer.shouldProceed(destinationBuild: 4)
      released.audio.reply?(.stereoConfirmed)
      released.installer.cycleFinished()
      #expect(released.installer.shouldProceed(destinationBuild: 4))
    }
    released.installer.cancel()
    #expect(released.store.data != nil && released.audio.released.isEmpty)
    #expect(released.installer.installsNow)
  }
}

@MainActor @Test func aCrashAfterEachStepLeavesARoleTheNextLaunchCanTrust() throws {
  // Before persistence nothing is on disk: the next launch is an ordinary owner.
  let early = Harness()
  early.installer.propose(destinationBuild: 4) { _ in }
  #expect(
    HandoffRole.classify(
      .success(early.store.data.map { try? UpdateHandoff.decode($0) } ?? nil), runningBuild: 3,
      runningManifest: manifest) == .none)
  // After persistence the old build waits and the new build activates.
  let late = Harness()
  late.installer.propose(destinationBuild: 4) { _ in }
  late.audio.reply?(.stereoConfirmed)
  let stored = try UpdateHandoff.decode(#require(late.store.data))
  #expect(
    HandoffRole.classify(.success(stored), runningBuild: 3, runningManifest: manifest)
      == .waiting(stored))
  #expect(
    HandoffRole.classify(.success(stored), runningBuild: 4, runningManifest: "x")
      == .destination(stored))
}

@MainActor @Test func waitingProcessCancelsOnlyTheUpdaterQuit() {
  #expect(WaitingTermination.reply(quitReason: nil) == .cancel)
  for reason in WaitingTermination.sessionReasons {
    #expect(WaitingTermination.reply(quitReason: reason) == .now)
  }
  #expect(WaitingTermination.reply(quitReason: 0x1234_5678) == .cancel)
  #expect(WaitingTermination.replaced(onDisk: "4", destination: 4))
  for value in [nil, "3", "04", "4.0", "", "x"] as [String?] {
    #expect(!WaitingTermination.replaced(onDisk: value, destination: 4))
  }
}

@MainActor @Test func secondAutomaticCheckWithoutAProposalReleasesTheHold() {
  for preparedFirst in [false, true] {
    let harness = Harness()
    _ = harness.installer.shouldProceed(destinationBuild: 4)
    if preparedFirst { harness.audio.reply?(.stereoConfirmed) }
    harness.installer.cycleFinished()
    if !preparedFirst { harness.audio.reply?(.stereoConfirmed) }
    #expect(harness.backgroundChecks == 1 && harness.store.data != nil)
    harness.installer.cycleFinished()
    #expect(harness.installer.gate.state == .deferred)
    #expect(harness.store.data == nil && harness.audio.released.count == 1)
    harness.installer.cycleFinished()
    #expect(harness.backgroundChecks == 1 && harness.audio.released.count == 1)
  }
}

@Test func loadedUUIDRejectsMalformedCommandTables() {
  func words(_ values: [UInt32]) -> Data {
    Data(
      values.flatMap { value in
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
      })
  }
  func thin(_ count: UInt32, _ size: UInt32, _ commands: Data) -> Data {
    words([0xfeed_facf, 0x0100_000c, 0, 2, count, size, 0, 0]) + commands
  }
  let uuid = Data(repeating: 7, count: 16)
  let command = words([0x1b, 24]) + uuid
  let valid = thin(1, 24, command)
  #expect(LoadedBundle.uuid(in: valid) == Array(uuid))
  for end in 0..<valid.count {
    #expect(LoadedBundle.uuid(in: Data(valid.prefix(end))) == nil)
  }
  for malformed in [
    thin(1, 24, words([0x1b, 8]) + uuid),
    thin(1, 24, words([0x1b, 32]) + uuid),
    thin(1, 8, command),
    thin(2, 24, command),
    thin(2, 48, command + command),
    thin(2, 32, command + words([1, 0])),
    thin(2, 32, words([1, 0]) + command),
  ] {
    #expect(LoadedBundle.uuid(in: malformed) == nil)
  }
}

@Test func loadedUUIDRejectsMalformedUniversalSlices() {
  func words(_ values: [UInt32], big: Bool = false) -> Data {
    Data(
      values.flatMap { value in
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ((big ? 3 - $0 : $0) * 8)) }
      })
  }
  let thin =
    words([0xfeed_facf, 0x0100_000c, 0, 2, 1, 24, 0, 0, 0x1b, 24])
    + Data(repeating: 7, count: 16)
  func fat(_ entries: [[UInt32]], padding: Int = 0, body: Data) -> Data {
    words([0xcafe_babe, UInt32(entries.count)], big: true)
      + entries.reduce(Data()) { $0 + words($1, big: true) }
      + Data(repeating: 0, count: padding) + body
  }
  let valid = fat([[0x0100_000c, 0, 32, 56, 3]], padding: 4, body: thin)
  #expect(LoadedBundle.uuid(in: valid) == Array(repeating: 7, count: 16))
  for end in 0..<valid.count {
    #expect(LoadedBundle.uuid(in: Data(valid.prefix(end))) == nil)
  }
  for malformed in [
    fat([[0x0100_000c, 0, 48, 56, 3], [0x0100_000c, 0, 104, 56, 3]], body: thin + thin),
    fat([[0x0100_000c, 0, 48, 56, 3], [7, 0, 48, 56, 3]], body: thin),
    fat([[0x0100_000c, 0, 28, 32, 0]], body: thin),
    fat([[0x0100_000c, 0, 28, 1000, 0]], body: thin),
    fat([[0x0100_000c, 0, 28, 56, 3]], body: thin),
    fat([[0x0100_000c, 0, 28, 56, 32]], body: thin),
    fat([[0x0100_000c, 0, 0, 56, 0]], body: thin),
  ] { #expect(LoadedBundle.uuid(in: malformed) == nil) }
}

private func unlockJSON(_ replacement: [String: String] = [:], extra: String? = nil) -> Data {
  let fields = [
    ("v", "1"), ("id", "7"), ("sourceBuild", "3"),
    ("confirmedAt", "\"2026-11-08T12:00:00Z\""), ("outcome", "\"userConfirmed\""),
  ]
  var values = fields.map { "\"\($0.0)\":\(replacement[$0.0] ?? $0.1)" }
  if let extra { values.append(extra) }
  return Data(("{" + values.joined(separator: ",") + "}").utf8)
}

@Test func unlockDecodesOnlyACompleteUserConfirmation() throws {
  let valid = unlockJSON()
  let record = try UpdateUnlock.decode(valid)
  #expect(record.id == 7 && record.sourceBuild == 3)
  #expect(try UpdateUnlock.decode(JSONEncoder().encode(record)) == record)
  var invalid = [Data(), unlockJSON(extra: "\"id\":7"), unlockJSON(extra: "\"extra\":0")]
  for (key, values) in [
    "v": ["0", "2", "true", "\"1\""],
    "id": ["0", "-1", "1.5", "true", "\"7\"", "18446744073709551616"],
    "sourceBuild": ["0", "-1", "1000000000", "true", "3.5", "\"3\""],
    "confirmedAt": ["0", "true", "\"yesterday\"", "\"2026-02-30T12:00:00Z\""],
    "outcome": ["true", "\"stereoConfirmed\"", "\"unconfirmed\""],
  ] {
    for value in values + ["null"] { invalid.append(unlockJSON([key: value])) }
    var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object.removeValue(forKey: key)
    invalid.append(try JSONSerialization.data(withJSONObject: object))
  }
  for end in 0..<valid.count { invalid.append(Data(valid.prefix(end))) }
  for data in invalid { #expect(throws: (any Error).self) { try UpdateUnlock.decode(data) } }
}

private final class UnlockMemoryStore: UpdateUnlockStore {
  var handoff: Data? = handoffJSON()
  var unlock: Data?
  var operations: [String] = []
  var crashAfter: String?
  var locked = false
  final class Lease {
    let release: () -> Void
    init(_ release: @escaping () -> Void) { self.release = release }
    deinit { release() }
  }
  func acquire() throws -> AnyObject {
    guard !locked else { throw RuntimeError.busy }
    locked = true
    operations.append("lock")
    return Lease { self.locked = false }
  }
  func changed(_ operation: String) throws {
    #expect(locked)
    operations.append(operation)
    if crashAfter == operation { throw RuntimeError.io(EIO) }
  }
  func writeHandoff(_ data: Data) throws { handoff = data }
  func readHandoff() throws -> Data? { handoff }
  func removeHandoff() throws {
    handoff = nil
    try changed("remove-handoff")
  }
  func readUnlock() throws -> Data? { unlock }
  func writeUnlock(_ data: Data) throws {
    unlock = data
    try changed("write-unlock")
  }
  func removeUnlock() throws {
    unlock = nil
    try changed("remove-unlock")
  }
}

@Test func unlockCrashRecoveryPreservesConfirmationUntilRecoveryFinishes() throws {
  let handoff = try UpdateHandoff.decode(handoffJSON())
  for crash in ["write-unlock", "remove-handoff", "remove-unlock", "none"] {
    let store = UnlockMemoryStore()
    store.crashAfter = crash
    func session() throws -> UpdateUnlockSession {
      try UpdateUnlockSession(store: store, acquireLock: store.acquire) {
        #expect(store.locked)
        store.operations.append("verify")
        return true
      }
    }
    do {
      let transaction = try session()
      try transaction.confirm(handoff, at: SourceTime("2026-11-08T12:00:00Z"))
    } catch { #expect(crash != "none") }
    #expect(!store.locked && store.unlock != nil)
    #expect(Array(store.operations.prefix(3)) == ["lock", "verify", "write-unlock"])
    let record = try UpdateUnlock.decode(#require(store.unlock))
    #expect(
      HandoffRole.classify(
        .success(try store.handoff.map(UpdateHandoff.decode)), unlock: .success(record),
        runningBuild: 3, runningManifest: manifest) == .recovering(record))
    store.crashAfter = nil
    do {
      let transaction = try session()
      try transaction.resume(record)
      try transaction.resume(record)
      #expect(store.handoff == nil && store.unlock != nil)
      #expect(try !transaction.finish(record, recovered: false))
      #expect(store.unlock != nil)
      if crash == "remove-unlock" { store.crashAfter = crash }
      do { _ = try transaction.finish(record, recovered: true) } catch {
        #expect(crash == "remove-unlock")
      }
    }
    #expect(store.handoff == nil && store.unlock == nil && !store.locked)
  }
}

@Test func unlockRefusesUnverifiedOrUncorrelatedEvidence() throws {
  let handoff = try UpdateHandoff.decode(handoffJSON())
  let store = UnlockMemoryStore()
  do {
    let transaction = try UpdateUnlockSession(store: store, acquireLock: store.acquire) { false }
    #expect(throws: (any Error).self) {
      try transaction.confirm(handoff, at: SourceTime("2026-11-08T12:00:00Z"))
    }
    #expect(store.unlock == nil && store.handoff != nil)
  }
  for data in [unlockJSON(["id": "8"]), unlockJSON(["sourceBuild": "4"])] {
    let record = try UpdateUnlock.decode(data)
    #expect(
      HandoffRole.classify(
        .success(handoff), unlock: .success(record), runningBuild: 3,
        runningManifest: manifest) == .invalid)
    store.unlock = data
    let transaction = try UpdateUnlockSession(store: store, acquireLock: store.acquire) { true }
    #expect(throws: (any Error).self) { try transaction.resume(record) }
    #expect(store.handoff != nil)
  }
  #expect(
    HandoffRole.classify(
      .success(handoff), unlock: .success(nil), runningBuild: 3,
      runningManifest: manifest) == .waiting(handoff))
  #expect(
    HandoffRole.classify(
      .success(nil), unlock: .failure(RuntimeError.invalid), runningBuild: 3,
      runningManifest: manifest) == .invalid)
}

@Test func unlockFileUsesPrivateAtomicPersistence() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  try files.writeUnlock(unlockJSON())
  #expect(try files.readUnlock() == unlockJSON())
  let attributes = try FileManager.default.attributesOfItem(
    atPath: root.appendingPathComponent(UpdateUnlock.fileName).path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  for stage in [FileStage.fileSync, .rename, .directorySync] {
    let failing = try AtomicRuntimeFiles(directory: root) {
      if $0 == stage { throw RuntimeError.io(EIO) }
    }
    #expect(throws: (any Error).self) { try failing.writeUnlock(unlockJSON(["id": "8"])) }
    let record = try UpdateUnlock.decode(#require(try files.readUnlock()))
    #expect([7, 8].contains(record.id))
  }
  try files.removeUnlock()
  try files.removeUnlock()
  #expect(try files.readUnlock() == nil)
}

/// Real FIFO and engine; only persistence and hardware completion are controlled by the test.
@MainActor private final class EngineUpdateAudio: UpdateAudioPort {
  let clock: QuitClock
  let utc: SourceTime
  var writes: [WriterCommand] = []
  var results: [UpdatePreparationResult] = []
  var reply: (@MainActor (UpdatePreparationResult) -> Void)?
  lazy var fifo = EngineFIFO(
    engine: Engine(build: manifest, run: 1, boot: "00000000-0000-4000-8000-000000000001"),
    clock: { [unowned self] in Instant(continuousNanos: clock.now, utc: utc) },
    execute: { [unowned self] action, reply in
      switch action {
      case .persist(let request):
        reply(.persistenceAcknowledged(run: 1, id: request.id, success: true))
      case .writeTarget(let command): writes.append(command)
      case .updatePrepared(_, let result): results.append(result)
      default: break
      }
    })
  init(clock: QuitClock) throws {
    self.clock = clock
    utc = try SourceTime("2026-11-08T12:00:00Z")
    fifo.enqueue(.journalLoaded(.missing))
    fifo.enqueue(
      .audioObserved(AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)))
    fifo.enqueue(.route(Route(epoch: 1, deviceOrdinal: 1)))
    fifo.enqueue(
      .connection(Connection(epoch: 1, boundary: try SourceTime("2026-11-08T11:59:59Z"))))
    fifo.enqueue(.streamStarted(epoch: 1, nonce: "test"))
    fifo.enqueue(.heartbeat(epoch: 1, nonce: "test", sequence: 1))
    fifo.enqueue(
      .observation(
        Observation(
          sourceTime: utc, source: .s1, provenance: .live,
          context: ObservationContext(
            routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1),
          receivedContinuousNanos: 0, value: .count(1, detection: .on))))
    fifo.flush()
    let mono = try #require(writes.first)
    #expect(mono.target == .mono)
    writes.removeAll()
    complete(mono)
  }
  func complete(_ command: WriterCommand) {
    fifo.enqueue(
      .writerCompleted(
        WriterReceipt(command: command, exitCode: 0, quiescent: true, persisted: true)))
    fifo.flush()
  }
  func prepareForUpdate(
    id: UInt64, deadline: UpdatePreparationDeadline,
    result: @escaping @MainActor (UpdatePreparationResult) -> Void
  ) {
    reply = result
    fifo.enqueue(
      .prepareUpdate(id: id),
      at: Instant(continuousNanos: deadline.startedAt ?? clock.now, utc: utc))
    fifo.flush()
  }
  func endUpdateHold(id: UInt64) {
    fifo.enqueue(.endUpdateHold(id: id))
    fifo.flush()
  }
}

@MainActor @Test func realEngineResultsRespectBoundariesAndDelayedDelivery() throws {
  for milliseconds: UInt64 in [1499, 1500, 1999, 2000, 2001] {
    for delayedTimer in [false, true] {
      let clock = QuitClock()
      let audio = try EngineUpdateAudio(clock: clock)
      let store = FakeHandoffStore()
      let installer = UpdateInstaller(
        sourceBuild: 3, sourceManifest: manifest, audio: audio, store: store,
        clock: { clock.now },
        schedule: { due, action in
          if !delayedTimer { clock.schedule(due, action) }
        }, warn: { { clock.record("warn") } })
      var replies: [Bool] = []
      installer.propose(destinationBuild: 4) { replies.append($0) }
      let stereo = try #require(audio.writes.first)
      #expect(stereo.recovery && stereo.target == .stereo)
      if milliseconds >= 1500 {
        clock.advance(1500)
        audio.fifo.enqueue(.tick)
        audio.fifo.flush()
        #expect(audio.results.isEmpty)
      }
      clock.advance(milliseconds)
      audio.complete(stereo)
      let result = try #require(audio.results.first)
      #expect(result == (milliseconds < 2000 ? .stereoConfirmed : .unconfirmed))
      audio.reply?(result)
      audio.reply?(result)
      #expect(replies == [milliseconds < 2000])
      #expect((store.data != nil) == (milliseconds < 2000))
      #expect(clock.recorded == (milliseconds < 1500 ? [] : ["warn"]))
    }
  }
  // The engine confirms on time, but delivery crosses the absolute deadline before its timer.
  let clock = QuitClock()
  let audio = try EngineUpdateAudio(clock: clock)
  let store = FakeHandoffStore()
  let installer = UpdateInstaller(
    sourceBuild: 3, sourceManifest: manifest, audio: audio, store: store,
    clock: { clock.now }, schedule: { _, _ in })
  var replies: [Bool] = []
  installer.propose(destinationBuild: 4) { replies.append($0) }
  clock.advance(1499)
  audio.complete(try #require(audio.writes.first))
  #expect(audio.results == [.stereoConfirmed])
  clock.advance(2001)
  audio.reply?(.stereoConfirmed)
  #expect(replies == [false] && store.data == nil)
}

@MainActor @Test func everyPreparationTakesItsOwnWarningFromTheFactory() throws {
  let clock = QuitClock()
  let audio = try EngineUpdateAudio(clock: clock)
  var made = 0
  let installer = UpdateInstaller(
    sourceBuild: 3, sourceManifest: manifest, audio: audio, store: FakeHandoffStore(),
    clock: { clock.now }, schedule: clock.schedule,
    warn: {
      made += 1
      let warning = StereoRestoreWarning(
        spawn: {
          clock.record("warn")
          return true
        }, fallback: {})
      return { warning.warn() }
    })
  #expect(made == 0)
  var replies: [Bool] = []
  installer.propose(destinationBuild: 4) { replies.append($0) }
  #expect(made == 1)
  let stereo = try #require(audio.writes.first)
  clock.advance(1500)
  audio.fifo.enqueue(.tick)
  audio.fifo.flush()
  clock.advance(2000)
  audio.complete(stereo)
  audio.reply?(try #require(audio.results.first))
  #expect(replies == [false] && clock.recorded == ["warn"])
  // A deferred update waits for the next launch, so this run prepares nothing more.
  installer.propose(destinationBuild: 4) { replies.append($0) }
  #expect(replies == [false, false] && made == 1 && clock.recorded == ["warn"])
  // The next launch prepares again with a fresh one-shot warning, which is shown again.
  let next = try EngineUpdateAudio(clock: clock)
  let relaunched = UpdateInstaller(
    sourceBuild: 3, sourceManifest: manifest, audio: next, store: FakeHandoffStore(),
    clock: { clock.now }, schedule: clock.schedule,
    warn: {
      made += 1
      let warning = StereoRestoreWarning(
        spawn: {
          clock.record("warn")
          return true
        }, fallback: {})
      return { warning.warn() }
    })
  relaunched.propose(destinationBuild: 4) { replies.append($0) }
  clock.advance(3500)
  clock.advance(4000)
  #expect(made == 2 && clock.recorded == ["warn", "warn"])
}

@MainActor @Test func cancellingWithTheRealFIFOAllowsLaterMonoCommands() throws {
  let clock = QuitClock()
  let audio = try EngineUpdateAudio(clock: clock)
  let installer = UpdateInstaller(
    sourceBuild: 3, sourceManifest: manifest, audio: audio, store: FakeHandoffStore(),
    clock: { clock.now }, schedule: clock.schedule)
  installer.propose(destinationBuild: 4) { _ in }
  let stereo = try #require(audio.writes.last)
  installer.cancel()
  audio.complete(stereo)
  #expect(audio.fifo.snapshot.desiredTarget == .mono)
  #expect(audio.writes.last?.target == .mono)
  #expect(!installer.installsNow)
}

@MainActor @Test func unlockIsConsumedOnlyAfterTheRealEngineRecovers() throws {
  for succeeds in [false, true] {
    let store = UnlockMemoryStore()
    store.unlock = unlockJSON()
    let record = try UpdateUnlock.decode(unlockJSON())
    let session = try UpdateUnlockSession(store: store, acquireLock: store.acquire) { true }
    try session.resume(record)
    var old = JournalRecord(run: 1, build: manifest)
    old.lifecycle.closedCleanly = false
    old.audio.restoreRequired = true
    old.audio.phase = .uncertain
    let time = Instant(continuousNanos: 0, utc: try SourceTime("2026-11-08T12:00:00Z"))
    var commands: [WriterCommand] = []
    var notices: [Notice] = []
    let fifo = EngineFIFO(
      engine: Engine(build: manifest, run: 2, boot: "00000000-0000-4000-8000-000000000001"),
      clock: { time },
      execute: { action, reply in
        switch action {
        case .persist(let request):
          reply(.persistenceAcknowledged(run: 2, id: request.id, success: true))
        case .writeTarget(let command): commands.append(command)
        case .showNotice(let notice): notices.append(notice)
        default: break
        }
      })
    fifo.enqueue(.journalLoaded(.record(old)))
    fifo.enqueue(.automation(false))
    fifo.enqueue(
      .audioObserved(AudioReading(generation: 1, mode: .mono, status: 0, systemMono: .off)))
    fifo.flush()
    func activation() -> UpdateActivation {
      UpdateActivation(
        role: .recovering(record), ownsLock: store.locked, bundleValid: true,
        engineOperational: fifo.snapshot.operational,
        recoveryPending: fifo.snapshot.recoveryPending,
        handoffCleared: false)
    }
    #expect(notices.contains(.previousCrash))
    #expect(
      !activation().clearsHandoff && !activation().automationAllowed && !activation().updatesAllowed
    )
    #expect(try !session.finish(record, recovered: activation().clearsHandoff))
    let restore = try #require(commands.first)
    #expect(restore.target == .stereo && restore.recovery)
    fifo.enqueue(
      .writerCompleted(
        WriterReceipt(
          command: restore, exitCode: succeeds ? 0 : 1,
          quiescent: true, persisted: true)))
    fifo.flush()
    #expect(activation().clearsHandoff == succeeds)
    #expect(try session.finish(record, recovered: activation().clearsHandoff) == succeeds)
    #expect((store.unlock == nil) == succeeds)
  }
}

@MainActor @Test func failedUnlockPersistenceNeverLosesTheArmedHandoff() throws {
  for stage in [FileStage.fileSync, .rename, .directorySync] {
    let root = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try AtomicRuntimeFiles(directory: root)
    try files.writeHandoff(handoffJSON())
    let restore = Data("preserved recovery evidence".utf8)
    try files.write(restore, name: "restore.json")
    let failing = try AtomicRuntimeFiles(directory: root) {
      if $0 == stage { throw RuntimeError.io(EIO) }
    }
    do {
      let session = try UpdateUnlockSession(
        store: failing,
        acquireLock: { try InstanceLock(files: files, name: "owner.lock") }, verifySource: { true })
      #expect(throws: (any Error).self) {
        try session.confirm(
          UpdateHandoff.decode(handoffJSON()), at: SourceTime("2026-11-08T12:00:00Z"))
      }
    }
    #expect(try files.readHandoff() == handoffJSON())
    #expect(try files.read("restore.json") == restore)
    if let data = try files.readUnlock() {
      let record = try UpdateUnlock.decode(data)
      let resumed = try UpdateUnlockSession(
        store: files,
        acquireLock: { try InstanceLock(files: files, name: "owner.lock") }, verifySource: { true })
      try resumed.resume(record)
      #expect(try files.readHandoff() == nil && files.readUnlock() != nil)
    } else {
      #expect(
        RuntimeHost.classify(files, version: 3, manifest: manifest)
          == .waiting(try UpdateHandoff.decode(handoffJSON())))
    }
  }
}

private let newerManifest = String(repeating: "b", count: 64)

@Test func aNewerVerifiedBuildRecoversAStaleUnlockOnlyWithoutAHandoff() throws {
  let record = try UpdateUnlock.decode(unlockJSON())
  var checks = 0
  func role(_ handoff: Data?, build: Int?, verified: Bool) throws -> HandoffRole {
    HandoffRole.classify(
      .success(try handoff.map(UpdateHandoff.decode)), unlock: .success(record),
      runningBuild: build, runningManifest: newerManifest,
      runningBundleVerified: {
        checks += 1
        return verified
      })
  }
  #expect(try role(nil, build: 4, verified: true) == .recovering(record))
  #expect(
    try role(nil, build: UpdateTransition.maximumBuild, verified: true) == .recovering(record))
  #expect(checks == 2)
  for build in [nil, 1, 2] as [Int?] {
    #expect(try role(nil, build: build, verified: true) == .invalid)
  }
  #expect(try role(nil, build: 4, verified: false) == .invalid)
  // A handoff on disk, related to the record or not, is not the evidence of a finished install.
  let unrelated = handoffJSON(["id": "8", "sourceBuild": "4", "destinationBuild": "5"])
  for handoff in [unrelated, handoffJSON()] {
    for build in [4, 5] {
      #expect(try role(handoff, build: build, verified: true) == .invalid)
    }
  }
  // The source build keeps its own path and never asks for the running-bundle check.
  checks = 0
  #expect(
    HandoffRole.classify(
      .success(nil), unlock: .success(record), runningBuild: 3, runningManifest: manifest,
      runningBundleVerified: {
        checks += 1
        return false
      }) == .recovering(record))
  #expect(checks == 0)
}

@Test func recoveryChecksTheBundleOfTheBuildThatRuns() throws {
  let record = try UpdateUnlock.decode(unlockJSON())
  for (build, source, running, expected) in [
    (3, true, false, true), (3, false, true, false), (4, false, true, true),
    (4, true, false, false), (2, true, true, false),
  ] as [(Int, Bool, Bool, Bool)] {
    #expect(
      HandoffRole.recoveryBundleValid(
        record, runningBuild: build, source: { source }, running: { running }) == expected,
      "\(build)")
  }
  #expect(
    !HandoffRole.recoveryBundleValid(record, runningBuild: nil, source: { true }, running: { true })
  )
}

/// Recovery of an unclean journal on the real engine; true when the restore succeeded.
@MainActor private func realEngineRecovers(_ record: UpdateUnlock, ownsLock: Bool) throws -> Bool {
  var old = JournalRecord(run: 1, build: manifest)
  old.lifecycle.closedCleanly = false
  old.audio.restoreRequired = true
  old.audio.phase = .uncertain
  let time = Instant(continuousNanos: 0, utc: try SourceTime("2026-11-08T12:00:00Z"))
  var commands: [WriterCommand] = []
  let fifo = EngineFIFO(
    engine: Engine(build: newerManifest, run: 2, boot: "00000000-0000-4000-8000-000000000001"),
    clock: { time },
    execute: { action, reply in
      switch action {
      case .persist(let request):
        reply(.persistenceAcknowledged(run: 2, id: request.id, success: true))
      case .writeTarget(let command): commands.append(command)
      default: break
      }
    })
  fifo.enqueue(.journalLoaded(.record(old)))
  fifo.enqueue(.automation(false))
  fifo.enqueue(
    .audioObserved(AudioReading(generation: 1, mode: .mono, status: 0, systemMono: .off)))
  fifo.flush()
  let restore = try #require(commands.first)
  #expect(restore.target == .stereo && restore.recovery)
  fifo.enqueue(
    .writerCompleted(
      WriterReceipt(command: restore, exitCode: 0, quiescent: true, persisted: true)))
  fifo.flush()
  return UpdateActivation(
    role: .recovering(record), ownsLock: ownsLock, bundleValid: true,
    engineOperational: fifo.snapshot.operational,
    recoveryPending: fifo.snapshot.recoveryPending, handoffCleared: false
  ).clearsHandoff
}

@MainActor @Test func aNewerBuildRepeatsRecoveryAfterACrashThenRemovesTheRecord() throws {
  let store = UnlockMemoryStore()
  store.handoff = nil
  store.unlock = unlockJSON()
  let record = try UpdateUnlock.decode(unlockJSON())
  func role() throws -> HandoffRole {
    HandoffRole.classify(
      .success(try store.handoff.map(UpdateHandoff.decode)),
      unlock: .success(try store.unlock.map(UpdateUnlock.decode)), runningBuild: 4,
      runningManifest: newerManifest, runningBundleVerified: { true })
  }
  for attempt in 0..<2 {
    #expect(!store.locked && store.unlock == unlockJSON())
    #expect(try role() == .recovering(record))
    let session = try UpdateUnlockSession(store: store, acquireLock: store.acquire) {
      #expect(store.locked)
      store.operations.append("verify")
      return HandoffRole.recoveryBundleValid(
        record, runningBuild: 4, source: { false }, running: { true })
    }
    try withExtendedLifetime(session) {
      try session.resume(record)
      let recovered = try realEngineRecovers(record, ownsLock: store.locked)
      #expect(recovered)
      // The first launch dies after recovery and before the record is removed.
      if attempt == 0 { return }
      #expect(try session.finish(record, recovered: recovered))
    }
  }
  #expect(store.unlock == nil && store.handoff == nil && !store.locked)
  #expect(try role() == .none)
  #expect(store.operations.filter { $0 == "verify" }.count == 2)
  #expect(store.operations.last == "remove-unlock")
}

@MainActor @Test func newerBuildBundleValidationRejectsMalformedEvidence() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let executable = root.appendingPathComponent("Contents/MacOS/MonoPods")
  let framework = root.appendingPathComponent(
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")
  let manifestURL = root.appendingPathComponent("Contents/Resources/Manifest.json")
  let plistPath = "Contents/Info.plist"
  let plistURL = root.appendingPathComponent(plistPath)
  var contents = Dictionary(
    uniqueKeysWithValues: BundleManifest.required.map { ($0, Data("artifact".utf8)) })
  contents[plistPath] = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleVersion": "4"], format: .xml, options: 0)
  for (path, data) in contents {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }
  let identity = ArtifactHash.data(try #require(contents["Contents/MacOS/MonoPods"]))
  let hashes = contents.mapValues(ArtifactHash.data)
  let document: [String: Any] = [
    "v": 1, "build": identity, "sourceCommit": String(repeating: "a", count: 40),
    "files": hashes,
  ]
  func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
  }
  let valid = try encode(document)
  try valid.write(to: manifestURL)
  func verify(signature: Bool = true, images: Bool = true, version: Int? = 4) -> Bool {
    RuntimeHost.runningBundleValid(
      root, executable: executable, version: version, manifest: identity,
      signatureValid: {
        #expect($0 == root)
        return signature
      },
      imagesMatch: {
        #expect($0 == [executable, framework])
        return images
      })
  }
  #expect(verify())
  #expect(!verify(signature: false))
  #expect(!verify(images: false))
  for version in [nil, 0, -1, 5, 1_000_000_000] as [Int?] {
    #expect(!verify(version: version))
  }
  #expect(
    !RuntimeHost.runningBundleValid(
      nil, executable: executable, version: 4, manifest: identity))
  #expect(
    !RuntimeHost.runningBundleValid(root, executable: nil, version: 4, manifest: identity))
  #expect(
    !RuntimeHost.runningBundleValid(
      root, executable: executable, version: 4, manifest: newerManifest,
      signatureValid: { _ in true }, imagesMatch: { _ in true }))
  // The fixture is unsigned and its images are not loaded into this process.
  #expect(
    !RuntimeHost.runningBundleValid(
      root, executable: executable, version: 4, manifest: identity))
  #expect(
    !RuntimeHost.runningBundleValid(
      root, executable: executable, version: 4, manifest: identity,
      signatureValid: { _ in true }))

  var invalid = [Data("[]".utf8), Data("not json".utf8)]
  var duplicate = Data(valid.dropLast())
  duplicate.append(Data(",\"build\":\"\(identity)\"}".utf8))
  invalid.append(duplicate)
  var extra = document
  extra["extra"] = 1
  invalid.append(try encode(extra))
  for key in document.keys {
    var missing = document
    missing.removeValue(forKey: key)
    invalid.append(try encode(missing))
    for wrong in [NSNull(), true, [], "wrong"] as [Any] {
      var changed = document
      changed[key] = wrong
      invalid.append(try encode(changed))
    }
  }
  for (key, value) in [
    ("v", 0), ("v", 2), ("build", ""), ("sourceCommit", "bad"),
  ] as [(String, Any)] {
    var changed = document
    changed[key] = value
    invalid.append(try encode(changed))
  }
  for path in hashes.keys {
    var missing = hashes
    missing.removeValue(forKey: path)
    var changed = document
    changed["files"] = missing
    invalid.append(try encode(changed))
  }
  for end in 0..<valid.count { invalid.append(Data(valid.prefix(end))) }
  for data in invalid {
    try data.write(to: manifestURL)
    #expect(!verify())
  }
  try valid.write(to: manifestURL)
  #expect(verify())

  // Rehash the plist so these failures exercise version validation, not its file hash.
  var badPlists = [Data("truncated plist".utf8)]
  for object in [
    [:], ["CFBundleVersion": true], ["CFBundleVersion": 4], ["CFBundleVersion": []],
    ["CFBundleVersion": "0"], ["CFBundleVersion": "-1"], ["CFBundleVersion": "04"],
    ["CFBundleVersion": "4.0"], ["CFBundleVersion": "5"],
    ["CFBundleVersion": "1000000000"],
  ] as [[String: Any]] {
    badPlists.append(
      try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0))
  }
  for data in badPlists {
    try data.write(to: plistURL)
    var changedHashes = hashes
    changedHashes[plistPath] = ArtifactHash.data(data)
    var changed = document
    changed["files"] = changedHashes
    try encode(changed).write(to: manifestURL)
    #expect(!verify())
  }
  try #require(contents[plistPath]).write(to: plistURL)
  try valid.write(to: manifestURL)
  for (path, data) in contents {
    let url = root.appendingPathComponent(path)
    try FileManager.default.removeItem(at: url)
    #expect(!verify())
    try Data("changed".utf8).write(to: url)
    #expect(!verify())
    try data.write(to: url)
  }
  #expect(verify())
}
