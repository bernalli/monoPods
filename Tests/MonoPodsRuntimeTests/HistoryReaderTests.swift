import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

@MainActor private final class HistoryTestProcess: HistoryProcess {
  var running = false
  var stops = 0
  var timeout: UInt64?
  var arguments: [String] = []
  var failStart = false
  var chunk: (@MainActor @Sendable (Data) -> Void)?
  var finished: (@MainActor @Sendable (Int32) -> Void)?
  func start(
    executable: String, arguments: [String], timeoutSeconds: UInt64?,
    chunk: @escaping @MainActor @Sendable (Data) -> Void,
    finished: @escaping @MainActor @Sendable (Int32) -> Void
  ) throws {
    #expect(executable == "/usr/bin/log")
    self.arguments = arguments
    timeout = timeoutSeconds
    self.chunk = chunk
    self.finished = finished
    if failStart { throw RuntimeError.child }
    running = true
  }
  func stop() { stops += 1 }
  func finish(_ status: Int32 = 0) {
    running = false
    finished?(status)
  }
}

@MainActor private final class HistoryTestClock {
  struct Alarm {
    let id: Int
    let due: UInt64
    let fire: @MainActor @Sendable () -> Void
  }
  var now: UInt64 = 0
  var alarms: [Alarm] = []
  var nextID = 0
  func schedule(_ delay: UInt64, _ fire: @escaping @MainActor @Sendable () -> Void)
    -> (@MainActor () -> Void)
  {
    nextID += 1
    let id = nextID
    alarms.append(Alarm(id: id, due: now + delay, fire: fire))
    return { [weak self] in self?.alarms.removeAll { $0.id == id } }
  }
  func advance(to time: UInt64) {
    now = time
    let due = alarms.filter { $0.due <= now }
    alarms.removeAll { $0.due <= now }
    for alarm in due { alarm.fire() }
  }
  func fireEarly() {
    guard !alarms.isEmpty else { return }
    alarms.removeFirst().fire()
  }
}

@MainActor private final class HistoryHarness {
  let clock = HistoryTestClock()
  var processes: [HistoryTestProcess] = []
  var starts: [UInt64] = []
  var inputs: [EngineInput] = []
  var failNextStart = false
  var driver: ObservationDriver!
  var transport: LogTransport!
  let context = ObservationContext(
    routeEpoch: 1, streamEpoch: 1, connectionEpoch: 2, deviceOrdinal: 1)
  init() throws {
    let utc = try SourceTime("2026-01-01T00:00:10Z")
    driver = ObservationDriver(
      clock: { [unowned self] in Instant(continuousNanos: self.clock.now, utc: utc) },
      submit: { [unowned self] in self.inputs.append($0) })
    transport = LogTransport(
      driver: driver, boot: "00000000-0000-4000-8000-000000000001",
      clock: { [unowned self] in self.clock.now }, schedule: clock.schedule,
      makeHistoryProcess: { [unowned self] in
        let process = HistoryTestProcess()
        process.failStart = self.failNextStart
        self.failNextStart = false
        self.processes.append(process)
        self.starts.append(self.clock.now)
        return process
      }, submit: { [unowned self] in self.inputs.append($0) })
    driver.route(address: "00:11:22:33:44:55")
    driver.connected(address: "00:11:22:33:44:55", at: try SourceTime("2026-01-01T00:00:00Z"))
    _ = try driver.beginStream(nonce: "test")
  }
  var replies: [EngineInput] {
    inputs.filter { if case .history = $0 { true } else { false } }
  }
  func request(_ id: UInt64, context: ObservationContext? = nil) {
    transport.history(id: id, context: context ?? self.context)
  }
  func assertBounds() {
    #expect(processes.filter(\.running).count <= 1)
    #expect(transport.activeHistoryCount <= 1)
    #expect(transport.pendingHistoryCount <= 1)
    #expect(clock.alarms.count <= 1)
    for pair in zip(starts, starts.dropFirst()) { #expect(pair.1 - pair.0 >= 1_000_000_000) }
  }
}

@MainActor @Test func historyBurstKeepsOneActiveAndOnlyTheLatestPendingRequest() throws {
  let harness = try HistoryHarness()
  for id: UInt64 in 1...100 {
    harness.request(id)
  }
  #expect(harness.processes.count == 1)
  #expect(harness.transport.pendingHistoryCount == 1)
  harness.assertBounds()
  harness.clock.advance(to: 2_000_000_000)
  #expect(harness.processes.count == 1)
  harness.processes[0].finish(-1)
  #expect(harness.processes.count == 2)
  #expect(harness.transport.pendingHistoryCount == 0)
  harness.processes.last?.finish(-1)
  #expect(
    harness.replies == [
      .history(query: 1, context: harness.context, observation: nil, complete: false),
      .history(query: 100, context: harness.context, observation: nil, complete: false),
    ])
}

