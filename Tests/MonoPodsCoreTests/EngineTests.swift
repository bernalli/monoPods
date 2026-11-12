import Foundation
import Testing

@testable import MonoPodsCore

func instant(_ seconds: UInt64, fraction: UInt64 = 0) -> Instant {
  Instant(
    continuousNanos: seconds * 1_000_000_000 + fraction,
    // swiftlint:disable:next force_try
    utc: try! SourceTime(
      "2001-01-01T\(String(format: "%02d", seconds / 3600)):"
        + "\(String(format: "%02d", seconds / 60 % 60)):"
        + "\(String(format: "%02d", seconds % 60)).\(String(format: "%09llu", fraction))Z"
    ))
}
func observation(
  _ count: Int?, at seconds: UInt64, provenance: Provenance = .live,
  context: ObservationContext = .test
) -> Observation {
  Observation(
    sourceTime: instant(seconds).utc, source: .s1, provenance: provenance, context: context,
    receivedContinuousNanos: seconds * 1_000_000_000,
    value: .count(count, detection: count == nil ? .unknown : .on))
}
extension ObservationContext {
  static let test = Self(routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1)
}
func acknowledge(_ actions: [EngineAction], engine: inout Engine, at time: Instant)
  -> [EngineAction]
{
  var result: [EngineAction] = []
  for action in actions {
    if case .persist(let request) = action {
      result += engine.handle(
        input: .persistenceAcknowledged(run: 1, id: request.id, success: true), at: time)
    }
  }
  return result
}
func readyEngine() -> Engine {
  var engine = Engine(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  let actions = engine.handle(input: .journalLoaded(.missing), at: instant(0))
  _ = acknowledge(actions, engine: &engine, at: instant(0))
  _ = engine.handle(input: .route(Route(epoch: 1, deviceOrdinal: 1)), at: instant(0))
  _ = engine.handle(
    input: .connection(Connection(epoch: 1, boundary: instant(0).utc)), at: instant(0))
  _ = engine.handle(input: .streamStarted(epoch: 1, nonce: "nonce"), at: instant(0))
  _ = engine.handle(input: .heartbeat(epoch: 1, nonce: "nonce", sequence: 1), at: instant(0))
  _ = engine.handle(input: .sentinelAvailable(true), at: instant(0))
  _ = engine.handle(
    input: .audioObserved(AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)),
    at: instant(0))
  return engine
}
/// A Playing row before the removals of a test that starts at 1 s: their player state is known.
func playerWasPlaying(engine: inout Engine) {
  _ = engine.handle(
    input: .nowPlaying(epoch: 1, playing: true, sourceTime: instant(0, fraction: 500_000_000).utc),
    at: instant(0, fraction: 500_000_000))
}
func delegate(_ count: Int, engine: inout Engine, seconds: UInt64) -> [EngineAction] {
  _ = engine.handle(input: .observation(observation(count, at: seconds)), at: instant(seconds))
  let prepared = engine.handle(input: .drain, at: instant(seconds))
  _ = acknowledge(prepared, engine: &engine, at: instant(seconds))
  return engine.handle(input: .drain, at: instant(seconds))
}
@Test func loadGateAndCoalescenceRevokePreparedMono() {
  var engine = Engine(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  #expect(engine.handle(input: .observation(observation(1, at: 1)), at: instant(1)).isEmpty)
  engine = readyEngine()
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  #expect(engine.snapshot.desiredTarget == .mono)
  let prepared = engine.handle(input: .drain, at: instant(1))
  #expect(prepared.contains { if case .persist = $0 { true } else { false } })
  _ = engine.handle(input: .observation(observation(2, at: 2)), at: instant(2))
  _ = acknowledge(prepared, engine: &engine, at: instant(2))
  let actions = engine.handle(input: .drain, at: instant(2))
  #expect(!actions.contains { if case .writeTarget = $0 { true } else { false } })
}
@Test func oneWriterAndReevaluationAfterDurableReceipt() throws {
  var engine = readyEngine()
  let actions = delegate(1, engine: &engine, seconds: 1)
  let command = try #require(
    actions.compactMap { if case .writeTarget(let value) = $0 { value } else { nil } }.first)
  #expect(command.target == .mono)
  _ = engine.handle(input: .observation(observation(2, at: 2)), at: instant(2))
  #expect(engine.handle(input: .drain, at: instant(2)).isEmpty)
  let receipt = WriterReceipt(command: command, exitCode: 0, quiescent: true, persisted: true)
  _ = engine.handle(input: .writerCompleted(receipt), at: instant(2))
  let prepared = engine.handle(input: .drain, at: instant(2))
  _ = acknowledge(prepared, engine: &engine, at: instant(2))
  let next = engine.handle(input: .drain, at: instant(2))
  #expect(
    next.contains {
      if case .writeTarget(let value) = $0 { value.target == .stereo } else { false }
    })
  #expect(engine.handle(input: .writerCompleted(receipt), at: instant(2)).isEmpty)
}
@Test func gapsUnknownAndSleepNeverRequestStereoButRouteLossDoes() throws {
  for invalidation in [
    EngineInput.gap(epoch: 1, reason: .transport, faultTime: nil),
    .environment(awake: false, bluetooth: true),
    .observation(observation(nil, at: 2)),
  ] {
    var engine = readyEngine()
    let actions = delegate(1, engine: &engine, seconds: 1)
    let command = try #require(
      actions.compactMap { if case .writeTarget(let value) = $0 { value } else { nil } }.first)
    _ = engine.handle(
      input: .writerCompleted(
        WriterReceipt(command: command, exitCode: 0, quiescent: true, persisted: true)),
      at: instant(1))
    _ = engine.handle(input: invalidation, at: instant(2))
    #expect(engine.snapshot.desiredTarget == nil)
    #expect(engine.handle(input: .drain, at: instant(2)).isEmpty)
    _ = engine.handle(input: .route(nil), at: instant(2))
    #expect(engine.snapshot.desiredTarget == .stereo)
  }
}
@Test func persistenceFailureAndUncertainWriterBlockAllEffects() {
  var engine = readyEngine()
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  let prepared = engine.handle(input: .drain, at: instant(1))
  for action in prepared {
    if case .persist(let request) = action {
      _ = engine.handle(
        input: .persistenceAcknowledged(run: 1, id: request.id, success: false), at: instant(1))
    }
  }
  #expect(engine.snapshot.blocked)
  #expect(engine.handle(input: .drain, at: instant(2)).isEmpty)
}
@Test func heartbeatDeadlineCannotBeHealedAtEquality() {
  var engine = readyEngine()
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  let expired = engine.handle(
    input: .heartbeat(epoch: 1, nonce: "nonce", sequence: 1), at: instant(25))
  #expect(expired.filter { if case .restartStream = $0 { true } else { false } }.count == 1)
  #expect(engine.snapshot.count == nil)
  #expect(
    !engine.handle(input: .tick, at: instant(26)).contains {
      if case .restartStream = $0 { true } else { false }
    })
}
@Test func playRequiresLiveUniqueTransitionAndExactContinuousWindow() {
  var engine = readyEngine()
  playerWasPlaying(engine: &engine)
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  _ = engine.handle(input: .pause(instant(1).utc), at: instant(1))
  let transition = Observation(
    sourceTime: instant(1).utc, source: .m, provenance: .live, context: .test,
    receivedContinuousNanos: 1_000_000_000, value: .transition(from: .both, to: .one))
  _ = engine.handle(input: .observation(transition), at: instant(1))
  #expect(
    !engine.handle(input: .drain, at: instant(1)).contains {
      if case .play = $0 { true } else { false }
    })
  let due = engine.handle(input: .tick, at: instant(1, fraction: 100_000_000))
  #expect(due.filter { if case .play = $0 { true } else { false } }.count == 1)
  _ = engine.handle(input: .pause(instant(1).utc), at: instant(2))
  _ = engine.handle(input: .observation(transition), at: instant(2))
  #expect(
    !engine.handle(input: .tick, at: instant(3)).contains {
      if case .play = $0 { true } else { false }
    })
}
@Test func detectionDisabledNoticeRearmsOnlyAtConnectionAndQuitDoesNotWaitForNotice() {
  var engine = readyEngine()
  let disabled = Observation(
    sourceTime: instant(1).utc, source: .s3, provenance: .live, context: .test,
    receivedContinuousNanos: 1_000_000_000, value: .count(nil, detection: .off))
  let first = engine.handle(input: .observation(disabled), at: instant(1))
  #expect(first.contains(.showNotice(.detectionDisabled)))
  #expect(
    !engine.handle(input: .observation(disabled), at: instant(2)).contains(
      .showNotice(.detectionDisabled)))
  var other = readyEngine()
  _ = other.handle(input: .observation(observation(2, at: 1)), at: instant(1))
  let quit = other.handle(input: .quit(.user), at: instant(2))
  #expect(quit.contains(.showNotice(.detectionQuitReminder)))
  _ = acknowledge(quit, engine: &other, at: instant(2))
  let command = commands(policyFlush(&other, at: instant(2))).first
  let completedActions = command.map { other.handle(input: completed($0), at: instant(2)) } ?? []
  let closed = acknowledge(completedActions, engine: &other, at: instant(2))
  #expect(closed.contains(.terminate(0)))
  #expect(other.nextDeadline == nil)
}
@Test func hostileSequencesMatchIndependentModel() {
  var writers = 0
  var recoveries = 0
  var plays = 0
  var restarts = 0
  var failedWriters = 0
  var notPlayingRemovals = 0
  var unknownReleased = 0
  var unknownWaited = 0
  var interventions = 0
  var declined = 0
  var resumesCaught = 0
  var reported = false
  for seed in UInt64(1)...500 {
    var random = seed
    func roll(_ bound: UInt64) -> UInt64 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      return (random >> 33) % bound
    }
    var engine = readyEngine()
    var model = ReferenceModel()
    var events: [ScenarioEvent] = []
    for step in UInt64(1)...300 {
      // 100 ms steps cover retry delays, heartbeat emission and heartbeat expiry.
      let now = instant(nanos: 2_000_000_000 + step * 100_000_000)
      var queue = [scenarioInput(roll: roll, model: model, now: now), EngineInput.drain]
      if let command = model.active, roll(4) == 0 {
        let exitCode: Int32 = roll(3) == 0 ? 1 : 0
        if exitCode != 0 { failedWriters += 1 }
        queue.insert(
          .writerCompleted(
            WriterReceipt(command: command, exitCode: exitCode, quiescent: true, persisted: true)),
          at: 0)
      }
      while !queue.isEmpty {
        let input = queue.removeFirst()
        events.append(ScenarioEvent(input: input, time: now))
        let actions = engine.handle(input: input, at: now)
        _ = model.apply(input, at: now, actions: actions, engineCount: engine.snapshot.count)
        for action in actions {
          switch action {
          case .persist(let request):
            queue.insert(.persistenceAcknowledged(run: 1, id: request.id, success: true), at: 0)
          case .writeTarget(let command):
            if command.recovery { recoveries += 1 } else { writers += 1 }
          case .play: plays += 1
          case .restartStream: restarts += 1
          default: break
          }
        }
      }
    }
    notPlayingRemovals += model.notPlayingRemovals
    unknownReleased += model.playOracle.unknownReleased
    unknownWaited += model.playOracle.unknownWaited
    interventions += model.playOracle.interventions
    declined += model.playOracle.declined
    resumesCaught += model.playOracle.resumesCaught
    if let violation = modelViolation(events) {
      var example = "not reduced"
      if !reported {
        // Only the first failing seed is reduced: the reduction replays the prefix many times.
        reported = true
        let data = try? JSONEncoder().encode(reducedCounterexample(events))
        example = data.flatMap { String(data: $0, encoding: .utf8) } ?? "encoding failed"
      }
      let failure = "seed=\(seed), event=\(violation.index), violation=\(violation.message)"
      Issue.record("\(failure), reduced=\(example)")
    }
  }
  // The alphabet must reach every guarded effect, or the property proves nothing.
  #expect(writers > 0 && recoveries > 0 && plays > 0 && restarts > 0 && failedWriters > 0)
  #expect(notPlayingRemovals > 0)
  #expect(unknownReleased > 0 && unknownWaited > 0)
  #expect(interventions > 0 && declined > 0 && resumesCaught > 0)
}

