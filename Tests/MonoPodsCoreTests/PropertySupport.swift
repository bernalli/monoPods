import Foundation
import Testing

@testable import MonoPodsCore

struct ScenarioEvent: Codable {
  var input: EngineInput
  var time: Instant
}
func instant(nanos: UInt64) -> Instant {
  instant(nanos / 1_000_000_000, fraction: nanos % 1_000_000_000)
}
/// Reference model of engine behavior for the generated input alphabet.
/// It is computed only from inputs and emitted actions and never reads Engine state.
struct ReferenceModel {
  var route: Route? = Route(epoch: 1, deviceOrdinal: 1)
  var routeHighWater: UInt64 = 1
  var connection: Connection? = Connection(epoch: 1, boundary: instant(0).utc)
  var connectionHighWater: UInt64 = 1
  var streamEpoch: UInt64 = 1
  var nonce = "nonce"
  var streamStart = instant(0).utc
  var healthy = true
  var failed = false
  var heartbeatDeadline: UInt64? = 25_000_000_000
  var lastHeartbeat: UInt64 = 1
  var sent: [UInt64: UInt64] = [:]
  var count: Int?
  var lastState: SourceTime?
  var unreadableAt: SourceTime?
  var restarted: Set<UInt64> = []
  var active: WriterCommand?
  var observedAudio: AudioReading?
  var debtBeforeActive = false
  var closing = false
  var restoreRequired = false
  var playOracle = PlayOracle()
  var notPlayingRemovals: Int { playOracle.suppressed }
  var context: ObservationContext? {
    guard let route, let connection else { return nil }
    return ObservationContext(
      routeEpoch: route.epoch, streamEpoch: streamEpoch, connectionEpoch: connection.epoch,
      deviceOrdinal: route.deviceOrdinal)
  }
  /// A new Mono, Stereo or Play needs the current route, a healthy stream and a known count.
  func baseAllows(_ expected: Set<Int>, context candidate: ObservationContext?) -> Bool {
    guard healthy, !failed, let context, candidate == context, let count else { return false }
    return expected.contains(count)
  }
  private mutating func resetCount() {
    count = nil
    lastState = nil
    unreadableAt = nil
  }
  private mutating func failStream(at now: Instant) {
    guard !failed else { return }
    failed = true
    healthy = false
    heartbeatDeadline = nil
    sent.removeAll()
    count = nil
    playOracle.resetPlayer(at: now.utc)
  }
  private mutating func recordRemoval(_ observation: Observation, at now: Instant) {
    guard observation.provenance == .live, observation.source == .m,
      case .transition(let from, let to) = observation.value, let context,
      observation.context == context, !failed, observation.sourceTime <= now.utc,
      observation.receivedContinuousNanos <= now.continuousNanos,
      observation.sourceTime >= streamStart,
      connection?.boundary.map({ observation.sourceTime > $0 }) ?? true
    else { return }
    playOracle.transition(
      from: from, to: to, time: observation.sourceTime, at: now)
  }
  private mutating func observe(_ observation: Observation, at now: Instant) {
    guard observation.provenance == .live, observation.source != .m,
      case .count(let value, _) = observation.value, let context, observation.context == context,
      !failed, observation.sourceTime <= now.utc,
      observation.receivedContinuousNanos <= now.continuousNanos,
      observation.sourceTime >= streamStart,
      connection?.boundary.map({ observation.sourceTime > $0 }) ?? true,
      lastState.map({ observation.sourceTime > $0 }) ?? true,
      unreadableAt.map({ observation.sourceTime > $0 }) ?? true,
      value.map({ (0...2).contains($0) }) ?? true
    else { return }
    lastState = observation.sourceTime
    if count == 2 && value == 1 {
      playOracle.countSignal(time: observation.sourceTime, at: now)
    }
    if value == nil || value == 0 { playOracle.cancel() }
    if value == nil { playOracle.forgetUserStop() }
    count = value
    unreadableAt = nil
  }
  private mutating func update(_ input: EngineInput, at now: Instant) {
    switch input {
    case .route(let value):
      guard value != route else { return }
      if let value {
        guard value.epoch > routeHighWater, value.deviceOrdinal > 0 else { return }
        routeHighWater = value.epoch
      }
      route = value
      connection = nil
      resetCount()
      playOracle.resetPlayer(at: now.utc)
      playOracle.resetObservations()
    case .connection(let value):
      guard route != nil, value.epoch > connectionHighWater,
        value.boundary.map({ $0 <= now.utc }) ?? true
      else { return }
      connectionHighWater = value.epoch
      connection = value
      resetCount()
      playOracle.resetObservations()
    case .streamStarted(let epoch, let value):
      guard epoch > streamEpoch, !value.isEmpty else { return }
      streamEpoch = epoch
      nonce = value
      streamStart = now.utc
      healthy = false
      failed = false
      lastHeartbeat = 0
      sent.removeAll()
      heartbeatDeadline = now.continuousNanos + 25_000_000_000
      resetCount()
      playOracle.resetPlayer(at: now.utc)
      playOracle.resetObservations(clearStatus: false)
    case .heartbeat(let epoch, let value, let sequence):
      guard epoch == streamEpoch, value == nonce, !failed, sequence > lastHeartbeat,
        let at = sent[sequence], now.continuousNanos >= at,
        now.continuousNanos - at < 25_000_000_000
      else { return }
      lastHeartbeat = sequence
      sent = sent.filter { $0.key > sequence }
      healthy = true
      heartbeatDeadline = now.continuousNanos + 25_000_000_000
    case .gap(let epoch, let reason, let time):
      guard epoch == streamEpoch else { return }
      count = nil
      playOracle.resetPlayer(at: now.utc)
      if reason == .sourceUnreadable {
        if let time, unreadableAt.map({ time > $0 }) ?? true { unreadableAt = time }
      } else {
        if reason == .clockChanged { lastState = nil }
        failStream(at: now)
      }
    case .observation(let observation):
      observe(observation, at: now)
      recordRemoval(observation, at: now)
    case .nowPlaying(let epoch, let playing, let time):
      if epoch == streamEpoch, !failed, time <= now.utc, time >= streamStart {
        playOracle.player(
          playing, time: time, at: now, allowed: baseAllows([1, 2], context: context))
      }
    case .pause(let time):
      playOracle.pause(time: time, at: now)
    case .streamFinished(let epoch):
      if epoch == streamEpoch { failStream(at: now) }
    case .audioObserved(let reading):
      if reading.valid, reading.generation > (observedAudio?.generation ?? 0) {
        observedAudio = reading
      }
    case .audioWriteSkipped(let command):
      if command == active {
        active = nil
        restoreRequired = debtBeforeActive
      }
    case .quit: closing = true
    case .writerCompleted(let receipt):
      guard receipt.command == active, receipt.quiescent, receipt.persisted else { return }
      active = nil
      let command = receipt.command
      restoreRequired = !(command.recovery && command.target == .stereo && receipt.exitCode == 0)
    default: return
    }
  }
  /// Applies one input and the actions the engine answered with; returns the first violation.
  mutating func apply(
    _ input: EngineInput, at now: Instant, actions: [EngineAction], engineCount: Int?
  ) -> String? {
    if let end = heartbeatDeadline, now.continuousNanos >= end { failStream(at: now) }
    playOracle.expire(at: now)
    update(input, at: now)
    playOracle.activateEntries(at: now, allowed: baseAllows([1, 2], context: context))
    var expected = playOracle.expected(
      input, at: now, allowed: baseAllows([1, 2], context: context))
    for action in actions {
      switch action {
      case .writeTarget(let command):
        if active != nil { return "concurrent writer" }
        if observedAudio?.systemMono == .on { return "writer during system override" }
        if command.recovery {
          if command.target != .stereo || (!restoreRequired && !closing) {
            return "recovery without restore"
          }
        } else if !baseAllows(command.target == .mono ? [1] : [0, 2], context: command.context) {
          return "writer without valid base"
        }
        debtBeforeActive = restoreRequired
        active = command
        restoreRequired = true
      case .play(let command):
        if !baseAllows([1, 2], context: command.context) { return "play without valid base" }
        if expected.remove(command.episode) == nil {
          return "Play without its eligible Pause/removal: episode \(command.episode)"
        }
      case .pause(let command):
        if !baseAllows([1, 2], context: command) { return "pause without valid base" }
        if playOracle.owedPauses == 0 && !playOracle.resumeNeedsStop {
          return "Pause without a stop of the user to protect"
        }
        playOracle.sentPause(at: now)
      case .persist:
        if active != nil { return "app persists during writer ownership" }
      case .restartStream(let epoch, _):
        if !restarted.insert(epoch).inserted { return "repeated restart" }
      case .emitHeartbeat(let epoch, _, let sequence):
        if epoch == streamEpoch { sent[sequence] = now.continuousNanos }
      default: break
      }
      playOracle.advanceID(after: action)
    }
    if !expected.isEmpty { return "missing legitimate Play for episodes \(expected.sorted())" }
    if playOracle.owedPauses != 0 { return "missing Pause at a protected entry" }
    if playOracle.resumeNeedsStop { return "system resume left playing inside protected entries" }
    if engineCount != count {
      return
        "count \(engineCount.map(String.init) ?? "nil") expected \(count.map(String.init) ?? "nil")"
    }
    return nil
  }
}
/// Independent, unbounded event ledger for Play decisions. Unlike Engine, this retains the
/// complete evidence and derives each removal's player state again at the decision instant.
/// IDs are allocated for accepted Pause/transition inputs and advanced by visible action IDs;
/// this lets the oracle check the exact episode, rather than any recent eligible removal.
struct PlayOracle {
  struct PlayerRow {
    var time: SourceTime
    var playing: Bool
    var order: Int
  }
  struct Signal {
    var time: SourceTime
    var arrival: UInt64
  }
  struct Removal {
    var id: UInt64
    var transition: Signal
    var count: Signal?
    var paired = false
  }
  struct Pause {
    var id: UInt64
    var time: SourceTime
    var start: UInt64
    var removal: Int?
    var due: UInt64?
    var waited = false
  }
  var nextID: UInt64 = 3
  var order = 0
  var rows: [PlayerRow] = []
  var barrier = instant(0).utc
  var counts: [Signal] = []
  var removals: [Removal] = []
  var pauses: [Pause] = []
  var lastTransition: SourceTime?
  var lastStatus: EarStatus?
  var suppressed = 0
  var permitted = 0
  /// Removals with an unknown player state that a stop released into a Play.
  var unknownReleased = 0
  /// Removals with an unknown player state that were due without a stop, so they had to wait.
  var unknownWaited = 0
  /// Every removal transition accepted since the start: never bounded, never reset by a barrier.
  var removalTimes: [SourceTime] = []
  /// Keep each entry separately in this unbounded ledger; never coalesce their protection or
  /// consume it when a resume is corrected. This checks the player's outcome for every entry.
  struct Entry {
    var time: SourceTime
    var arrived: Instant
    var inferredStop: Bool
    var decision: Bool?
  }
  var entries: [Entry] = []
  var resumeNeedsStop = false
  /// Receipts are matched to actual emitted commands, independently of entry protection.
  var sentPauses: [UInt64] = []
  /// A removal had its Pause and no row at all until the end of its episode.
  var stoppedAcrossRemoval = false
  /// Pauses that the actions of the current input must contain.
  var owedPauses = 0
  var interventions = 0
  var interventionsByDeduction = 0
  var declined = 0
  var resumesCaught = 0

