import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private let second: UInt64 = 1_000_000_000
private let pulse: UInt64 = 100_000_000
private let simulationBoot = "00000000-0000-4000-8000-000000000001"

/// Drives an EngineFIFO the way RuntimeHost does: a 100 ms clock, adapters replying on the FIFO,
/// and diary records built from the FIFO's observe callback.
@MainActor private final class DiarySimulation {
  enum Ticking { case deadlines, everyPulse }
  let run: UInt64
  let ticking: Ticking
  var fifo: EngineFIFO!
  private(set) var now: Instant
  private(set) var records: [TraceRecord] = []
  private(set) var encoded = Data()
  private(set) var executed: [(UInt64, EngineAction)] = []
  private(set) var heartbeatCycleLines = 0
  private(set) var heartbeatCycleBytes = 0
  var answerHeartbeats = true
  var writerExitCodes: [Int32] = []
  var writerAnswers = true
  var noticeResults: [Bool] = []
  private var sequence: UInt64 = 0
  private var times: [UInt64: SourceTime] = [:]

  init(run: UInt64 = 1, ticking: Ticking = .deadlines) {
    self.run = run
    self.ticking = ticking
    now = Instant(continuousNanos: 0, utc: Self.utc(seconds: 0))
    fifo = EngineFIFO(
      engine: Engine(build: testBuild, run: run, boot: simulationBoot),
      clock: { [unowned self] in self.now },
      execute: { [unowned self] action, reply in self.execute(action, reply: reply) })
    fifo.observe = { [unowned self] input, now, actions in
      let lines =
        self.append(.input(InputPayload(utc: now.utc, input: input)), at: now)
        + self.append(.actions(ActionsPayload(utc: now.utc, actions: actions)), at: now)
      if Self.isHeartbeatCycle(input, actions) {
        self.heartbeatCycleLines += 2
        self.heartbeatCycleBytes += lines
      }
    }
    _ = append(.launch(LaunchPayload(utc: now.utc, boot: simulationBoot)), at: now)
  }
  static func utc(seconds: UInt64) -> SourceTime {
    let text = String(
      format: "2026-01-%02llu T%02llu:%02llu:%02lluZ", seconds / 86_400 + 1,
      seconds / 3600 % 24, seconds / 60 % 60, seconds % 60
    ).replacingOccurrences(of: " ", with: "")
    // swiftlint:disable:next force_try
    return try! SourceTime(text)
  }
  static func isHeartbeatCycle(_ input: EngineInput, _ actions: [EngineAction]) -> Bool {
    switch input {
    case .tick:
      return actions.count == 1
        && actions.allSatisfy {
          if case .emitHeartbeat = $0 { true } else { false }
        }
    case .heartbeat: return actions.isEmpty
    default: return false
    }
  }
  @discardableResult private func append(_ payload: TracePayload, at now: Instant) -> Int {
    sequence += 1
    let record = TraceRecord(
      build: testBuild, run: run, seq: sequence, m: now.continuousNanos, payload: payload)
    records.append(record)
    // swiftlint:disable:next force_try
    var line = try! JSONEncoder().encode(record)
    line.append(10)
    encoded.append(line)
    return line.count
  }
  private func execute(_ action: EngineAction, reply: @escaping EngineFIFO.Reply) {
    executed.append((now.continuousNanos, action))
    switch action {
    case .persist(let request):
      reply(.persistenceAcknowledged(run: run, id: request.id, success: true))
    case .emitHeartbeat(let epoch, let nonce, let sequence):
      if answerHeartbeats { reply(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence)) }
    case .queryHistory(let id, let context):
      reply(.history(query: id, context: context, observation: nil, complete: false))
    case .writeTarget(let command):
      guard writerAnswers else { return }
      let code = writerExitCodes.isEmpty ? 0 : writerExitCodes.removeFirst()
      reply(
        .writerCompleted(
          WriterReceipt(command: command, exitCode: code, quiescent: true, persisted: true)))
    case .play(let command): reply(.playCompleted(run: run, id: command.id, accepted: true))
    case .showNotice(.previousCrash):
      let success = noticeResults.isEmpty ? true : noticeResults.removeFirst()
      reply(.noticePresented(.previousCrash, success: success))
    default: break
    }
  }
  func send(_ input: EngineInput) {
    fifo.enqueue(input)
    fifo.flush()
  }
  /// Advances the 100 ms clock up to `seconds`, ticking as RuntimeHost.pulse does. It yields
  /// regularly so that timing-sensitive tests sharing the main actor are not starved.
  func advance(to seconds: UInt64) async {
    let end = seconds * second
    var pulses = 0
    while now.continuousNanos < end {
      pulses += 1
      if pulses % 1_000 == 0 { await Task.yield() }
      let next = now.continuousNanos + pulse
      now = Instant(continuousNanos: next, utc: time(next))
      switch ticking {
      case .deadlines: if fifo.tickIfDue() { fifo.flush() }
      case .everyPulse:
        fifo.enqueue(.tick)
        fifo.flush()
      }
    }
  }
  func time(_ nanos: UInt64) -> SourceTime {
    let key = nanos / second
    if let cached = times[key] { return cached }
    let value = Self.utc(seconds: key)
    times[key] = value
    return value
  }
  func finish(exitCode: Int32 = 0) {
    _ = append(.end(EndPayload(utc: now.utc, exitCode: exitCode)), at: now)
  }
  var context: ObservationContext {
    ObservationContext(routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1)
  }
  func start(journal: RuntimeLoad = .missing, route: Bool) async {
    send(.journalLoaded(journal))
    send(.audioObserved(AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)))
    send(.sentinelAvailable(true))
    send(.streamStarted(epoch: 1, nonce: "nonce-1"))
    guard route else { return }
    await advance(to: 1)
    send(.route(Route(epoch: 1, deviceOrdinal: 1)))
    send(.connection(Connection(epoch: 1, boundary: now.utc)))
  }
  func count(_ value: Int, source: Source = .s1) {
    send(
      .observation(
        Observation(
          sourceTime: now.utc, source: source, provenance: .live, context: context,
          receivedContinuousNanos: now.continuousNanos, value: .count(value, detection: .on))))
  }
  func earTransition() {
    send(
      .observation(
        Observation(
          sourceTime: now.utc, source: .m, provenance: .live, context: context,
          receivedContinuousNanos: now.continuousNanos, value: .transition(from: .both, to: .one))
      ))
  }
}

