import Foundation
import Testing

@testable import MonoPodsCore

@Test func journalDecoderRejectsMissingExtraDuplicateAndImpossiblePhase() throws {
  let valid = Data(
    #"""
    {"v":1,"lifecycle":{"run":1,"build":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","closedCleanly":true,"exitReason":null,"noticePending":false},
    "audio":{"initial":"unknown","recoveryTarget":"stereo","nextId":1,"restoreRequired":false,"phase":"idle","active":null,"lastCompleted":null}}
    """#
    .utf8)
  #expect(try JournalRecord.decode(valid).audio.restoreRequired == false)
  for end in 0..<valid.count {
    #expect(throws: (any Error).self) { try JournalRecord.decode(valid.prefix(end)) }
  }
  let text = try #require(String(data: valid, encoding: .utf8))
  for mutation in [
    text.replacingOccurrences(of: "\"v\":1", with: "\"v\":true"),
    text.replacingOccurrences(of: "\"v\":1", with: "\"v\":2"),
    text.replacingOccurrences(of: "\"v\":1", with: "\"v\":1,\"v\":1"),
    text.replacingOccurrences(of: "\"active\":null,", with: ""),
    text.replacingOccurrences(of: "\"phase\":\"idle\"", with: "\"phase\":\"running\""),
    text.replacingOccurrences(of: "\"nextId\":1", with: "\"nextId\":18446744073709551616"),
    text.replacingOccurrences(of: "\"nextId\":1", with: "\"nextId\":1.0"),
    text.replacingOccurrences(
      of: "\"noticePending\":false", with: "\"noticePending\":false,\"extra\":0"),
    // The supervision fields of earlier builds are no longer part of the journal.
    text.replacingOccurrences(
      of: "\"lastCompleted\":null}}",
      with: "\"lastCompleted\":null},\"drill\":{\"relaunchDrillBuild\":null,"
        + "\"pending\":null,\"result\":\"notRun\"}}"),
    text.replacingOccurrences(of: "\"exitReason\":null", with: "\"exitReason\":\"handover\""),
    text.replacingOccurrences(
      of: "\"exitReason\":null", with: "\"exitReason\":\"relaunchDrill\""),
  ] {
    #expect(throws: (any Error).self) { try JournalRecord.decode(Data(mutation.utf8)) }
  }
}
func selection() -> AcceptanceSelection {
  AcceptanceSelection(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", from: instant(0).utc,
    to: instant(59).utc)
}
func launchTrace() -> TraceRecord {
  TraceRecord(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", run: 1, seq: 1, m: 0,
    payload: .launch(
      LaunchPayload(
        utc: instant(0).utc, boot: "00000000-0000-4000-8000-000000000001")))
}
@Test func incompleteAndWrongBuildNeverProduceObservedVerdict() {
  let empty = LogReport.evaluate(records: [], selection: selection())
  #expect(empty.verdict == .insufficient)
  #expect(empty.exitCode == 2)
  let launch = launchTrace()
  #expect(
    LogReport.evaluate(records: [launch, launch], selection: selection()).verdict == .insufficient)
  var wrong = launch
  wrong.build = "another-build"
  #expect(LogReport.evaluate(records: [wrong], selection: selection()).verdict == .insufficient)
  let invalid = AcceptanceSelection(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", from: instant(2).utc,
    to: instant(1).utc)
  #expect(LogReport.evaluate(records: [launch], selection: invalid).exitCode == 1)
}
@Test func orphanCompletionAndActionMismatchFailIndependentOfCoverage() {
  let command = WriterCommand(run: 1, id: 7, context: .test, target: .mono, recovery: false)
  let receipt = WriterReceipt(command: command, exitCode: 0, quiescent: true, persisted: true)
  let orphan = TraceRecord(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", run: 1, seq: 2,
    m: 1_000_000_000,
    payload: .input(InputPayload(utc: instant(1).utc, input: .writerCompleted(receipt))))
  #expect(
    LogReport.evaluate(records: [launchTrace(), orphan], selection: selection()).exitCode == 1)
  let fake = TraceRecord(
    build: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", run: 1, seq: 2,
    m: 1_000_000_000,
    payload: .actions(ActionsPayload(utc: instant(1).utc, actions: [.writeTarget(command)])))
  #expect(LogReport.evaluate(records: [launchTrace(), fake], selection: selection()).exitCode == 1)
}
@Test func exitZeroReceiptDoesNotProveAudioEffect() {
  let report = LogReport.evaluate(records: [launchTrace()], selection: selection())
  #expect(report.unverified.contains("effectiveMono"))
  #expect(report.unverified.contains("audiblePlayback"))
  #expect(report.verifiedEffects == 0)
}
@Test func traceStrictnessAndJSONLTruncationAreNotSilent() throws {
  let data = try JSONEncoder().encode(launchTrace())
  _ = try TraceRecord.decode(data)
  let text = try #require(String(data: data, encoding: .utf8))
  #expect(throws: (any Error).self) {
    try TraceRecord.decode(Data(text.dropLast().appending(",\"extra\":0}").utf8))
  }
  #expect(throws: (any Error).self) {
    try TraceRecord.decode(
      Data(text.replacingOccurrences(of: "\"seq\":1", with: "\"seq\":true").utf8))
  }
  #expect(throws: (any Error).self) {
    try TraceRecord.decode(Data(text.replacingOccurrences(of: "\"seq\":1", with: "\"seq\":0").utf8))
  }
  let truncated = LogReport.decodeJSONL(data)
  #expect(!truncated.complete)
  let complete = LogReport.decodeJSONL(data + Data([10]))
  #expect(complete.complete)
  #expect(complete.records.count == 1)
}

@Test func preferencesSavedWithAutomationOffResumeAutomationAndKeepTheOtherSettings() throws {
  // A file written by 1.0.0 after the user turned Automatic Mono/Stereo off.
  let saved = #"{"v":1,"automationEnabled":false,"menuBarVisible":false,"launchAtLogin":false}"#
  let decoded = try ControlPreferences.decode(Data(saved.utf8))
  #expect(!decoded.automationEnabled)
  let migrated = decoded.migrated()
  #expect(migrated.automationEnabled)
  #expect(!migrated.menuBarVisible)
  #expect(!migrated.launchAtLogin)
  #expect(migrated.v == 1)
  // The migrated file is still one that 1.0.0 reads.
  #expect(try ControlPreferences.decode(JSONEncoder().encode(migrated)) == migrated)
  #expect(ControlPreferences().migrated() == ControlPreferences())
}

@Test func heartbeatAndControlSchemasRejectNumericBooleansUnknownKeysAndLateReceipts() throws {
  let control =
    #"{"v":1,"automationEnabled":true,"menuBarVisible":false,"launchAtLogin":false}"#
  let decoded = try ControlPreferences.decode(Data(control.utf8))
  #expect(decoded.automationEnabled)
  #expect(!decoded.launchAtLogin)
  #expect(ControlPreferences().launchAtLogin)
  for bad in [
    control.replacingOccurrences(of: "\"automationEnabled\":true", with: "\"automationEnabled\":1"),
    control.replacingOccurrences(of: ",\"launchAtLogin\":false", with: ""),
    control.replacingOccurrences(of: "\"launchAtLogin\":false", with: "\"launchAtLogin\":1"),
    control.replacingOccurrences(of: "\"launchAtLogin\":false", with: "\"launchAtLogin\":null"),
    control.replacingOccurrences(of: "false}", with: "false,\"extra\":true}"),
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try ControlPreferences.decode(Data(bad.utf8)) }
  }
  let heartbeat =
    #"{"v":1,"epoch":1,"nonce":"nonce","sequence":1,"issuedContinuousNanos":0,"receivedContinuousNanos":24999999999}"#
  #expect(try HeartbeatRecord.decode(Data(heartbeat.utf8)).sequence == 1)
  for bad in [
    heartbeat.replacingOccurrences(of: "24999999999", with: "25000000000"),
    heartbeat.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":true"),
    heartbeat.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":18446744073709551616"),
    heartbeat.replacingOccurrences(of: "\"epoch\":1", with: "\"epoch\":0"),
  ] {
    #expect(throws: (any Error).self) { try HeartbeatRecord.decode(Data(bad.utf8)) }
  }
}

private struct TraceHarness {
  let hash = String(repeating: "a", count: 64)
  let boot = "00000000-0000-4000-8000-000000000001"
  var engine: Engine
  var run: UInt64
  var sequence: UInt64 = 0
  var records: [TraceRecord] = []
  var journal: JournalRecord?
  var answerWrites = true
  init(run: UInt64, now: Instant) {
    self.run = run
    engine = Engine(build: hash, run: run, boot: boot)
    append(.launch(LaunchPayload(utc: now.utc, boot: boot)), at: now)
  }
  mutating func append(_ payload: TracePayload, at now: Instant) {
    sequence += 1
    records.append(
      TraceRecord(build: hash, run: run, seq: sequence, m: now.continuousNanos, payload: payload))
  }
  mutating func send(_ input: EngineInput, at now: Instant) {
    append(.input(InputPayload(utc: now.utc, input: input)), at: now)
    let actions = engine.handle(input: input, at: now)
    append(.actions(ActionsPayload(utc: now.utc, actions: actions)), at: now)
    for action in actions {
      switch action {
      case .persist(let request):
        journal = request.record
        send(.persistenceAcknowledged(run: run, id: request.id, success: true), at: now)
        if request.record.audio.phase == .prepared { send(.drain, at: now) }
      case .writeTarget(let command):
        guard answerWrites else { continue }
        send(
          .writerCompleted(
            WriterReceipt(command: command, exitCode: 0, quiescent: true, persisted: true)), at: now
        )
      case .emitHeartbeat(let epoch, let nonce, let sequence):
        send(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence), at: now)
      case .play(let command):
        send(.playCompleted(run: run, id: command.id, accepted: true), at: now)
      case .terminate(let code): append(.end(EndPayload(utc: now.utc, exitCode: code)), at: now)
      default: break
      }
    }
  }
}
private func completeTrace(
  beforeQuit: (inout TraceHarness) -> Void = { _ in }, quitAt: UInt64 = 13
) throws -> [TraceRecord] {
  var first = TraceHarness(run: 1, now: instant(0))
  first.send(.audioObserved(audioReading(1)), at: instant(0))
  first.send(.journalLoaded(.missing), at: instant(0))
  first.send(.quit(.user), at: instant(0))
  first.send(.drain, at: instant(0))
  let journal = try #require(first.journal)
  #expect(journal.lifecycle.closedCleanly)
  var second = TraceHarness(run: 2, now: instant(1))
  second.send(.journalLoaded(.record(journal)), at: instant(1))
  second.send(.route(Route(epoch: 1, deviceOrdinal: 1)), at: instant(1))
  second.send(.connection(Connection(epoch: 1, boundary: instant(0).utc)), at: instant(1))
  second.send(.streamStarted(epoch: 1, nonce: "nonce"), at: instant(1))
  second.send(
    .audioObserved(AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)),
    at: instant(1))
  second.send(.sentinelAvailable(true), at: instant(1))
  for kind in [EvidenceKind.streamAccessible, .historyAccessible] {
    second.append(
      .evidence(
        EvidencePayload(
          utc: instant(1).utc, kind: kind, verified: true,
          evidenceHash: String(repeating: "b", count: 64))), at: instant(1))
  }
  // The player is known to be playing before every removal below, count signals included.
  let playing = instant(1, fraction: 500_000_000)
  second.send(.nowPlaying(epoch: 1, playing: true, sourceTime: playing.utc), at: playing)
  for seconds in 2...7 {
    second.send(
      .observation(observation(seconds.isMultiple(of: 2) ? 1 : 2, at: UInt64(seconds))),
      at: instant(UInt64(seconds)))
    second.send(.drain, at: instant(UInt64(seconds)))
  }
  for seconds in UInt64(8)...12 {
    second.send(.pause(instant(seconds).utc), at: instant(seconds))
    let transition = Observation(
      sourceTime: instant(seconds).utc, source: .m, provenance: .live, context: .test,
      receivedContinuousNanos: seconds * 1_000_000_000, value: .transition(from: .both, to: .one))
    second.send(.observation(transition), at: instant(seconds))
    second.send(.drain, at: instant(seconds))
    second.send(.tick, at: instant(seconds, fraction: 100_000_000))
    var intermediate = transition
    intermediate.sourceTime = instant(seconds, fraction: 500_000_000).utc
    intermediate.receivedContinuousNanos += 500_000_000
    intermediate.value = .transition(from: .one, to: .both)
    second.send(.observation(intermediate), at: instant(seconds, fraction: 500_000_000))
  }
  beforeQuit(&second)
  second.send(.quit(.user), at: instant(quitAt))
  second.send(.drain, at: instant(quitAt))
  return first.records + second.records
}
@Test func completeObservableContractStillNamesUnverifiedAudioEffects() throws {
  let records = try completeTrace()
  let report = LogReport.evaluate(records: records, selection: selection())
  #expect(report.verdict == .observedWithLimits, "\(report.issues)")
  #expect(report.exitCode == 0)
  #expect(report.metrics.monoCompletions == 3)
  #expect(report.metrics.stereoCompletions == 5)
  #expect(report.metrics.matchedEpisodes == 5)
  #expect(report.metrics.recoveryCommands == 2)
  #expect(
    report.metrics.pauseToPlayNanos == [
      100_000_000, 100_000_000, 100_000_000, 100_000_000, 100_000_000,
    ])
  #expect(report.verifiedEffects == 0)
  #expect(report.unverified.contains("effectiveMono"))
  _ = try Report.decode(JSONEncoder().encode(report))
  for record in records { _ = try TraceRecord.decode(JSONEncoder().encode(record)) }
}
@Test func removingRecordsCannotImproveAcceptance() throws {
  let records = try completeTrace()
  for index in records.indices {
    var reduced = records
    reduced.remove(at: index)
    #expect(
      LogReport.evaluate(records: reduced, selection: selection()).verdict != .observedWithLimits,
      "missing record \(index)")
  }
}
/// A user stop, then a removal without a Pause of macOS, then an ear back in with the echo of the
/// Pause of the app.
private func undoneResume(_ harness: inout TraceHarness) {
  func transition(_ from: EarStatus, _ to: EarStatus, at seconds: UInt64) -> EngineInput {
    .observation(
      Observation(
        sourceTime: instant(seconds).utc, source: .m, provenance: .live, context: .test,
        receivedContinuousNanos: seconds * 1_000_000_000, value: .transition(from: from, to: to)))
  }
  let stop = instant(14)
  harness.send(.nowPlaying(epoch: 1, playing: false, sourceTime: stop.utc), at: stop)
  harness.send(transition(.both, .one, at: 15), at: instant(15))
  harness.send(transition(.one, .both, at: 16), at: instant(16))
  let echo = instant(16, fraction: 20_000_000)
  harness.send(.pause(echo.utc), at: echo)
  harness.send(.drain, at: echo)
}
@Test func aPauseOfTheAppKeepsTheReportValid() throws {
  let records = try completeTrace(beforeQuit: undoneResume, quitAt: 17)
  let actions = records.flatMap { record -> [EngineAction] in
    if case .actions(let payload) = record.payload { payload.actions } else { [] }
  }
  #expect(actions.contains(.pause(context: .test)))
  let report = LogReport.evaluate(records: records, selection: selection())
  #expect(report.verdict == .observedWithLimits, "\(report.issues)")
  #expect(report.metrics.matchedEpisodes == 5)
  // The echo of the app's own Pause is not a removal that went without its Play.
  #expect(report.metrics.playOmissions == 0)
  _ = try Report.decode(JSONEncoder().encode(report))
  for record in records { _ = try TraceRecord.decode(JSONEncoder().encode(record)) }
}
@Test func aSystemPauseAfterTheEchoWindowStillCountsAsAnOmission() throws {
  let records = try completeTrace(
    beforeQuit: { harness in
      undoneResume(&harness)
      let late = instant(18)
      harness.send(.pause(late.utc), at: late)
    }, quitAt: 19)
  let report = LogReport.evaluate(records: records, selection: selection())
  #expect(report.metrics.playOmissions == 1)
}
@Test func thePauseActionFollowsTheStrictContract() throws {
  let hash = String(repeating: "a", count: 64)
  let record = TraceRecord(
    build: hash, run: 1, seq: 2, m: 1_000_000_000,
    payload: .actions(ActionsPayload(utc: instant(1).utc, actions: [.pause(context: .test)])))
  let data = try JSONEncoder().encode(record)
  #expect(try TraceRecord.decode(data) == record)
  let noRoute = ObservationContext(
    routeEpoch: 0, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1)
  var invalid = record
  invalid.payload = .actions(
    ActionsPayload(utc: instant(1).utc, actions: [.pause(context: noRoute)]))
  #expect(throws: (any Error).self) { try TraceRecord.decode(JSONEncoder().encode(invalid)) }
}
/// Rows of a build without the Pause action, written out by hand: the format must stay readable.
@Test func tracesWrittenBeforeThePauseActionAreStillRead() throws {
  let hash = String(repeating: "a", count: 64)
  let context = #"{"routeEpoch":1,"streamEpoch":1,"connectionEpoch":1,"deviceOrdinal":1}"#
  let time = "2001-01-01T00:00:01.000000000Z"
  let play =
    #"{"v":1,"build":"\#(hash)","run":1,"seq":2,"m":1000000000,"event":"actions","#
    + #""payload":{"utc":"\#(time)","actions":[{"play":{"_0":{"run":1,"id":3,"episode":2,"#
    + #""context":\#(context),"command":0}}}]}}"#
  let pause =
    #"{"v":1,"build":"\#(hash)","run":1,"seq":3,"m":1000000000,"event":"input","#
    + #""payload":{"engine":{"_0":{"utc":"\#(time)","input":{"pause":{"_0":"\#(time)"}}}}}}"#
  let decoded = LogReport.decodeJSONL(Data((play + "\n" + pause + "\n").utf8))
  #expect(decoded.complete)
  #expect(decoded.records.count == 2)
}

@Test func reportCorrelatesSkipsWithoutCountingThemAsAudioCompletions() throws {
  var trace = TraceHarness(run: 1, now: instant(0))
  trace.answerWrites = false
  for input: EngineInput in [
    .audioObserved(audioReading(1)), .journalLoaded(.missing),
    .route(Route(epoch: 1, deviceOrdinal: 1)),
    .connection(Connection(epoch: 1, boundary: instant(0).utc)),
    .streamStarted(epoch: 1, nonce: "nonce"),
    .observation(observation(1, at: 1)), .drain,
  ] { trace.send(input, at: instant(1)) }
  let writes = trace.records.flatMap { record -> [WriterCommand] in
    if case .actions(let payload) = record.payload { return commands(payload.actions) }
    return []
  }
  let command = try #require(writes.first)
  var foreign = command
  foreign.id += 1
  var mismatched = trace
  mismatched.send(.audioWriteSkipped(foreign), at: instant(1))
  let mismatch = LogReport.evaluate(records: mismatched.records, selection: selection())
  #expect(mismatch.issues.contains(.receiptMismatch))
  trace.send(.audioObserved(audioReading(2, .mono, override: .on)), at: instant(1))
  trace.send(.audioWriteSkipped(command), at: instant(1))
  let report = LogReport.evaluate(records: trace.records, selection: selection())
  #expect(!report.issues.contains(.receiptMismatch) && !report.issues.contains(.orphanCompletion))
  #expect(report.metrics.monoCompletions == 0 && report.metrics.stereoCompletions == 0)
  trace.send(.audioWriteSkipped(command), at: instant(1))
  #expect(
    LogReport.evaluate(records: trace.records, selection: selection()).issues.contains(
      .orphanCompletion))
}