func crashedJournal(restoreRequired: Bool) -> JournalRecord {
  var record = JournalRecord(run: 9, build: String(repeating: "b", count: 64))
  record.lifecycle.closedCleanly = false
  if restoreRequired {
    record.audio.nextId = 2
    record.audio.phase = .completed
    record.audio.restoreRequired = true
    record.audio.lastCompleted = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  }
  return record
}
func crashNotices(_ actions: [EngineAction]) -> Int {
  actions.filter { $0 == .showNotice(.previousCrash) }.count
}
@Test func failedCrashNoticeIsReissuedOnlyAtSixtySecondsUntilPresented() throws {
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  let load = engine.handle(
    input: .journalLoaded(.record(crashedJournal(restoreRequired: false))), at: instant(0))
  #expect(crashNotices(acknowledge(load, engine: &engine, at: instant(0))) == 1)
  var now: UInt64 = 0
  for _ in 1...3 {
    now += 1
    #expect(
      engine.handle(input: .noticePresented(.previousCrash, success: false), at: instant(now))
        .isEmpty)
    // A second failure without a request in flight must not move the deadline.
    _ = engine.handle(input: .noticePresented(.previousCrash, success: false), at: instant(now + 1))
    let retry = now + 60
    #expect(engine.nextDeadline == retry * 1_000_000_000)
    #expect(
      crashNotices(engine.handle(input: .tick, at: instant(retry - 1, fraction: 999_999_999))) == 0)
    #expect(crashNotices(engine.handle(input: .tick, at: instant(retry))) == 1)
    #expect(engine.nextDeadline == nil)
    #expect(crashNotices(engine.handle(input: .tick, at: instant(retry + 30))) == 0)
    now = retry + 30
  }
  let presented = engine.handle(
    input: .noticePresented(.previousCrash, success: true), at: instant(now))
  let cleared = try #require(
    presented.compactMap { if case .persist(let request) = $0 { request } else { nil } }.first)
  #expect(!cleared.record.lifecycle.noticePending)
  _ = acknowledge(presented, engine: &engine, at: instant(now))
  #expect(engine.nextDeadline == nil)
  #expect(crashNotices(engine.handle(input: .tick, at: instant(now + 600))) == 0)
  _ = engine.handle(input: .noticePresented(.previousCrash, success: false), at: instant(now + 600))
  #expect(engine.nextDeadline == nil)
}
@Test func pendingCrashNoticeBlocksNeitherStereoRecoveryNorAutomation() throws {
  func writers(_ actions: [EngineAction]) -> [WriterCommand] {
    actions.compactMap { if case .writeTarget(let value) = $0 { value } else { nil } }
  }
  func persisted(_ actions: [EngineAction]) -> [PersistenceRequest] {
    actions.compactMap { if case .persist(let request) = $0 { request } else { nil } }
  }
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  let load = engine.handle(
    input: .journalLoaded(.record(crashedJournal(restoreRequired: true))), at: instant(0))
  #expect(crashNotices(acknowledge(load, engine: &engine, at: instant(0))) == 1)
  #expect(engine.snapshot.operational)
  _ = engine.handle(
    input: .audioObserved(AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)),
    at: instant(0))
  let prepared = engine.handle(input: .drain, at: instant(0))
  _ = acknowledge(prepared, engine: &engine, at: instant(0))
  let restore = try #require(writers(engine.handle(input: .drain, at: instant(0))).first)
  #expect(restore.target == .stereo && restore.recovery)
  _ = engine.handle(
    input: .writerCompleted(
      WriterReceipt(command: restore, exitCode: 0, quiescent: true, persisted: true)),
    at: instant(0))
  _ = engine.handle(input: .route(Route(epoch: 1, deviceOrdinal: 1)), at: instant(0))
  _ = engine.handle(
    input: .connection(Connection(epoch: 1, boundary: instant(0).utc)), at: instant(0))
  _ = engine.handle(input: .streamStarted(epoch: 1, nonce: "nonce"), at: instant(0))
  _ = engine.handle(input: .heartbeat(epoch: 1, nonce: "nonce", sequence: 1), at: instant(0))
  let mono = try #require(writers(delegate(1, engine: &engine, seconds: 1)).first)
  #expect(mono.target == .mono && !mono.recovery)
  // A success during writer ownership is kept and saved once the writer is done.
  let during = engine.handle(
    input: .noticePresented(.previousCrash, success: true), at: instant(1))
  #expect(persisted(during).isEmpty)
  let completed = engine.handle(
    input: .writerCompleted(
      WriterReceipt(command: mono, exitCode: 0, quiescent: true, persisted: true)),
    at: instant(1))
  let cleared = try #require(persisted(completed).first)
  #expect(!cleared.record.lifecycle.noticePending)
  _ = acknowledge(completed, engine: &engine, at: instant(1))
  #expect(crashNotices(engine.handle(input: .tick, at: instant(120))) == 0)
}
@Test func quitTerminatesFromBlockedJournalWithoutRewritingIt() {
  var record = JournalRecord(run: 9, build: String(repeating: "b", count: 64))
  record.v = 2
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  _ = engine.handle(input: .journalLoaded(.record(record)), at: instant(0))
  let quit = engine.handle(input: .quit(.user), at: instant(1))
  #expect(quit.contains(.terminate(0)))
  #expect(!quit.contains { if case .persist = $0 { true } else { false } })
  #expect(engine.nextDeadline == nil)
}
@Test func quitWithSystemOverrideClosesWithoutStereoAndKeepsDebt() throws {
  var engine = readyEngine()
  let command = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: completed(command), at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(2, .mono, override: .on)), at: instant(2))
  let quit = engine.handle(input: .quit(.user), at: instant(2))
  let saved = try #require(
    quit.compactMap { if case .persist(let value) = $0 { value } else { nil } }.first)
  #expect(saved.record.lifecycle.closedCleanly)
  #expect(saved.record.audio.restoreRequired && saved.record.audio.phase == .completed)
  #expect(commands(quit).isEmpty)
  #expect(acknowledge(quit, engine: &engine, at: instant(2)).contains(.terminate(0)))
}
@Test func liveRowOlderThanUnreadableFaultCannotRevalidateCount() {
  var engine = readyEngine()
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  _ = engine.handle(
    input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(3).utc), at: instant(3))
  _ = engine.handle(input: .observation(observation(1, at: 2)), at: instant(4))
  #expect(engine.snapshot.count == nil)
  _ = engine.handle(input: .observation(observation(1, at: 4)), at: instant(4))
  #expect(engine.snapshot.count == 1)
}
@Test func consumedPlayDeadlineNeverStaysInNextDeadline() {
  var engine = readyEngine()
  playerWasPlaying(engine: &engine)
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  _ = engine.handle(input: .pause(instant(1).utc), at: instant(1))
  let transition = Observation(
    sourceTime: instant(1).utc, source: .m, provenance: .live, context: .test,
    receivedContinuousNanos: 1_000_000_000, value: .transition(from: .both, to: .one))
  _ = engine.handle(input: .observation(transition), at: instant(1))
  let prepared = engine.handle(input: .drain, at: instant(1))
  // A blocked run is not operational, but the episode is not invalidated.
  let saves = prepared.compactMap { if case .persist(let request) = $0 { request } else { nil } }
  #expect(saves.count == 1)
  for request in saves {
    _ = engine.handle(
      input: .persistenceAcknowledged(run: 1, id: request.id, success: false), at: instant(1))
  }
  #expect(engine.snapshot.blocked)
  let due = instant(1, fraction: 100_000_000)
  #expect(
    !engine.handle(input: .tick, at: due).contains { if case .play = $0 { true } else { false } })
  #expect(engine.nextDeadline.map { $0 > due.continuousNanos } ?? true)
}
@Test func journalOutsideContractBlocksAtLoad() {
  let record = JournalRecord(run: 9, build: "not-a-build-hash")
  #expect(record.valid && !record.contractValid)
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  let actions = engine.handle(input: .journalLoaded(.record(record)), at: instant(0))
  #expect(actions.contains(.showNotice(.recoveryBlocked)))
  #expect(engine.snapshot.blocked)
}
@Test func orphanCompletionsCannotAuthorizeRecovery() {
  var engine = policyEngine(load: .record(crashedJournal(restoreRequired: true)))
  let before = engine
  let foreign = WriterCommand(run: 9, id: 1, context: nil, target: .stereo, recovery: true)
  #expect(engine.handle(input: completed(foreign), at: instant(100)).isEmpty)
  #expect(engine == before)
  #expect(commands(policyFlush(&engine, at: instant(0))).map(\.target) == [.stereo])
}
@Test func historiesMustArriveThroughCurrentQueryAndNeverAuthorizePlay() {
  var engine = readyEngine()
  _ = engine.handle(
    input: .observation(observation(1, at: 1, provenance: .history)), at: instant(1))
  #expect(engine.snapshot.count == nil)
  _ = engine.handle(input: .observation(observation(1, at: 2)), at: instant(2))
  _ = engine.handle(
    input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(3).utc), at: instant(3))
  _ = engine.handle(
    input: .observation(observation(1, at: 2, provenance: .history)), at: instant(4))
  #expect(engine.snapshot.count == nil)
}