/// Covers every deadline the core keeps: Play confirmation, writer retry, crash notice
/// retry, heartbeat emission and expiry with stream restart, and an outstanding close handled by the host watchdog.
@MainActor private func deadlineScenario(_ ticking: DiarySimulation.Ticking) async
  -> DiarySimulation
{
  let simulation = DiarySimulation(run: 2, ticking: ticking)
  var crashed = JournalRecord(run: 1, build: testBuild)
  crashed.lifecycle.closedCleanly = false
  simulation.noticeResults = [false, true]
  simulation.writerExitCodes = [1, 0]
  await simulation.start(journal: .record(crashed), route: true)
  await simulation.advance(to: 5)
  simulation.count(1)
  // The player is known to be playing, so the Play is due 100 ms after the Pause.
  simulation.send(.nowPlaying(epoch: 1, playing: true, sourceTime: simulation.now.utc))
  await simulation.advance(to: 40)
  simulation.send(.pause(simulation.now.utc))
  simulation.earTransition()
  await simulation.advance(to: 100)
  simulation.answerHeartbeats = false
  await simulation.advance(to: 160)
  simulation.answerHeartbeats = true
  simulation.send(.streamStarted(epoch: 2, nonce: "nonce-2"))
  await simulation.advance(to: 200)
  simulation.writerAnswers = false
  simulation.send(.quit(.user))
  await simulation.advance(to: 230)
  simulation.finish()
  return simulation
}

@MainActor @Test func deadlineTicksActLikeTickingEveryPulse() async {
  let gated = await deadlineScenario(.deadlines)
  let reference = await deadlineScenario(.everyPulse)
  #expect(gated.executed.count == reference.executed.count)
  #expect(gated.executed.map(\.0) == reference.executed.map(\.0))
  #expect(gated.executed.map(\.1) == reference.executed.map(\.1))
  let actions = gated.executed.map(\.1)
  #expect(actions.contains { if case .play = $0 { true } else { false } })
  #expect(actions.filter { if case .writeTarget = $0 { true } else { false } }.count >= 3)
  #expect(actions.filter { $0 == .showNotice(.previousCrash) }.count == 2)
  #expect(actions.contains { if case .restartStream = $0 { true } else { false } })
  // An outstanding call leaves the engine open; the independent host watchdog exits.
  #expect(!gated.fifo.snapshot.terminated)
  #expect(!actions.contains(.terminate(0)))
  #expect(gated.records.count < reference.records.count)
}