@MainActor @Test func historyThrottleSurvivesEarlyAlarmsAndPendingReplacement() throws {
  let harness = try HistoryHarness()
  harness.request(1)
  harness.processes[0].finish(-1)
  harness.request(2)
  harness.request(3)
  #expect(harness.processes.count == 1)
  harness.clock.advance(to: 999_999_999)
  harness.clock.fireEarly()
  #expect(harness.processes.count == 1)
  harness.clock.advance(to: 1_000_000_000)
  #expect(harness.processes.count == 2)
  harness.processes.last?.finish(-1)
  #expect(
    harness.replies.last
      == .history(
        query: 3, context: harness.context, observation: nil, complete: false))
  harness.assertBounds()
}

@MainActor @Test func historyKeepsOriginalCorrelationAcrossRouteAndStreamChanges() throws {
  let harness = try HistoryHarness()
  harness.request(1)
  harness.driver.route(address: "AA:BB:CC:DD:EE:FF")
  _ = try harness.driver.beginStream(nonce: "next")
  let changed = ObservationContext(
    routeEpoch: 2, streamEpoch: 2, connectionEpoch: 3, deviceOrdinal: 2)
  harness.request(2, context: changed)
  harness.clock.advance(to: 2_000_000_000)
  harness.processes[0].chunk?(Data("{\"count\":0,\"finished\":1}\n".utf8))
  harness.processes[0].finish()
  #expect(
    harness.replies.first
      == .history(
        query: 1, context: harness.context, observation: nil, complete: true))
  #expect(harness.processes.count == 2)
  // A duplicate late callback cannot free the new active slot or emit another old reply.
  harness.processes[0].finish()
  harness.request(3, context: changed)
  #expect(harness.processes.count == 2)
  #expect(harness.replies.count == 1)
  harness.clock.advance(to: 3_000_000_000)
  harness.processes[1].finish(-1)
  harness.processes.last?.finish(-1)
  #expect(
    harness.replies.last
      == .history(
        query: 3, context: changed, observation: nil, complete: false))
  harness.assertBounds()
}

@MainActor @Test func historyTimeoutAndSizeLimitWaitForActualCompletion() throws {
  let harness = try HistoryHarness()
  harness.request(1)
  harness.request(2)
  let first = harness.processes[0]
  #expect(first.timeout == 30)
  #expect(first.arguments.first == "show")
  first.chunk?(Data(repeating: 65, count: 8 * 1024 * 1024 + 1))
  #expect(first.stops == 1)
  first.chunk?(Data("ignored".utf8))
  #expect(first.stops == 1)
  harness.clock.advance(to: 31_000_000_000)
  #expect(harness.processes.count == 1)
  first.finish(-1)
  #expect(harness.processes.count == 2)
  #expect(
    harness.replies.first
      == .history(
        query: 1, context: harness.context, observation: nil, complete: false))
  harness.processes[1].finish(-1)
  harness.assertBounds()
}

@MainActor @Test func historyStopDropsPendingAndIgnoresLateCallbacks() throws {
  let harness = try HistoryHarness()
  harness.request(1)
  harness.request(2)
  harness.transport.stop()
  harness.transport.stop()
  #expect(harness.processes[0].stops == 1)
  #expect(harness.transport.activeHistoryCount == 1)
  #expect(harness.transport.pendingHistoryCount == 0)
  harness.request(3)
  harness.clock.advance(to: 60_000_000_000)
  harness.processes[0].chunk?(Data("ignored".utf8))
  harness.processes[0].finish(-1)
  #expect(harness.processes.count == 1)
  #expect(harness.transport.activeHistoryCount == 0)
  #expect(harness.replies.isEmpty)
}

