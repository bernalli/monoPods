import Foundation

public struct AcceptanceSelection: Codable, Equatable, Sendable {
  public var build: String
  public var from: SourceTime
  public var to: SourceTime
  public init(build: String, from: SourceTime, to: SourceTime) {
    self.build = build
    self.from = from
    self.to = to
  }
}
public enum Verdict: String, Codable, Sendable {
  case fail = "FAIL"
  case insufficient = "INSUFFICIENT"
  case observedWithLimits = "OBSERVED_WITH_LIMITS"
}
public enum ReportIssue: String, Codable, Sendable {
  case invalidSelection, malformedRecord, incompleteSegment, duplicateSequence, sequenceGap,
    nonMonotonicTime, mixedBuild
  case missingActions, actionMismatch, orphanCompletion, concurrentWriter, receiptMismatch,
    uncertainEffect, commandError
  case invalidPlay, invalidHeartbeat, missingCoverage
}
public struct ReportMetrics: Codable, Equatable, Sendable {
  public var unknownNanos: UInt64 = 0
  public var gaps: UInt64 = 0
  public var missingSnapshots: UInt64 = 0
  public var playOmissions: UInt64 = 0
  public var matchedEpisodes: UInt64 = 0
  public var monoCompletions: UInt64 = 0
  public var stereoCompletions: UInt64 = 0
  public var recoveryCommands: UInt64 = 0
  public var notices: UInt64 = 0
  public var heartbeatLatenciesNanos: [UInt64] = []
  public var pauseToPlayNanos: [UInt64] = []
}
public struct Premise: Codable, Equatable, Sendable {
  public var id: String
  public var state: String
}
public struct Report: Codable, Equatable, Sendable {
  public var v = 1
  public var selection: AcceptanceSelection
  public var verdict: Verdict
  public var issues: [ReportIssue]
  public var metrics: ReportMetrics
  public var verifiedEffects: UInt64
  public var unverified: [String]
  public var premises: [Premise]
  public var exitCode: Int32 {
    switch verdict {
    case .fail: 1
    case .insufficient: 2
    case .observedWithLimits: 0
    }
  }
  public static func decode(_ data: Data) throws -> Self {
    let value = try ContractValidation.decode(Self.self, data: data)
    guard value.v == 1, value.selection.from < value.selection.to,
      ContractValidation.hash(value.selection.build),
      value.premises.count == 11, value.premises.map(\.id) == (1...11).map({ "N\($0)" }),
      value.premises.allSatisfy({ ["OBSERVED", "NON_VERIFIED", "FAILED"].contains($0.state) }),
      Set(value.unverified).isSubset(of: Set(EvidenceKind.allNames))
    else { throw ContractError.invalid }
    return value
  }
}
extension EvidenceKind {
  fileprivate static let allNames = [
    "effectiveMono", "audiblePlayback", "acousticLatency", "lastEar", "voluntaryPause", "otherApps",
    "otherModels", "powerUse",
  ]
}
public struct TraceDecodeResult: Sendable {
  public var records: [TraceRecord]
  public var complete: Bool
  public var malformed: Bool
}
public enum LogReport {
  public static func decodeJSONL(_ data: Data) -> TraceDecodeResult {
    var records: [TraceRecord] = []
    var malformed = false
    let complete = data.isEmpty || data.last == 10
    let lines = data.split(separator: 10, omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
      if index == lines.count - 1 { continue }
      do { records.append(try TraceRecord.decode(Data(line))) } catch { malformed = true }
    }
    return TraceDecodeResult(
      records: records, complete: complete && !malformed, malformed: malformed)
  }
  public static func evaluate(records: [TraceRecord], selection: AcceptanceSelection) -> Report {
    var evaluator = Evaluator(selection: selection)
    guard selection.from < selection.to, ContractValidation.hash(selection.build) else {
      evaluator.errors.insert(.invalidSelection)
      return evaluator.report()
    }
    for record in records { evaluator.consume(record) }
    return evaluator.report()
  }
}
private struct IndependentPause {
  var source: SourceTime
  var continuous: UInt64
  var used = false
}
private struct IndependentTransition {
  var observation: Observation
  var used = false
}
private struct RunEvaluation {
  var engine: Engine
  var lastSequence: UInt64
  var lastM: UInt64
  var ended = false
  var expected: [EngineAction]?
  var writer: WriterCommand?
  var startup = false
  var context: ObservationContext?
  var route: Route?
  var connection: Connection?
  var streamEpoch: UInt64 = 0
  var streamStart: SourceTime?
  var streamNonce = ""
  var heartbeatHighWater: UInt64 = 0
  var heartbeats: [UInt64: UInt64] = [:]
  var pauses: [IndependentPause] = []
  var transitions: [IndependentTransition] = []
  var lastTransitionTime: SourceTime?
  var lastTransitionStatus: EarStatus?
  var lastOwnPause: UInt64?
}
private struct Evaluator {
  let selection: AcceptanceSelection
  var runs: [UInt64: RunEvaluation] = [:]
  var errors: Set<ReportIssue> = []
  var incomplete: Set<ReportIssue> = []
  var metrics = ReportMetrics()
  var evidence: Set<EvidenceKind> = []
  var effects: UInt64 = 0
  var operationalStartup = false
  var streamReadable = false
  var historyReadable = false
  var recordBuilds: [UInt64: String] = [:]