  mutating func cancel() {
    counts.removeAll()
    removals.removeAll()
    pauses.removeAll()
  }
  mutating func resetPlayer(at time: SourceTime) {
    rows.removeAll()
    barrier = time
    cancel()
    forgetUserStop()
  }
  mutating func forgetUserStop() {
    entries.removeAll()
    resumeNeedsStop = false
    stoppedAcrossRemoval = false
  }
  mutating func resetObservations(clearStatus: Bool = true) {
    lastTransition = nil
    if clearStatus { lastStatus = nil }
    cancel()
    forgetUserStop()
  }
  mutating func player(_ playing: Bool, time: SourceTime, at now: Instant, allowed: Bool) {
    guard time > barrier else { return }
    let first = !rows.contains { $0.time == time }
    order += 1
    rows.append(PlayerRow(time: time, playing: playing, order: order))
    guard first else { return }
    stoppedAcrossRemoval = false
    guard playing, protected(time, at: now), allowed else { return }
    resumeNeedsStop = true
    resumesCaught += 1
  }
  private func within(_ entry: Entry, at now: Instant) -> Bool {
    now.utc.nanos - entry.time.nanos < 1_500_000_000
      && now.continuousNanos - entry.arrived.continuousNanos
        < UInt64(1_500_000_000 - (entry.arrived.utc.nanos - entry.time.nanos))
  }
  private func protected(_ time: SourceTime, at now: Instant) -> Bool {
    // Reconstruct coverage from the complete entry ledger on each query. Overlapping entry
    // intervals form a connected protection, including late rows from its earlier entries.
    let admitted = entries.filter { $0.decision == true }.sorted { $0.time < $1.time }
    for index in admitted.indices where within(admitted[index], at: now) {
      var first = admitted[index].time
      for previous in admitted[..<index].reversed() {
        if first.nanos - previous.time.nanos >= 1_500_000_000 { break }
        first = previous.time
      }
      if time >= first && time.nanos - admitted[index].time.nanos < 1_500_000_000 { return true }
    }
    return false
  }
  mutating func sentPause(at now: Instant) {
    if owedPauses > 0 { owedPauses -= 1 }
    resumeNeedsStop = false
    sentPauses.append(now.continuousNanos)
  }
  /// The rule over every row accepted since the barrier: the first accepted row with the greatest
  /// source time before the ear came in. No row at all needs the deduction from a removal.
  private func stoppedByUser(before time: SourceTime, inferredStop: Bool, now: Instant) -> Bool {
    guard
      let last = rows.filter({ $0.time < time })
        .sorted(by: { ($0.time, -$0.order) < ($1.time, -$1.order) }).last
    else { return inferredStop }
    if last.playing {
      return protected(last.time, at: now)
    }
    return !removalTimes.contains { $0 <= last.time && last.time.nanos - $0.nanos < 1_000_000_000 }
  }
  private mutating func earCameIn(at time: SourceTime, now: Instant) {
    guard now.utc.nanos - time.nanos < 1_500_000_000 else { return }
    entries.append(Entry(time: time, arrived: now, inferredStop: stoppedAcrossRemoval))
  }
  mutating func activateEntries(at now: Instant, allowed: Bool) {
    guard allowed else { return }
    for index in entries.indices
    where entries[index].decision == nil && within(entries[index], at: now) {
      let entry = entries[index]
      let stopped = stoppedByUser(before: entry.time, inferredStop: entry.inferredStop, now: now)
      entries[index].decision = stopped
      guard stopped else {
        declined += 1
        continue
      }
      if !rows.contains(where: { $0.time < entry.time }) { interventionsByDeduction += 1 }
      interventions += 1
      owedPauses += 1
      cancel()
      removalTimes.removeAll()
    }
  }
  /// The rule of the specification over every row accepted since the barrier, whatever the
  /// arrival order of rows and signals: the row with the greatest source time strictly before the
  /// first signal of the removal. For equal source times the first accepted row wins.
  func state(for removal: Removal) -> Bool? {
    let first = min(removal.transition.time, removal.count?.time ?? removal.transition.time)
    return rows.filter { $0.time < first }
      .sorted { ($0.time, -$0.order) < ($1.time, -$1.order) }.last?.playing
  }
  /// Whether a Not Playing row at or after the transition is accepted. Of the rows with one
  /// source time only the first accepted counts, whatever the arrival order of rows and signals.
  func stopped(for removal: Removal) -> Bool {
    return rows.contains { row in
      !row.playing && row.time >= removal.transition.time
        && !rows.contains { $0.time == row.time && $0.order < row.order }
    }
  }
  mutating func countSignal(time: SourceTime, at now: Instant) {
    let signal = Signal(time: time, arrival: now.continuousNanos)
    let eligible = removals.indices.filter { index in
      removals[index].count == nil
        && abs(removals[index].transition.time.nanos - time.nanos) < 3_000_000_000
        && (!removals[index].paired || pauses.contains { $0.removal == index })
    }
    if let index = eligible.min(by: {
      let left = abs(removals[$0].transition.time.nanos - time.nanos)
      let right = abs(removals[$1].transition.time.nanos - time.nanos)
      return (left, removals[$0].id) < (right, removals[$1].id)
    }) {
      removals[index].count = signal
    } else if lastTransition.map({ $0.nanos - time.nanos < 3_000_000_000 }) ?? true {
      counts.append(signal)
    }
  }
  mutating func transition(
    from: EarStatus, to: EarStatus, time: SourceTime, at now: Instant
  ) {
    guard lastTransition.map({ time > $0 }) ?? true else { return }
    lastTransition = time
    counts.removeAll { time.nanos - $0.time.nanos >= 3_000_000_000 }
    guard lastStatus != to else { return }
    lastStatus = to
    if [(EarStatus.both, EarStatus.one), (.one, .none), (.both, .none)].contains(where: {
      $0 == (from, to)
    }) {
      removalTimes.append(time)
    }
    if to == .none || to == .unknown { cancel() }
    if [(EarStatus.one, EarStatus.both), (.none, .one), (.none, .both)].contains(where: {
      $0 == (from, to)
    }) {
      earCameIn(at: time, now: now)
      return
    }
    guard from == .both, to == .one else { return }
    let signal = Signal(time: time, arrival: now.continuousNanos)
    var removal = Removal(id: nextID, transition: signal)
    nextID += 1
    if let index = counts.indices.filter({
      abs(counts[$0].time.nanos - time.nanos) < 3_000_000_000
    }).min(by: {
      (abs(counts[$0].time.nanos - time.nanos), $0)
        < (abs(counts[$1].time.nanos - time.nanos), $1)
    }) {
      removal.count = counts.remove(at: index)
    }
    removals.append(removal)
  }
  mutating func pause(time: SourceTime, at now: Instant) {
    guard time <= now.utc else { return }
    if !sentPauses.isEmpty {
      sentPauses.removeFirst()
      return
    }
    pauses.append(Pause(id: nextID, time: time, start: now.continuousNanos))
    nextID += 1
  }
  mutating func expire(at now: Instant) {
    let ended = pauses.filter { now.continuousNanos - $0.start >= 3_000_000_000 }
    if rows.isEmpty, ended.contains(where: { $0.due != nil }) { stoppedAcrossRemoval = true }
    pauses.removeAll { now.continuousNanos - $0.start >= 3_000_000_000 }
    sentPauses.removeAll { now.continuousNanos - $0 >= 500_000_000 }
  }
  /// A declarative matching over all surviving facts; the ledger never copies Engine snapshots.
  mutating func expected(_ input: EngineInput, at now: Instant, allowed: Bool) -> Set<UInt64> {
    if case .drain = input {
      var candidates: [(Int64, UInt64, UInt64, Int, Int)] = []
      for (p, pause) in pauses.enumerated() where pause.removal == nil {
        for (r, removal) in removals.enumerated() where !removal.paired {
          let delta = removal.transition.time.nanos - pause.time.nanos
          if (-3_000_000_000..<3_000_000_000).contains(delta) {
            candidates.append((abs(delta), pause.id, removal.id, p, r))
          }
        }
      }
      for candidate in candidates.sorted(by: { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }) {
        let (p, r) = (candidate.3, candidate.4)
        guard pauses[p].removal == nil, !removals[r].paired else { continue }
        pauses[p].removal = r
        pauses[p].due = max(pauses[p].start + 100_000_000, removals[r].transition.arrival)
        removals[r].paired = true
      }
    } else if case .tick = input {
      // Ticks dispatch already matched episodes only.
    } else {
      return []
    }
    var expected: Set<UInt64> = []
    var settled: Set<UInt64> = []
    for (position, pause) in pauses.enumerated()
    where pause.due.map({ $0 <= now.continuousNanos }) ?? false {
      guard let index = pause.removal else {
        settled.insert(pause.id)
        continue
      }
      let removal = removals[index]
      switch state(for: removal) {
      case .some(false):
        if allowed { suppressed += 1 }
      case .some(true):
        if allowed {
          expected.insert(pause.id)
          permitted += 1
        }
      case .none:
        // Unknown state: without a stop the Pause keeps waiting, whatever the base says.
        guard stopped(for: removal) else {
          if !pause.waited { unknownWaited += 1 }
          pauses[position].waited = true
          continue
        }
        if allowed {
          expected.insert(pause.id)
          unknownReleased += 1
        }
      }
      settled.insert(pause.id)
    }
    pauses.removeAll { settled.contains($0.id) }
    return expected
  }
  mutating func advanceID(after action: EngineAction) {
    let id: UInt64
    switch action {
    case .persist(let request): id = request.id
    case .queryHistory(let value, _): id = value
    case .writeTarget(let command): id = command.id
    case .play(let command): id = command.id
    default: return
    }
    nextID = max(nextID, id + 1)
  }
}