@Test func retryBudgetSurvivesUnknownAndNoHeartbeatMeansNoRetry() throws {
  var engine = readyEngine()
  var actions = delegate(1, engine: &engine, seconds: 1)
  let command = try #require(
    actions.compactMap { if case .writeTarget(let value) = $0 { value } else { nil } }.first)
  _ = engine.handle(
    input: .writerCompleted(
      WriterReceipt(command: command, exitCode: 1, quiescent: true, persisted: true)),
    at: instant(1))
  #expect(engine.handle(input: .drain, at: instant(5)).isEmpty)
  _ = engine.handle(input: .tick, at: instant(6))
  actions = engine.handle(input: .drain, at: instant(6))
  #expect(actions.contains { if case .persist = $0 { true } else { false } })
  _ = acknowledge(actions, engine: &engine, at: instant(6))
  actions = engine.handle(input: .drain, at: instant(6))
  let second = try #require(
    actions.compactMap { if case .writeTarget(let value) = $0 { value } else { nil } }.first)
  _ = engine.handle(
    input: .writerCompleted(
      WriterReceipt(command: second, exitCode: 1, quiescent: true, persisted: true)), at: instant(6)
  )
  _ = engine.handle(input: .observation(observation(nil, at: 7)), at: instant(7))
  _ = engine.handle(input: .observation(observation(1, at: 8)), at: instant(8))
  #expect(engine.handle(input: .drain, at: instant(8)).isEmpty)
}