  mutating func consume(_ record: TraceRecord) {
    guard record.payload.utc >= selection.from, record.payload.utc < selection.to else { return }
    if let old = recordBuilds[record.run], old != record.build,
      old == selection.build || record.build == selection.build
    {
      errors.insert(.mixedBuild)
    }
    recordBuilds[record.run] = record.build
    guard record.build == selection.build else { return }
    guard record.valid else {
      errors.insert(.malformedRecord)
      return
    }
    if case .launch(let payload) = record.payload {
      guard runs[record.run] == nil else {
        incomplete.insert(.duplicateSequence)
        return
      }
      if record.seq != 1 { incomplete.insert(.sequenceGap) }
      runs[record.run] = RunEvaluation(
        engine: Engine(build: record.build, run: record.run, boot: payload.boot),
        lastSequence: record.seq, lastM: record.m)
      return
    }
    guard var state = runs[record.run] else {
      incomplete.insert(.incompleteSegment)
      return
    }
    guard !state.ended else {
      errors.insert(.malformedRecord)
      return
    }
    guard record.seq > state.lastSequence else {
      incomplete.insert(.duplicateSequence)
      return
    }
    if state.lastSequence == UInt64.max || record.seq != state.lastSequence + 1 {
      incomplete.insert(.sequenceGap)
    }
    guard record.m >= state.lastM else {
      errors.insert(.nonMonotonicTime)
      return
    }
    if state.engine.snapshot.count == nil { add(record.m - state.lastM, to: \.unknownNanos) }
    state.lastSequence = record.seq
    state.lastM = record.m
    switch record.payload {
    case .launch: break
    case .input(let payload):
      if state.expected != nil { incomplete.insert(.missingActions) }
      inspect(payload.input, record: record, state: &state)
      state.expected = state.engine.handle(
        input: payload.input, at: Instant(continuousNanos: record.m, utc: payload.utc))
      if state.engine.snapshot.operational {
        state.startup = true
        operationalStartup = true
      }
    case .actions(let payload):
      if state.expected != payload.actions { errors.insert(.actionMismatch) }
      state.expected = nil
      for action in payload.actions { inspect(action, record: record, state: &state) }
    case .evidence(let payload):
      if payload.verified {
        evidence.insert(payload.kind)
        if payload.kind == .streamAccessible {
          streamReadable = true
        } else if payload.kind == .historyAccessible {
          historyReadable = true
        } else {
          effects += 1
        }
      } else {
        errors.insert(.commandError)
      }
    case .end(let payload):
      state.ended = true
      if state.expected != nil { incomplete.insert(.missingActions) }
      if state.writer != nil { errors.insert(.uncertainEffect) }
      if payload.exitCode != 0 { errors.insert(.commandError) }
    }
    runs[record.run] = state
  }
  mutating func inspect(_ input: EngineInput, record: TraceRecord, state: inout RunEvaluation) {
    switch input {
    case .route(let route):
      if state.route != route {
        state.connection = nil
        state.context = nil
        state.lastTransitionStatus = nil
        state.lastTransitionTime = nil
      }
      state.route = route
    case .connection(let connection):
      state.connection = connection
      state.lastTransitionStatus = nil
      state.lastTransitionTime = nil
      refreshContext(state: &state)
    case .streamStarted(let epoch, let nonce):
      if epoch > state.streamEpoch {
        state.streamEpoch = epoch
        state.streamNonce = nonce
        state.streamStart = record.payload.utc
        state.heartbeats.removeAll()
        state.heartbeatHighWater = 0
        refreshContext(state: &state)
      }
    case .observation(let observation):
      if observation.source == .m, observation.provenance == .live,
        observation.context == state.context,
        observation.sourceTime <= record.payload.utc,
        observation.receivedContinuousNanos <= record.m,
        state.streamStart.map({ observation.sourceTime >= $0 }) ?? false,
        state.connection?.boundary.map({ observation.sourceTime > $0 }) ?? false,
        state.lastTransitionTime.map({ observation.sourceTime > $0 }) ?? true,
        case .transition(let from, let to) = observation.value
      {
        state.lastTransitionTime = observation.sourceTime
        if state.lastTransitionStatus != to {
          state.lastTransitionStatus = to
          if from == .both && to == .one {
            state.transitions.append(IndependentTransition(observation: observation))
          }
        }
      }
    case .pause(let source):
      // The echo of a Pause of the app is not a removal that can miss its Play.
      if let own = state.lastOwnPause, record.m - own < UInt64(Engine.pauseGuardWindow) { break }
      state.pauses.append(IndependentPause(source: source, continuous: record.m))
    case .audioWriteSkipped(let command):
      guard let writer = state.writer else {
        errors.insert(.orphanCompletion)
        return
      }
      guard writer == command else {
        errors.insert(.receiptMismatch)
        return
      }
      state.writer = nil
    case .writerCompleted(let receipt):
      guard let writer = state.writer else {
        errors.insert(.orphanCompletion)
        return
      }
      guard writer == receipt.command else {
        errors.insert(.receiptMismatch)
        return
      }
      state.writer = nil
      if !receipt.quiescent || !receipt.persisted { errors.insert(.uncertainEffect) }
      if receipt.exitCode != 0 {
        errors.insert(.commandError)
      } else if writer.target == .mono {
        add(1, to: \.monoCompletions)
      } else {
        add(1, to: \.stereoCompletions)
      }
    case .gap: add(1, to: \.gaps)
    case .history(_, _, let observation, let complete):
      if !complete || observation == nil { add(1, to: \.missingSnapshots) }
    case .heartbeat(let epoch, let nonce, let sequence):
      if epoch == state.streamEpoch, nonce == state.streamNonce,
        sequence > state.heartbeatHighWater,
        let sent = state.heartbeats[sequence], record.m >= sent, record.m - sent < 25_000_000_000
      {
        metrics.heartbeatLatenciesNanos.append(record.m - sent)
        state.heartbeatHighWater = sequence
        state.heartbeats = state.heartbeats.filter { $0.key > sequence }
      }
    case .playCompleted(_, _, let accepted): if !accepted { errors.insert(.commandError) }
    case .persistenceAcknowledged(_, _, let success):
      if !success { errors.insert(.commandError) }
    default: break
    }
  }
  mutating func inspect(_ action: EngineAction, record: TraceRecord, state: inout RunEvaluation) {
    switch action {
    case .writeTarget(let command):
      if state.writer != nil { errors.insert(.concurrentWriter) }
      state.writer = command
      if command.recovery { add(1, to: \.recoveryCommands) }
    case .play:
      var pairs: [(Int64, Int, Int)] = []
      for (i, pause) in state.pauses.enumerated() where !pause.used {
        guard record.m >= pause.continuous, record.m - pause.continuous >= 100_000_000,
          record.m - pause.continuous < 3_000_000_000
        else { continue }
        for (j, transition) in state.transitions.enumerated() where !transition.used {
          let distance = transition.observation.sourceTime.nanos - pause.source.nanos
          if distance >= -3_000_000_000, distance < 3_000_000_000,
            transition.observation.context == state.context
          {
            pairs.append((abs(distance), i, j))
          }
        }
      }
      if let pair = pairs.min(by: { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }) {
        state.pauses[pair.1].used = true
        state.transitions[pair.2].used = true
        metrics.pauseToPlayNanos.append(record.m - state.pauses[pair.1].continuous)
        add(1, to: \.matchedEpisodes)
      } else {
        errors.insert(.invalidPlay)
      }
    case .pause: state.lastOwnPause = record.m
    case .emitHeartbeat(let epoch, let nonce, let sequence):
      if epoch != state.streamEpoch || nonce != state.streamNonce || sequence == 0
        || state.heartbeats[sequence] != nil
      {
        errors.insert(.invalidHeartbeat)
      } else {
        state.heartbeats[sequence] = record.m
      }
    case .showNotice(let notice):
      add(1, to: \.notices)
      if [
        .persistenceFailed, .recoveryBlocked, .commandFailed,
      ].contains(notice) {
        errors.insert(.commandError)
      }
    default: break
    }
  }
  func refreshContext(state: inout RunEvaluation) {
    guard let route = state.route, let connection = state.connection, state.streamEpoch > 0 else {
      state.context = nil
      return
    }
    state.context = ObservationContext(
      routeEpoch: route.epoch, streamEpoch: state.streamEpoch,
      connectionEpoch: connection.epoch, deviceOrdinal: route.deviceOrdinal)
  }
  mutating func add(_ value: UInt64, to field: WritableKeyPath<ReportMetrics, UInt64>) {
    let (sum, overflow) = metrics[keyPath: field].addingReportingOverflow(value)
    metrics[keyPath: field] = sum
    if overflow { errors.insert(.malformedRecord) }
  }
  mutating func report() -> Report {
    for run in runs.values {
      if !run.ended || run.expected != nil { incomplete.insert(.incompleteSegment) }
      add(UInt64(run.pauses.filter { !$0.used }.count), to: \.playOmissions)
    }
    if !operationalStartup || !streamReadable || !historyReadable
      || metrics.matchedEpisodes < 5
      || metrics.monoCompletions < 3 || metrics.stereoCompletions < 3
      || metrics.recoveryCommands < 1
    {
      incomplete.insert(.missingCoverage)
    }
    let verdict: Verdict =
      !errors.isEmpty ? .fail : (incomplete.isEmpty ? .observedWithLimits : .insufficient)
    let issues = errors.union(incomplete).sorted { $0.rawValue < $1.rawValue }
    let unverified = EvidenceKind.allNames.filter {
      !evidence.contains(EvidenceKind(rawValue: $0)!)
    }
    let premises = (1...11).map { id in
      Premise(
        id: "N\(id)",
        state: id == 1 && streamReadable && historyReadable ? "OBSERVED" : "NON_VERIFIED")
    }
    return Report(
      selection: selection, verdict: verdict, issues: issues, metrics: metrics,
      verifiedEffects: effects, unverified: unverified, premises: premises)
  }
}