/// Draws one input from the hostile alphabet, aimed at the model's current epochs.
func scenarioInput(roll: (UInt64) -> UInt64, model: ReferenceModel, now: Instant) -> EngineInput {
  let current = model.context ?? .test
  func state(_ count: Int?, at time: SourceTime, context: ObservationContext) -> EngineInput {
    .observation(
      Observation(
        sourceTime: time, source: .s1, provenance: .live, context: context,
        receivedContinuousNanos: now.continuousNanos,
        value: .count(count, detection: count == nil ? .unknown : .on)))
  }
  /// A transition `back` nanoseconds old: bluetoothd rows can arrive after newer player rows.
  func transition(_ from: EarStatus, _ to: EarStatus, back: UInt64 = 0) -> EngineInput {
    .observation(
      Observation(
        sourceTime: instant(nanos: now.continuousNanos - back).utc, source: .m, provenance: .live,
        context: current, receivedContinuousNanos: now.continuousNanos,
        value: .transition(from: from, to: to)))
  }
  switch roll(39) {
  case 0..<10: return state(Int(roll(3)), at: now.utc, context: current)
  case 10, 11: return state(nil, at: now.utc, context: current)
  case 12..<15:
    let back = (1 + roll(80)) * 10_000_000
    return state(Int(roll(3)), at: instant(nanos: now.continuousNanos - back).utc, context: current)
  case 15, 16:
    var foreign = current
    if roll(2) == 0 { foreign.deviceOrdinal = 2 } else { foreign.connectionEpoch += 1_000 }
    return state(1, at: now.utc, context: foreign)
  case 17:
    let back = min(now.continuousNanos, roll(3) * 1_000_000_000)
    return .gap(
      epoch: model.streamEpoch, reason: .sourceUnreadable,
      faultTime: roll(3) == 0 ? nil : instant(nanos: now.continuousNanos - back).utc)
  case 18:
    if roll(3) == 0 { return .gap(epoch: model.streamEpoch, reason: .transport, faultTime: nil) }
    return .heartbeat(epoch: 999, nonce: "stale", sequence: 1 + roll(100))
  case 19: return .tick
  case 20:
    if roll(3) == 0 { return .route(nil) }
    return .route(Route(epoch: model.routeHighWater + 1, deviceOrdinal: 1))
  case 21, 22:
    return .connection(
      Connection(
        epoch: model.connectionHighWater + 1,
        boundary: instant(nanos: now.continuousNanos - 20_000_000).utc))
  case 23:
    return .streamStarted(epoch: model.streamEpoch + 1, nonce: "nonce-\(model.streamEpoch + 1)")
  case 24..<27:
    return .heartbeat(
      epoch: model.streamEpoch, nonce: model.nonce,
      sequence: model.sent.keys.max() ?? model.lastHeartbeat)
  case 27, 28: return .pause(now.utc)
  case 29, 30: return transition(.both, .one, back: roll(3) == 0 ? (1 + roll(80)) * 10_000_000 : 0)
  case 31: return transition(.one, .both)
  case 32: return transition(.none, .one)
  case 33: return transition(.none, .both)
  case 34: return transition(.both, .none)
  case 35: return transition(.one, .none)
  default:
    // Player rows: current, late, or from the future, and sometimes from another stream epoch.
    let time: SourceTime
    switch roll(4) {
    case 0:
      let back = min(now.continuousNanos, (1 + roll(80)) * 10_000_000)
      time = instant(nanos: now.continuousNanos - back).utc
    case 1: time = instant(nanos: now.continuousNanos + 1_000_000_000).utc
    default: time = now.utc
    }
    return .nowPlaying(
      epoch: roll(8) == 0 ? model.streamEpoch + 5 : model.streamEpoch, playing: roll(2) == 0,
      sourceTime: time)
  }
}
/// Replays the events on a fresh engine and a fresh model and returns the first violation.
func modelViolation(_ events: [ScenarioEvent]) -> (index: Int, message: String)? {
  var engine = readyEngine()
  var model = ReferenceModel()
  for (index, event) in events.enumerated() {
    let actions = engine.handle(input: event.input, at: event.time)
    if let violation = model.apply(
      event.input, at: event.time, actions: actions, engineCount: engine.snapshot.count)
    {
      return (index, violation)
    }
  }
  return nil
}
/// Deletion reduction preserves the original inputs and times. It runs only on failure,
/// on the prefix that ends at the violation, in one pass.
func reducedCounterexample(_ original: [ScenarioEvent]) -> [ScenarioEvent] {
  guard let first = modelViolation(original) else { return original }
  var events = Array(original[...first.index])
  var index = 0
  while index < events.count {
    var candidate = events
    candidate.remove(at: index)
    if modelViolation(candidate) != nil {
      events = candidate
    } else {
      index += 1
    }
  }
  return events
}