@MainActor private func replay(_ data: Data) -> (matched: Bool, actions: [EngineAction]) {
  let decoded = LogReport.decodeJSONL(data)
  guard decoded.complete, case .launch(let launch) = decoded.records.first?.payload else {
    return (false, [])
  }
  let first = decoded.records[0]
  var engine = Engine(build: first.build, run: first.run, boot: launch.boot)
  var expected: [EngineAction]?
  var matched = true
  var all: [EngineAction] = []
  for record in decoded.records.dropFirst() {
    switch record.payload {
    case .input(let payload):
      if expected != nil { matched = false }
      expected = engine.handle(
        input: payload.input, at: Instant(continuousNanos: record.m, utc: payload.utc))
    case .actions(let payload):
      if expected != payload.actions { matched = false }
      all += payload.actions
      expected = nil
    case .launch, .evidence, .end: break
    }
  }
  return (matched && expected == nil, all)
}

@MainActor @Test func diaryReplayReproducesTheLiveEngineActions() async throws {
  let live = await deadlineScenario(.deadlines)
  let replayed = replay(live.encoded)
  #expect(replayed.matched)
  #expect(replayed.actions == live.executed.map(\.1))
  let report = LogReport.evaluate(
    records: live.records,
    selection: AcceptanceSelection(
      build: testBuild, from: DiarySimulation.utc(seconds: 0),
      to: DiarySimulation.utc(seconds: 3600)))
  for issue in [
    ReportIssue.actionMismatch, .missingActions, .sequenceGap, .duplicateSequence,
    .malformedRecord, .incompleteSegment, .invalidHeartbeat, .invalidPlay,
  ] {
    #expect(!report.issues.contains(issue))
  }
  #expect(report.metrics.matchedEpisodes == 1)
}

@MainActor @Test func diaryOmitsDrainsAndRepeatedConfirmationsWithoutEffect() async {
  let simulation = DiarySimulation()
  await simulation.start(route: false)
  let before = simulation.records.count
  for _ in 0..<50 {
    simulation.send(.ownerConfirmed(run: 99, build: testBuild, healthy: true))
    simulation.send(.automation(true))
  }
  #expect(simulation.records.count == before)
  #expect(
    !simulation.records.contains {
      if case .input(let payload) = $0.payload { payload.input == .drain } else { false }
    })
  #expect(EngineFIFO.recordsInDiary(.tick, actions: [], changed: false))
  #expect(EngineFIFO.recordsInDiary(.sentinelPlay(simulation.now.utc), actions: [], changed: false))
  #expect(!EngineFIFO.recordsInDiary(.drain, actions: [], changed: false))
  #expect(EngineFIFO.recordsInDiary(.drain, actions: [], changed: true))
}

/// Diary volume. The heartbeat contract fixes one emission every 10 s and two recorded inputs
/// per emission (the due tick and the returned heartbeat). Every other line stays within
/// 2,000 lines a day without audio events and within 1 MiB a day with 300 log events.
@MainActor @Test func idleDayDiaryHoldsOnlyTheHeartbeatCycle() async {
  let simulation = DiarySimulation()
  await simulation.start(route: false)
  await simulation.advance(to: 86_400)
  simulation.finish()
  let emitted = simulation.executed.filter {
    if case .emitHeartbeat = $0.1 { true } else { false }
  }.count
  #expect(emitted == 8_641)
  // The first emission answers streamStarted; every later one is a recorded tick.
  #expect(simulation.heartbeatCycleLines == 2 * emitted + 2 * (emitted - 1))
  #expect(simulation.records.count - simulation.heartbeatCycleLines <= 2_000)
  let ticks = simulation.records.filter {
    if case .input(let payload) = $0.payload { payload.input == .tick } else { false }
  }
  #expect(ticks.count == emitted - 1)
}

@MainActor @Test func dayWithThreeHundredLogEventsStaysWithinBudget() async {
  let simulation = DiarySimulation()
  await simulation.start(route: true)
  for event in 0..<300 {
    await simulation.advance(to: 2 + UInt64(event) * 288)
    // Mostly repeated states, as in the probe log; the count changes every tenth event.
    simulation.count(event / 10 % 2 == 0 ? 2 : 1, source: event % 3 == 0 ? .s1 : .s3)
  }
  await simulation.advance(to: 86_400)
  simulation.finish()
  let writers = simulation.executed.filter {
    if case .writeTarget = $0.1 { true } else { false }
  }.count
  #expect(writers == 30)
  #expect(simulation.encoded.count - simulation.heartbeatCycleBytes < 1_048_576)
  #expect(replay(simulation.encoded).matched)
}