@Test func sourceIdentitySurvivesStreamRestartWithoutIntermediateTransition() {
  var engine = readyEngine()
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  let first = Observation(
    sourceTime: instant(1).utc, source: .m, provenance: .live, context: .test,
    receivedContinuousNanos: 1_000_000_000, value: .transition(from: .both, to: .one))
  _ = engine.handle(input: .observation(first), at: instant(1))
  _ = engine.handle(input: .streamStarted(epoch: 2, nonce: "next"), at: instant(2))
  _ = engine.handle(input: .heartbeat(epoch: 2, nonce: "next", sequence: 1), at: instant(2))
  var context = ObservationContext.test
  context.streamEpoch = 2
  // A known Playing state: only the repeated source identity can withhold the Play.
  _ = engine.handle(
    input: .nowPlaying(epoch: 2, playing: true, sourceTime: instant(2, fraction: 500_000_000).utc),
    at: instant(2, fraction: 500_000_000))
  _ = engine.handle(input: .observation(observation(1, at: 3, context: context)), at: instant(3))
  _ = engine.handle(input: .pause(instant(3).utc), at: instant(3))
  var repeated = first
  repeated.sourceTime = instant(3).utc
  repeated.context = context
  repeated.receivedContinuousNanos = 3_000_000_000
  _ = engine.handle(input: .observation(repeated), at: instant(3))
  _ = engine.handle(input: .drain, at: instant(3))
  #expect(
    !engine.handle(input: .tick, at: instant(3, fraction: 100_000_000)).contains {
      if case .play = $0 { true } else { false }
    })
}