@MainActor @Test func historyStopCancelsThrottleAndRejectsItsStaleAlarm() throws {
  let harness = try HistoryHarness()
  harness.request(1)
  harness.processes[0].finish(-1)
  harness.request(2)
  let alarm = try #require(harness.clock.alarms.first)
  harness.transport.stop()
  #expect(harness.clock.alarms.isEmpty)
  harness.clock.advance(to: 2_000_000_000)
  alarm.fire()
  #expect(harness.processes.count == 1)
  #expect(harness.transport.pendingHistoryCount == 0)
}

@MainActor @Test func historyLaunchFailureIsCorrelatedAndThrottled() throws {
  let harness = try HistoryHarness()
  harness.failNextStart = true
  harness.request(1)
  #expect(harness.transport.activeHistoryCount == 0)
  #expect(
    harness.replies == [
      .history(query: 1, context: harness.context, observation: nil, complete: false)
    ])
  harness.request(2)
  harness.request(3)
  harness.clock.advance(to: 1_000_000_000)
  #expect(harness.processes.count == 2)
  harness.processes.last?.finish(-1)
  #expect(
    harness.replies.last
      == .history(
        query: 3, context: harness.context, observation: nil, complete: false))
  harness.assertBounds()
}

@MainActor @Test func generatedHistorySequencesBoundProcessesAndPendingRequests() throws {
  for seed: UInt64 in 1...32 {
    let harness = try HistoryHarness()
    var random = seed
    var nextID: UInt64 = 1
    for step in 0..<300 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      switch (random >> 32) % 7 {
      case 0...2:
        let context = ObservationContext(
          routeEpoch: 1 + random % 3, streamEpoch: 1 + random % 5,
          connectionEpoch: 1 + random % 7, deviceOrdinal: 1)
        harness.request(nextID, context: context)
        nextID += 1
      case 3: harness.processes.last(where: \.running)?.finish(random % 2 == 0 ? 0 : -1)
      case 4: harness.clock.advance(to: harness.clock.now + random % 2_000_000_001)
      case 5: harness.clock.fireEarly()
      default:
        if step > 250 { harness.transport.stop() } else { harness.failNextStart = true }
      }
      harness.assertBounds()
    }
    harness.transport.stop()
    harness.processes.last(where: \.running)?.finish(-1)
    #expect(harness.transport.activeHistoryCount == 0)
    #expect(harness.transport.pendingHistoryCount == 0)
  }
}

@MainActor @Test func historyGapBurstsFromTheEngineUseOneGlobalSlot() throws {
  let harness = try HistoryHarness()
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  let now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:10Z"))
  _ = engine.handle(input: .journalLoaded(.missing), at: now)
  for input in harness.inputs { _ = engine.handle(input: input, at: now) }
  var queries: [UInt64] = []
  for _ in 0..<100 {
    harness.driver.consume(Data("{invalid}\n".utf8), epoch: 1)
    let input = try #require(harness.inputs.last)
    guard case .gap = input else {
      Issue.record("Expected an unreadable gap")
      return
    }
    for action in engine.handle(input: input, at: now) {
      if case .queryHistory(let id, let context) = action {
        queries.append(id)
        harness.request(id, context: context)
      }
    }
    harness.assertBounds()
  }
  try #require(queries.count == 100)
  try #require(harness.processes.count == 1)
  #expect(harness.transport.pendingHistoryCount == 1)
  harness.clock.advance(to: 2_000_000_000)
  let first = try #require(harness.processes.first)
  first.finish(-1)
  try #require(harness.processes.count == 2)
  let second = try #require(harness.processes.last)
  second.finish(-1)
  let delivered = harness.replies.compactMap { input -> UInt64? in
    if case .history(let id, _, _, _) = input { return id }
    return nil
  }
  #expect(delivered == [queries.first, queries.last].compactMap { $0 })
}

@MainActor @Test func historyTimeoutCannotStartASuccessorBeforeTheExitCallback() throws {
  let harness = try HistoryHarness()
  harness.request(1)
  harness.request(2)
  harness.clock.advance(to: 30_000_000_000)
  #expect(harness.processes[0].timeout == 30)
  #expect(harness.processes.count == 1)
  // LogProcess owns deadline enforcement; its negative completion releases admission.
  harness.processes[0].finish(-1)
  #expect(harness.processes.count == 2)
  #expect(
    harness.replies.first
      == .history(
        query: 1, context: harness.context, observation: nil, complete: false))
  harness.processes[1].finish(-1)
  harness.assertBounds()
}