@Test func ownerWaitWithoutAcquisitionEndsWith75AtExactlySixtySeconds() {
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  #expect(engine.handle(input: .ownerWaiting, at: instant(0)) == [.acquireOwner])
  #expect(engine.nextDeadline == 60_000_000_000)
  let early = Instant(continuousNanos: 59_999_999_999, utc: instant(0).utc)
  #expect(engine.handle(input: .tick, at: early).isEmpty)
  #expect(!engine.snapshot.terminated)
  let now = Instant(continuousNanos: 60_000_000_000, utc: instant(0).utc)
  #expect(engine.handle(input: .tick, at: now) == [.terminate(75)])
  #expect(engine.nextDeadline == nil)
  #expect(engine.snapshot.terminated)
}
@Test func liveOwnerConfirmationBeforeJournalLoadEndsWithoutWrites() {
  for healthy in [true, false] {
    var engine = Engine(
      build: String(repeating: "a", count: 64), run: 1,
      boot: "00000000-0000-4000-8000-000000000001")
    _ = engine.handle(input: .ownerWaiting, at: instant(0))
    let confirmed = engine.handle(
      input: .ownerConfirmed(run: 7, build: String(repeating: "b", count: 64), healthy: healthy),
      at: instant(1))
    #expect(confirmed == [.terminate(0)])
    #expect(engine.snapshot.terminated)
    #expect(engine.handle(input: .journalLoaded(.missing), at: instant(1)).isEmpty)
  }
}
@Test func ownerConfirmationAfterJournalLoadIsInert() {
  var engine = readyEngine()
  let before = engine
  let actions = engine.handle(
    input: .ownerConfirmed(run: 7, build: String(repeating: "a", count: 64), healthy: true),
    at: instant(0))
  #expect(actions.isEmpty)
  #expect(engine == before)
  #expect(!engine.snapshot.terminated)
}
@Test func sentinelPlayAndToggleAreDiagnosticOnly() {
  var engine = readyEngine()
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  #expect(engine.handle(input: .sentinelPlay(instant(1).utc), at: instant(1)).isEmpty)
  #expect(engine.handle(input: .sentinelToggle(instant(1).utc), at: instant(1)).isEmpty)
  #expect(engine.snapshot.count == 1)
}

@Test func playDeadlineBoundariesAreInclusiveAtDelayAndExclusiveAtExpiry() {
  let cases: [(UInt64, Bool)] = [
    (99_999_999, false), (100_000_000, true), (100_000_001, true),
    (2_999_999_999, true), (3_000_000_000, false), (3_000_000_001, false),
  ]
  for (delta, expected) in cases {
    var engine = readyEngine()
    playerWasPlaying(engine: &engine)
    _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
    _ = engine.handle(input: .pause(instant(1).utc), at: instant(1))
    let transition = Observation(
      sourceTime: instant(1).utc, source: .m, provenance: .live, context: .test,
      receivedContinuousNanos: 1_000_000_000, value: .transition(from: .both, to: .one))
    _ = engine.handle(input: .observation(transition), at: instant(1))
    _ = engine.handle(input: .drain, at: instant(1))
    let now = instant(1 + delta / 1_000_000_000, fraction: delta % 1_000_000_000)
    let actions = engine.handle(input: .tick, at: now)
    #expect(actions.contains { if case .play = $0 { true } else { false } } == expected)
  }
}
@Test func writerRetriesHaveExactBudgetAndContinuousBackoff() throws {
  var engine = readyEngine()
  let initial = delegate(1, engine: &engine, seconds: 1)
  let command = try #require(
    initial.compactMap { if case .writeTarget(let value) = $0 { value } else { nil } }.first)
  _ = engine.handle(
    input: .writerCompleted(
      WriterReceipt(command: command, exitCode: 1, quiescent: true, persisted: true)),
    at: instant(1))
  var attempts: [UInt64] = [1]
  var notices = 0
  for seconds in UInt64(2)...200 {
    let now = instant(seconds)
    let timed = engine.handle(input: .tick, at: now)
    for action in timed {
      if case .emitHeartbeat(let epoch, let nonce, let sequence) = action {
        _ = engine.handle(
          input: .heartbeat(epoch: epoch, nonce: nonce, sequence: sequence), at: now)
      }
    }
    let prepared = engine.handle(input: .drain, at: now)
    _ = acknowledge(prepared, engine: &engine, at: now)
    let delegated = engine.handle(input: .drain, at: now)
    for action in delegated {
      if case .writeTarget(let command) = action {
        attempts.append(seconds)
        let failed = engine.handle(
          input: .writerCompleted(
            WriterReceipt(command: command, exitCode: 1, quiescent: true, persisted: true)), at: now
        )
        notices += failed.filter { $0 == .showNotice(.commandFailed) }.count
      }
    }
  }
  #expect(attempts == [1, 6, 36, 156])
  #expect(notices == 1)
  _ = engine.handle(input: .observation(observation(2, at: 201)), at: instant(201))
  _ = engine.handle(input: .observation(observation(1, at: 202)), at: instant(202))
  #expect(
    engine.handle(input: .drain, at: instant(202)).contains {
      if case .persist = $0 { true } else { false }
    })
}
@Test func historyNeedsCurrentQueryAndNeverOverridesNewerLive() throws {
  func queryID(_ actions: [EngineAction]) -> UInt64? {
    actions.compactMap { if case .queryHistory(let id, _) = $0 { id } else { nil } }.first
  }
  var engine = readyEngine()
  let first = try #require(
    queryID(
      engine.handle(
        input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(1).utc),
        at: instant(1))))
  let snapshot = observation(1, at: 2, provenance: .history)
  _ = engine.handle(
    input: .history(query: first + 1, context: .test, observation: snapshot, complete: true),
    at: instant(3))
  #expect(engine.snapshot.count == nil)
  _ = engine.handle(
    input: .history(query: first, context: .test, observation: snapshot, complete: true),
    at: instant(3))
  #expect(engine.snapshot.count == 1)
  let second = try #require(
    queryID(
      engine.handle(
        input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(3).utc),
        at: instant(3))))
  _ = engine.handle(input: .observation(observation(2, at: 5)), at: instant(5))
  _ = engine.handle(
    input: .history(
      query: second, context: .test, observation: observation(1, at: 4, provenance: .history),
      complete: true),
    at: instant(6))
  #expect(engine.snapshot.count == 2)
}
@Test func removingForeignDeviceObservationsLeavesActionsIdentical() {
  func run(seed: UInt64, keepForeign: Bool) -> [EngineAction] {
    var random = seed
    var engine = readyEngine()
    var active: WriterCommand?
    var log: [EngineAction] = []
    var foreign = ObservationContext.test
    foreign.deviceOrdinal = 2
    for step in 1...300 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      let now = instant(UInt64(2 + step / 100), fraction: UInt64(step % 100) * 10_000_000)
      let isForeign = (random >> 33) % 3 == 0
      let value: ObservationValue
      let source: Source
      switch (random >> 40) % 4 {
      case 0:
        value = .transition(from: .both, to: .one)
        source = .m
      case 1:
        value = .transition(from: .one, to: .both)
        source = .m
      default:
        value = .count(Int((random >> 48) % 3), detection: .on)
        source = .s1
      }
      var inputs: [EngineInput] = []
      if !isForeign || keepForeign {
        inputs.append(
          .observation(
            Observation(
              sourceTime: now.utc, source: source, provenance: .live,
              context: isForeign ? foreign : .test, receivedContinuousNanos: now.continuousNanos,
              value: value)))
      }
      if (random >> 20) % 7 == 0 { inputs.append(.pause(now.utc)) }
      // Player rows keep Play among the compared actions.
      if (random >> 28) % 5 == 0 {
        inputs.append(
          .nowPlaying(epoch: 1, playing: (random >> 33) % 2 == 0, sourceTime: now.utc))
      }
      if let command = active, (random >> 12) % 5 == 0 {
        inputs.append(
          .writerCompleted(
            WriterReceipt(command: command, exitCode: 0, quiescent: true, persisted: true)))
        active = nil
      }
      inputs.append(.drain)
      for input in inputs {
        var actions = engine.handle(input: input, at: now)
        actions += acknowledge(actions, engine: &engine, at: now)
        for action in actions {
          if case .writeTarget(let command) = action { active = command }
        }
        log += actions
      }
    }
    return log
  }
  var plays = 0
  for seed in UInt64(1)...200 {
    let kept = run(seed: seed, keepForeign: true)
    #expect(kept == run(seed: seed, keepForeign: false), "seed=\(seed)")
    plays += kept.filter { if case .play = $0 { true } else { false } }.count
  }
  #expect(plays > 0)
}

@Test func interruptedRecoveryShowsCrashNoticeAfterOpeningAck() {
  var record = crashedJournal(restoreRequired: true)
  record.audio.phase = .running
  record.audio.nextId = 2
  record.audio.active = AudioCommand(id: 1, target: .mono)
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  let actions = engine.handle(input: .journalLoaded(.record(record)), at: instant(0))
  let opening = acknowledge(actions, engine: &engine, at: instant(0))
  #expect(opening.contains(.showNotice(.previousCrash)))
  #expect(!opening.contains(.showNotice(.recoveryBlocked)))
  #expect(!engine.snapshot.blocked)
}

@Test(arguments: [EarStatus.none, .unknown])
func endingTransitionDiscardsAPendingCountRemoval(gone: EarStatus) {
  var engine = readyEngine()
  func row(_ nanos: UInt64, _ value: ObservationValue, _ source: Source, at arrival: UInt64)
    -> EngineInput
  {
    .observation(
      Observation(
        sourceTime: instant(nanos: nanos).utc, source: source, provenance: .live, context: .test,
        receivedContinuousNanos: arrival, value: value))
  }
  let steps: [(EngineInput, UInt64)] = [
    (row(1_000_000_000, .count(2, detection: .on), .s1, at: 1_000_000_000), 1_000_000_000),
    (row(1_200_000_000, .count(1, detection: .on), .s1, at: 1_200_000_000), 1_200_000_000),
    (row(1_400_000_000, .transition(from: .both, to: gone), .m, at: 1_400_000_000), 1_400_000_000),
    (.pause(instant(nanos: 2_100_000_000).utc), 2_100_000_000),
    (row(1_920_000_000, .transition(from: .both, to: .one), .m, at: 2_200_000_000), 2_200_000_000),
    (
      .nowPlaying(epoch: 1, playing: true, sourceTime: instant(nanos: 1_630_000_000).utc),
      2_300_000_000
    ),
  ]
  for (input, time) in steps { _ = engine.handle(input: input, at: instant(nanos: time)) }
  let actions = engine.handle(input: .drain, at: instant(nanos: 2_300_000_000))
  #expect(actions.contains { if case .play = $0 { true } else { false } })
}

// MARK: - Stereo preparation before an update, without termination

private func prepared(_ actions: [EngineAction]) -> [UpdatePreparationResult] {
  actions.compactMap { if case .updatePrepared(_, let result) = $0 { result } else { nil } }
}
private func monoApplied() throws -> Engine {
  var engine = readyEngine()
  let command = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  #expect(command.target == .mono)
  _ = engine.handle(input: completed(command), at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(2, .mono)), at: instant(1))
  return engine
}
@Test func updatePreparationRestoresStereoAndReportsWithoutTerminating() throws {
  var engine = try monoApplied()
  #expect(engine.handle(input: .prepareUpdate(id: 7), at: instant(2)).isEmpty)
  let flushed = policyFlush(&engine, at: instant(2))
  let stereo = try #require(commands(flushed).first)
  #expect(stereo.target == .stereo && stereo.recovery)
  let done = engine.handle(input: completed(stereo), at: instant(2))
  #expect(done.contains(.updatePrepared(id: 7, result: .stereoConfirmed)))
  #expect(!done.contains { if case .terminate = $0 { true } else { false } })
  #expect(!engine.snapshot.terminated)
  // A held engine sends neither Mono nor Play, and reports once.
  _ = engine.handle(input: .observation(observation(1, at: 3)), at: instant(3))
  #expect(engine.snapshot.desiredTarget == nil)
  #expect(commands(policyFlush(&engine, at: instant(3))).isEmpty)
  #expect(prepared(engine.handle(input: .tick, at: instant(4))).isEmpty)
}
@Test func updatePreparationReportsNothingToRestoreOnlyForAValidCleanJournal() {
  var engine = readyEngine()
  let actions = engine.handle(input: .prepareUpdate(id: 1), at: instant(1))
  #expect(prepared(actions) == [.nothingToRestore])
  #expect(commands(actions).isEmpty)
  var blocked = Engine(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  #expect(prepared(blocked.handle(input: .prepareUpdate(id: 2), at: instant(1))) == [.unconfirmed])
  _ = blocked.handle(input: .journalLoaded(.blocked), at: instant(1))
  #expect(prepared(blocked.handle(input: .prepareUpdate(id: 3), at: instant(1))) == [.unconfirmed])
}
@Test func updatePreparationTreatsSystemMonoAsNothingToRestore() throws {
  var engine = try monoApplied()
  _ = engine.handle(input: .audioObserved(audioReading(3, .mono, override: .on)), at: instant(2))
  let actions = engine.handle(input: .prepareUpdate(id: 4), at: instant(2))
  #expect(prepared(actions) == [.nothingToRestore])
  #expect(commands(policyFlush(&engine, at: instant(2))).isEmpty)
}
@Test func updatePreparationGivesUpAtTheQuitBoundariesAndResumesWhenReleased() throws {
  for failures in [true, false] {
    var engine = try monoApplied()
    _ = engine.handle(input: .prepareUpdate(id: 9), at: instant(2))
    var results: [UpdatePreparationResult] = []
    if failures {
      var now = instant(2)
      for step in 0..<3 {
        now = instant(nanos: 2_000_000_000 + UInt64(step) * 700_000_000)
        for command in commands(policyFlush(&engine, at: now)) {
          results += prepared(engine.handle(input: completed(command, status: 1), at: now))
        }
        results += prepared(engine.handle(input: .tick, at: now))
      }
      results += prepared(engine.handle(input: .tick, at: instant(3, fraction: 499_999_999)))
    } else {
      // The attempt window closes at 1500 ms; an in-flight receipt has until 2000 ms.
      _ = policyFlush(&engine, at: instant(2))
      results += prepared(engine.handle(input: .tick, at: instant(3, fraction: 499_999_999)))
      #expect(results.isEmpty)
      results += prepared(engine.handle(input: .tick, at: instant(3, fraction: 500_000_000)))
      #expect(results.isEmpty)
      results += prepared(engine.handle(input: .tick, at: instant(4)))
    }
    #expect(results.last == .unconfirmed)
    #expect(results.filter { $0 == .unconfirmed }.count == 1)
    #expect(!engine.snapshot.terminated)
    _ = engine.handle(input: .endUpdateHold(id: 8), at: instant(4))
    #expect(engine.snapshot.desiredTarget == nil)
    _ = engine.handle(input: .endUpdateHold(id: 9), at: instant(4))
    #expect(engine.snapshot.desiredTarget == .mono)
  }
}
@Test func updatePreparationIgnoresRepeatsAndEndsCleanlyOnQuit() throws {
  var engine = try monoApplied()
  _ = engine.handle(input: .prepareUpdate(id: 5), at: instant(2))
  #expect(engine.handle(input: .prepareUpdate(id: 6), at: instant(2)).isEmpty)
  let stereo = try #require(commands(policyFlush(&engine, at: instant(2))).first)
  #expect(prepared(engine.handle(input: completed(stereo), at: instant(2))) == [.stereoConfirmed])
  let quit = engine.handle(input: .quit(.logout), at: instant(3))
  let saved = try #require(
    quit.compactMap { if case .persist(let value) = $0 { value } else { nil } }.first)
  #expect(saved.record.lifecycle.closedCleanly)
  #expect(!saved.record.audio.restoreRequired)
  #expect(commands(quit).isEmpty)
  #expect(acknowledge(quit, engine: &engine, at: instant(3)).contains(.terminate(0)))
}
@Test func updatePreparationSuspendsPlayCommands() {
  func row(_ nanos: UInt64, _ value: ObservationValue, _ source: Source) -> EngineInput {
    .observation(
      Observation(
        sourceTime: instant(nanos: nanos).utc, source: source, provenance: .live, context: .test,
        receivedContinuousNanos: nanos, value: value))
  }
  // The removal of an earbud while playing: without a hold this sends a Play.
  for held in [false, true] {
    var engine = readyEngine()
    if held { _ = engine.handle(input: .prepareUpdate(id: 1), at: instant(nanos: 900_000_000)) }
    let steps: [(EngineInput, UInt64)] = [
      (row(1_000_000_000, .count(2, detection: .on), .s1), 1_000_000_000),
      (row(1_200_000_000, .count(1, detection: .on), .s1), 1_200_000_000),
      (row(1_400_000_000, .transition(from: .both, to: .none), .m), 1_400_000_000),
      (.pause(instant(nanos: 2_100_000_000).utc), 2_100_000_000),
      (row(1_920_000_000, .transition(from: .both, to: .one), .m), 2_200_000_000),
      (
        .nowPlaying(epoch: 1, playing: true, sourceTime: instant(nanos: 1_630_000_000).utc),
        2_300_000_000
      ),
    ]
    for (input, time) in steps { _ = engine.handle(input: input, at: instant(nanos: time)) }
    let actions = engine.handle(input: .drain, at: instant(nanos: 2_300_000_000))
    #expect(actions.contains { if case .play = $0 { true } else { false } } == !held)
  }
}

@Test func cancellingAnUnreportedUpdateRestoresOrdinaryAutomation() throws {
  var engine = try monoApplied()
  _ = engine.handle(input: .prepareUpdate(id: 7), at: instant(2))
  let stereo = try #require(commands(policyFlush(&engine, at: instant(2))).first)
  _ = engine.handle(input: .endUpdateHold(id: 8), at: instant(2))
  #expect(engine.snapshot.desiredTarget == .stereo)
  _ = engine.handle(input: .endUpdateHold(id: 7), at: instant(2))
  #expect(engine.snapshot.desiredTarget == .mono)
  #expect(prepared(engine.handle(input: completed(stereo), at: instant(2))).isEmpty)
  #expect(commands(policyFlush(&engine, at: instant(2))).first?.target == .mono)
}

@Test func updateEventsRequirePositiveIdentifiers() throws {
  for id: UInt64 in [0, 1, UInt64.max] {
    for input in [EngineInput.prepareUpdate(id: id), .endUpdateHold(id: id)] {
      let decoded = try ContractValidation.decode(
        EngineInput.self, data: JSONEncoder().encode(input))
      #expect(decoded.valid == (id > 0))
    }
    for result in [UpdatePreparationResult.stereoConfirmed, .nothingToRestore, .unconfirmed] {
      let action = EngineAction.updatePrepared(id: id, result: result)
      let decoded = try ContractValidation.decode(
        EngineAction.self, data: JSONEncoder().encode(action))
      #expect(decoded.valid == (id > 0))
    }
  }
}

@Test func updateReceiptsUseTheFullAbsoluteWindow() throws {
  for milliseconds: UInt64 in [1499, 1500, 1999, 2000, 2001] {
    var engine = try monoApplied()
    _ = engine.handle(input: .prepareUpdate(id: 7), at: instant(2))
    let command = try #require(commands(policyFlush(&engine, at: instant(2))).first)
    if milliseconds >= 1500 {
      #expect(prepared(engine.handle(input: .tick, at: instant(nanos: 3_500_000_000))).isEmpty)
      #expect(commands(policyFlush(&engine, at: instant(nanos: 3_500_000_000))).isEmpty)
    }
    let result = prepared(
      engine.handle(
        input: completed(command),
        at: instant(nanos: 2_000_000_000 + milliseconds * 1_000_000)))
    #expect(result == [milliseconds < 2000 ? .stereoConfirmed : .unconfirmed])
    #expect(prepared(engine.handle(input: completed(command), at: instant(5))).isEmpty)
  }
}

@Test func updateDoesNotBeginANewAttemptAtTheRetryCutoff() throws {
  for milliseconds: UInt64 in [1499, 1500, 1999, 2000, 2001] {
    var engine = try monoApplied()
    _ = engine.handle(input: .prepareUpdate(id: 7), at: instant(2))
    let command = try #require(commands(policyFlush(&engine, at: instant(2))).first)
    let now = instant(nanos: 2_000_000_000 + milliseconds * 1_000_000)
    _ = engine.handle(input: completed(command, status: 1), at: now)
    let retries = commands(policyFlush(&engine, at: now))
    #expect(retries.count == (milliseconds < 1500 ? 1 : 0))
  }
}

@Test func unreadableFaultWatermarkNeverMovesBackwards() {
  for order: [UInt64] in [[5, 3], [3, 5], [5, 5, 3]] {
    var engine = readyEngine()
    for second in order {
      _ = engine.handle(
        input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(second).utc),
        at: instant(6))
    }
    _ = engine.handle(input: .observation(observation(1, at: 4)), at: instant(6))
    #expect(engine.snapshot.count == nil)
    #expect(engine.snapshot.desiredTarget == nil)
    _ = engine.handle(input: .observation(observation(2, at: 7)), at: instant(7))
    #expect(engine.snapshot.count == 2)
    #expect(engine.snapshot.desiredTarget == .stereo)
  }
}
