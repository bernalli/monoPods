import Foundation
import Testing

@testable import MonoPodsCore

private let readingJSON =
  #"{"generation":1,"mode":"mono","status":0,"systemMono":"off"}"#
private let skippedJSON =
  #"{"audioWriteSkipped":{"_0":{"run":1,"id":2,"target":"mono","recovery":false,"context":{"routeEpoch":1,"streamEpoch":2,"connectionEpoch":3,"deviceOrdinal":4}}}}"#

private func jsonText(_ value: JSONValue, reversed: Bool = false) throws -> String {
  switch value {
  case .object(let fields):
    let keys = fields.keys.sorted()
    return try "{"
      + (reversed ? keys.reversed() : keys).map {
        try jsonText(.string($0)) + ":" + jsonText(fields[$0]!, reversed: reversed)
      }.joined(separator: ",") + "}"
  case .array(let values):
    return try "[" + values.map { try jsonText($0) }.joined(separator: ",") + "]"
  case .string(let text):
    return try #require(String(data: JSONEncoder().encode(text), encoding: .utf8))
  case .number(let text): return text
  case .bool(let value): return value ? "true" : "false"
  case .null: return "null"
  }
}

private func keyOrders(_ keys: [String]) -> [[String]] {
  guard !keys.isEmpty else { return [[]] }
  return keys.flatMap { key in keyOrders(keys.filter { $0 != key }).map { [key] + $0 } }
}

private func jsonPermutations(_ value: JSONValue) throws -> [String] {
  guard case .object(let fields) = value else { return [try jsonText(value)] }
  var result: [String] = []
  for keys in keyOrders(fields.keys.sorted()) {
    var combinations = [String]()
    combinations.append("")
    for key in keys {
      let prefix = try jsonText(.string(key)) + ":"
      let values = try jsonPermutations(fields[key]!)
      combinations = combinations.flatMap { partial in
        values.map { partial + (partial.isEmpty ? "" : ",") + prefix + $0 }
      }
    }
    result += combinations.map { "{" + $0 + "}" }
  }
  return result
}

/// Mutates every field at every nesting level, retaining duplicate keys in the lexical fixture.
private func structuralMutations(_ value: JSONValue) throws -> [String] {
  guard case .object(let fields) = value else { return [] }
  let replacements: [JSONValue] = [
    .null, .bool(true), .number("1.5"), .string("bad"), .array([]), .object([:]),
  ]
  var result = [String]()
  result.append(try jsonText(.object(fields.merging(["extra": .null]) { old, _ in old })))
  for key in fields.keys.sorted() {
    let item = fields[key]!
    var omitted = fields
    omitted.removeValue(forKey: key)
    result.append(try jsonText(.object(omitted)))
    let prefix = try jsonText(.object(fields))
    result.append(
      try String(prefix.dropLast()) + "," + jsonText(.string(key)) + ":" + jsonText(item) + "}")
    for replacement in replacements where replacement != item {
      var changed = fields
      changed[key] = replacement
      result.append(try jsonText(.object(changed)))
    }
    for nested in try structuralMutations(item) {
      let others = try fields.keys.sorted().filter { $0 != key }.map {
        try jsonText(.string($0)) + ":" + jsonText(fields[$0]!)
      }
      result.append(
        try "{" + (others + [jsonText(.string(key)) + ":" + nested]).joined(separator: ",") + "}")
    }
  }
  return result
}

private func decodeAudioContract(_ text: String, reading: Bool) throws {
  if reading {
    _ = try AudioReading.decode(Data(text.utf8))
  } else {
    let input = try ContractValidation.decode(EngineInput.self, data: Data(text.utf8))
    guard input.valid else { throw ContractError.invalid }
  }
}

@Test func audioContractsRejectEveryStructuralMutationAndTruncation() throws {
  let failedReading =
    #"{"generation":18446744073709551615,"mode":null,"status":-2147483648,"systemMono":"unreadable"}"#
  for (text, reading) in [
    (readingJSON, true), (failedReading, true),
    (#"{"audioObserved":{"_0":\#(failedReading)}}"#, false),
    (#"{"audioObserved":{"_0":\#(readingJSON)}}"#, false),
    (skippedJSON, false),
  ] {
    let value = try StrictJSON.parse(Data(text.utf8))
    try decodeAudioContract(text, reading: reading)
    for permutation in try jsonPermutations(value) {
      try decodeAudioContract(permutation, reading: reading)
    }
    for mutated in try structuralMutations(value) {
      #expect(throws: (any Error).self, "\(mutated)") {
        try decodeAudioContract(mutated, reading: reading)
      }
    }
    let bytes = Array(text.utf8)
    for end in bytes.indices {
      #expect(throws: (any Error).self) {
        try decodeAudioContract(
          #require(String(bytes: bytes[..<end], encoding: .utf8)), reading: reading)
      }
    }
  }
}

@Test func audioReadingEnforcesGenerationAndStatusModeEquivalence() throws {
  for generation in ["1", "18446744073709551615"] {
    for (mode, status) in [
      ("\"stereo\"", "0"), ("\"mono\"", "0"), ("null", "-2147483648"), ("null", "2147483647"),
    ] {
      for system in ["on", "off", "unreadable"] {
        let text =
          "{\"generation\":\(generation),\"mode\":\(mode),\"status\":\(status),\"systemMono\":\"\(system)\"}"
        let value = try AudioReading.decode(Data(text.utf8))
        #expect(value.valid)
        #expect(try AudioReading.decode(JSONEncoder().encode(value)) == value)
      }
    }
  }
  for (key, values) in [
    ("generation", ["0", "-1", "18446744073709551616", "1.0", "1e0"]),
    ("status", ["-2147483649", "2147483648", "1", "-1", "0.0"]),
    ("mode", ["null", "\"unknown\"", "0"]),
    ("systemMono", ["\"unknown\"", "0"]),
  ] {
    var fields = try StrictJSON.parse(Data(readingJSON.utf8)).object(keys: [
      "generation", "mode", "status", "systemMono",
    ])
    for replacement in values {
      fields[key] = try StrictJSON.parse(Data(replacement.utf8))
      let text = try jsonText(.object(fields))
      #expect(throws: (any Error).self) { try decodeAudioContract(text, reading: true) }
      #expect(throws: (any Error).self) {
        try decodeAudioContract(#"{"audioObserved":{"_0":\#(text)}}"#, reading: false)
      }
    }
  }
  #expect(!AudioReading(generation: 1, mode: nil, status: 0, systemMono: .off).valid)
}

@Test func skippedCommandsRejectInvalidIdentityAndContext() throws {
  for key in ["run", "id", "routeEpoch", "streamEpoch", "connectionEpoch", "deviceOrdinal"] {
    for value in ["0", "-1", "18446744073709551616", "1.0"] {
      let original =
        key == "id" || key == "streamEpoch"
        ? "2" : key == "connectionEpoch" ? "3" : key == "deviceOrdinal" ? "4" : "1"
      let text = skippedJSON.replacingOccurrences(
        of: "\"\(key)\":\(original)", with: "\"\(key)\":\(value)")
      #expect(throws: (any Error).self) { try decodeAudioContract(text, reading: false) }
    }
  }
  let recoveryMono = skippedJSON.replacingOccurrences(of: "false", with: "true")
  #expect(throws: (any Error).self) { try decodeAudioContract(recoveryMono, reading: false) }
}

@Test func audioObservationsAdvanceSnapshotWithoutChangingPlaybackControls() {
  var engine = readyEngine()
  let initial = engine.snapshot
  let reading = AudioReading(generation: 2, mode: .mono, status: 0, systemMono: .on)
  #expect(engine.handle(input: .audioObserved(reading), at: instant(1)).isEmpty)
  #expect(engine.snapshot.audio == reading)
  for generation: UInt64 in [0, 1, 2] {
    #expect(
      engine.handle(
        input: .audioObserved(
          AudioReading(generation: generation, mode: .stereo, status: 0, systemMono: .off)),
        at: instant(100)
      ).isEmpty)
    #expect(engine.snapshot.audio == reading)
  }
  #expect(engine.snapshot.desiredTarget == initial.desiredTarget)
  #expect(engine.snapshot.blocked == initial.blocked)
  #expect(engine.snapshot.lastCompleted == initial.lastCompleted)
  let terminal = AudioReading(generation: .max, mode: nil, status: -1, systemMono: .unreadable)
  #expect(engine.handle(input: .audioObserved(terminal), at: instant(1)).isEmpty)
  #expect(engine.snapshot.audio == terminal)
}

@Test func invalidAudioReadingsWithHigherGenerationsHaveNoEffect() {
  var engine = readyEngine()
  let valid = AudioReading(generation: 2, mode: .mono, status: 0, systemMono: .on)
  _ = engine.handle(input: .audioObserved(valid), at: instant(1))
  let before = engine
  for reading in [
    AudioReading(generation: 3, mode: nil, status: 0, systemMono: .off),
    AudioReading(generation: 3, mode: .stereo, status: 1, systemMono: .off),
  ] {
    #expect(engine.handle(input: .audioObserved(reading), at: instant(2)).isEmpty)
    #expect(engine == before)
  }
}

@Test func skippedWritesLeaveTheCurrentBackendUntouched() {
  var engine = readyEngine()
  let before = engine
  let command = WriterCommand(run: 1, id: 1, context: nil, target: .stereo, recovery: true)
  #expect(engine.handle(input: .audioWriteSkipped(command), at: instant(86_000)).isEmpty)
  #expect(engine == before)
}

@Test func oldShortcutTraceAndRemovedNoticeFailTheCurrentDecoder() throws {
  for (input, old, replacement) in [
    (EngineInput.tick, "\"tick\":{}", "\"shortcutAvailability\":{\"_0\":\"available\"}"),
    (.noticePresented(.commandFailed, success: true), "commandFailed", "writerStuck"),
  ] {
    let record = TraceRecord(
      build: String(repeating: "a", count: 64), run: 1, seq: 1, m: 0,
      payload: .input(InputPayload(utc: instant(0).utc, input: input)))
    let data = try JSONEncoder().encode(record)
    _ = try TraceRecord.decode(data)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains(old))
    let obsolete = text.replacingOccurrences(of: old, with: replacement)
    #expect(LogReport.decodeJSONL(Data((obsolete + "\n").utf8)).malformed)
  }
}

@Test func schemaAndCurrentAudioDiscriminatorsStayAligned() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let data = try Data(contentsOf: root.appendingPathComponent("schemas/contract.schema.json"))
  let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let definitions = try #require(schema["$defs"] as? [String: Any])
  let encoded = try #require(String(data: data, encoding: .utf8))
  #expect(!encoded.contains("shortcutAvailability") && !encoded.contains("writerStuck"))
  #expect(encoded.contains("stereoNotRestored"))
  for name in ["audioReading", "writerCommand", "writerReceipt", "journal", "input"] {
    #expect(definitions[name] != nil, "\(name)")
  }
  #expect(encoded.contains("audioObserved") && encoded.contains("audioWriteSkipped"))
}

private func incompatibleMutations(_ value: JSONValue) throws -> [String] {
  guard case .object(let fields) = value else { return [] }
  var output: [String] = []
  let canonical = try jsonText(value)
  output.append(String(canonical.dropLast()) + ",\"extra\":null}")
  for key in fields.keys.sorted() {
    let item = fields[key]!
    var omitted = fields
    omitted.removeValue(forKey: key)
    output.append(try jsonText(.object(omitted)))
    output.append(
      try String(canonical.dropLast()) + "," + jsonText(.string(key)) + ":" + jsonText(item) + "}")
    let replacements: [JSONValue]
    switch item {
    case .object: replacements = [.bool(true), .number("1"), .string("bad"), .array([])]
    case .number:
      replacements = [.null, .bool(true), .number("1.5"), .string("1"), .array([]), .object([:])]
    case .bool: replacements = [.null, .number("0"), .string("false"), .array([]), .object([:])]
    case .string: replacements = [.null, .bool(false), .number("0"), .array([]), .object([:])]
    case .null: replacements = [.bool(true), .number("0"), .array([]), .object([:])]
    case .array: replacements = [.bool(true), .number("0"), .string("bad"), .object([:])]
    }
    for replacement in replacements {
      var changed = fields
      changed[key] = replacement
      output.append(try jsonText(.object(changed)))
    }
    for nested in try incompatibleMutations(item) {
      let others = try fields.keys.sorted().filter { $0 != key }.map {
        try jsonText(.string($0)) + ":" + jsonText(fields[$0]!)
      }
      output.append(
        try "{" + (others + [jsonText(.string(key)) + ":" + nested]).joined(separator: ",") + "}")
    }
  }
  return output
}

@Test func durableReceiptAndJournalContractsRejectEveryNestedShapeMutation() throws {
  let command = WriterCommand(run: 1, id: 2, context: .test, target: .mono, recovery: false)
  let receipt = WriterReceipt(command: command, exitCode: .min, quiescent: true, persisted: true)
  var journal = crashedJournal(restoreRequired: true)
  journal.audio.nextId = 10
  journal.audio.phase = .completed
  journal.audio.lastCompleted = CommandReceipt(id: 2, target: .mono, exitCode: .max)
  let values: [(Data, (Data) throws -> Void)] = [
    (
      try JSONEncoder().encode(receipt),
      { data in
        let receipt = try ContractValidation.decode(WriterReceipt.self, data: data)
        guard receipt.command.valid else { throw ContractError.invalid }
      }
    ),
    (try JSONEncoder().encode(journal), { _ = try JournalRecord.decode($0) }),
    (
      try JSONEncoder().encode(EngineInput.writerCompleted(receipt)),
      { data in
        let input = try ContractValidation.decode(EngineInput.self, data: data)
        guard input.valid else { throw ContractError.invalid }
      }
    ),
  ]
  for (data, decode) in values {
    try decode(data)
    let parsed = try StrictJSON.parse(data)
    try decode(Data(jsonText(parsed, reversed: true).utf8))
    for mutated in try incompatibleMutations(parsed) {
      #expect(throws: (any Error).self, "\(mutated)") { try decode(Data(mutated.utf8)) }
    }
    for end in 0..<data.count { #expect(throws: (any Error).self) { try decode(data.prefix(end)) } }
  }
  for exit in ["-2147483649", "2147483648", "1.0", "true", "null"] {
    let text = try #require(String(data: JSONEncoder().encode(receipt), encoding: .utf8))
    let mutated = text.replacingOccurrences(
      of: "\"exitCode\":-2147483648", with: "\"exitCode\":\(exit)")
    #expect(throws: (any Error).self) {
      try ContractValidation.decode(WriterReceipt.self, data: Data(mutated.utf8))
    }
  }
}

func policyEngine(load: RuntimeLoad = .missing) -> Engine {
  var engine = Engine(
    build: String(repeating: "a", count: 64), run: 1,
    boot: "00000000-0000-4000-8000-000000000001")
  _ = engine.handle(input: .audioObserved(audioReading(1)), at: instant(0))
  let actions = engine.handle(input: .journalLoaded(load), at: instant(0))
  _ = acknowledge(actions, engine: &engine, at: instant(0))
  return engine
}
func audioReading(
  _ generation: UInt64, _ mode: Target? = .stereo,
  override: SystemMono = .off
) -> AudioReading {
  AudioReading(
    generation: generation, mode: mode, status: mode == nil ? -1 : 0,
    systemMono: override)
}
@discardableResult func policyFlush(_ engine: inout Engine, at now: Instant) -> [EngineAction] {
  var all: [EngineAction] = []
  for _ in 0..<8 {
    let actions = engine.handle(input: .drain, at: now)
    all += actions
    let ack = acknowledge(actions, engine: &engine, at: now)
    all += ack
    if !actions.contains(where: { if case .persist = $0 { true } else { false } }) { break }
  }
  return all
}
func commands(_ actions: [EngineAction]) -> [WriterCommand] {
  actions.compactMap { if case .writeTarget(let command) = $0 { command } else { nil } }
}
func completed(_ command: WriterCommand, status: Int32 = 0) -> EngineInput {
  .writerCompleted(
    WriterReceipt(command: command, exitCode: status, quiescent: true, persisted: true))
}

@Test func interruptedJournalsNormalizeAndRecoverWithoutAnyObservationBase() throws {
  for phase in [
    JournalPhase.prepared, .running, .uncertain, .completed, .idle, .restoreCommandCompleted,
  ] {
    var record = crashedJournal(
      restoreRequired: phase != .idle && phase != .restoreCommandCompleted)
    record.audio.phase = phase
    record.audio.nextId = 50
    if phase == .prepared || phase == .running {
      record.audio.active = AudioCommand(id: 2, target: .mono)
    }
    if phase == .completed {
      record.audio.lastCompleted = CommandReceipt(id: 2, target: .mono, exitCode: 0)
    }
    if phase == .restoreCommandCompleted {
      record.audio.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 0)
    }
    #expect(record.contractValid)
    var engine = policyEngine(load: .record(record))
    #expect(!engine.snapshot.blocked, "\(phase)")
    let first = commands(policyFlush(&engine, at: instant(0)))
    if !record.audio.restoreRequired {
      #expect(first.isEmpty)
      continue
    }
    let command = try #require(first.first)
    #expect(command.recovery && command.target == .stereo && command.id >= 50)
    _ = engine.handle(input: completed(command, status: -1), at: instant(0))
    for _ in 0..<10 { _ = engine.handle(input: .automation(false), at: instant(1)) }
    #expect(commands(policyFlush(&engine, at: instant(4))).isEmpty)
    _ = engine.handle(input: .tick, at: instant(5))
    #expect(commands(policyFlush(&engine, at: instant(5))).count == 1)
  }
}

@Test func receiptAndSkipMutationsCannotConsumeTheActiveTransaction() throws {
  var initial = readyEngine()
  let command = try #require(commands(delegate(1, engine: &initial, seconds: 1)).first)
  var variants: [WriterCommand] = []
  var changed = command
  changed.run += 1
  variants.append(changed)
  changed = command
  changed.id += 1
  variants.append(changed)
  changed = command
  changed.target = .stereo
  variants.append(changed)
  changed = command
  changed.recovery = true
  variants.append(changed)
  for field in [\ObservationContext.routeEpoch, \.streamEpoch, \.connectionEpoch, \.deviceOrdinal] {
    changed = command
    changed.context?[keyPath: field] += 1
    variants.append(changed)
  }
  changed = command
  changed.context = nil
  variants.append(changed)
  for foreign in variants {
    for input in [completed(foreign), .audioWriteSkipped(foreign)] {
      var engine = initial
      let before = engine
      #expect(engine.handle(input: input, at: instant(100)).isEmpty)
      #expect(engine == before)
      _ = engine.handle(input: completed(command), at: instant(1))
      #expect(engine.snapshot.lastCompleted?.id == command.id)
      let settled = engine
      #expect(engine.handle(input: completed(command), at: instant(101)).isEmpty)
      #expect(engine == settled)
    }
  }
}

@Test func correlatedSkipRestoresPreparedAudioAndRequiresCancellationAck() throws {
  var engine = readyEngine()
  let command = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: .audioObserved(audioReading(2, .mono, override: .on)), at: instant(1))
  let cancelled = engine.handle(input: .audioWriteSkipped(command), at: instant(1))
  let request = try #require(
    cancelled.compactMap { if case .persist(let value) = $0 { value } else { nil } }.first)
  #expect(!request.record.audio.restoreRequired && request.record.audio.phase == .idle)
  #expect(request.record.audio.active == nil && request.record.audio.lastCompleted == nil)
  _ = engine.handle(
    input: .persistenceAcknowledged(run: 1, id: request.id, success: false), at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(3)), at: instant(2))
  #expect(engine.snapshot.blocked)
  #expect(commands(policyFlush(&engine, at: instant(2))).isEmpty)
}

@Test func systemOverrideCancelsPreparedAndDefersRecovery() throws {
  var engine = readyEngine()
  _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
  let prepared = engine.handle(input: .drain, at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(2, .mono, override: .on)), at: instant(1))
  _ = acknowledge(prepared, engine: &engine, at: instant(1))
  #expect(commands(policyFlush(&engine, at: instant(1))).isEmpty)
  #expect(engine.snapshot.count == 1)
  _ = engine.handle(
    input: .audioObserved(audioReading(3, .mono, override: .unreadable)), at: instant(2))
  #expect(commands(policyFlush(&engine, at: instant(2))).map(\.target) == [.mono])
}

@Test func externalDisagreementWaitsOneSecondAndTenSecondsBetweenCorrections() throws {
  var engine = readyEngine()
  let mono = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: completed(mono), at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(2, .stereo)), at: instant(2))
  #expect(commands(policyFlush(&engine, at: instant(2, fraction: 999_999_999))).isEmpty)
  _ = engine.handle(
    input: .audioObserved(audioReading(3, .stereo)), at: instant(2, fraction: 999_999_999))
  let correction = try #require(commands(policyFlush(&engine, at: instant(3))).first)
  _ = engine.handle(input: completed(correction, status: -50), at: instant(3))
  for time in UInt64(4)...12 {
    _ = engine.handle(input: .audioObserved(audioReading(time + 1, .stereo)), at: instant(time))
    #expect(commands(policyFlush(&engine, at: instant(time))).isEmpty)
  }
  #expect(commands(policyFlush(&engine, at: instant(12, fraction: 999_999_999))).isEmpty)
  #expect(commands(policyFlush(&engine, at: instant(13))).count == 1)
  #expect(!engine.snapshot.blocked)
}

@Test func delayedSystemPreferenceWinsBeforeCorrectionAndStaleReadingCannotUndoIt() throws {
  var engine = readyEngine()
  let mono = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: completed(mono), at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(2, .stereo)), at: instant(2))
  _ = engine.handle(
    input: .audioObserved(audioReading(3, .stereo, override: .on)),
    at: instant(2, fraction: 500_000_000))
  _ = engine.handle(input: .audioObserved(audioReading(2)), at: instant(3))
  #expect(commands(policyFlush(&engine, at: instant(3))).isEmpty)
  _ = engine.handle(input: .audioObserved(audioReading(4, .stereo)), at: instant(4))
  let recovery = try #require(commands(policyFlush(&engine, at: instant(4))).first)
  #expect(recovery.recovery && recovery.target == .stereo)
  _ = engine.handle(input: completed(recovery), at: instant(4))
  #expect(commands(policyFlush(&engine, at: instant(4))).map(\.target) == [.mono])
}

@Test func quitWithoutDebtStillWaitsForItsStereoAndIgnoresNoticeAcknowledgement() throws {
  var engine = policyEngine()
  _ = engine.handle(input: .quit(.user), at: instant(1))
  #expect(!engine.snapshot.terminated)
  let command = try #require(commands(policyFlush(&engine, at: instant(1))).first)
  #expect(command.target == .stereo && command.recovery)
  let saved = engine.handle(input: completed(command), at: instant(1))
  #expect(acknowledge(saved, engine: &engine, at: instant(1)).contains(.terminate(0)))
}

@Test func quitRetriesAtAbsoluteBoundariesAndNeverRestartsItsBudget() throws {
  for reason in [ExitReason.user, .signal, .logout] {
    var engine = policyEngine()
    _ = engine.handle(input: .quit(reason), at: instant(0))
    let first = try #require(commands(policyFlush(&engine, at: instant(0))).first)
    _ = engine.handle(input: completed(first, status: -1), at: instant(0))
    _ = engine.handle(input: .quit(.user), at: instant(nanos: 199_000_000))
    #expect(commands(policyFlush(&engine, at: instant(nanos: 199_000_000))).isEmpty)
    let second = try #require(commands(policyFlush(&engine, at: instant(nanos: 200_000_000))).first)
    _ = engine.handle(input: completed(second, status: -1), at: instant(nanos: 200_000_000))
    #expect(commands(policyFlush(&engine, at: instant(nanos: 599_000_000))).isEmpty)
    let third = try #require(commands(policyFlush(&engine, at: instant(nanos: 600_000_000))).first)
    let end = engine.handle(input: completed(third, status: -1), at: instant(nanos: 600_000_000))
    #expect(end.contains(.terminate(0)))
    #expect(!end.contains { if case .persist = $0 { true } else { false } })
  }
}

@Test func quitNeverOverlapsWriterOrAcceptsLateSuccessAsClean() throws {
  var engine = readyEngine()
  let mono = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: .quit(.signal), at: instant(1))
  #expect(commands(policyFlush(&engine, at: instant(1))).isEmpty)
  _ = engine.handle(input: completed(mono), at: instant(2))
  let stereo = try #require(commands(policyFlush(&engine, at: instant(2))).first)
  #expect(stereo.target == .stereo)
  let late = engine.handle(input: completed(stereo), at: instant(3))
  #expect(!late.contains { if case .persist = $0 { true } else { false } })
}

@Test func quitCutoffDoesNotStartAnotherWriteAt1500Milliseconds() throws {
  for nanos: UInt64 in [1_499_000_000, 1_500_000_000, 1_999_000_000, 2_000_000_000] {
    var engine = policyEngine()
    _ = engine.handle(input: .quit(.logout), at: instant(0))
    let first = try #require(commands(policyFlush(&engine, at: instant(0))).first)
    _ = engine.handle(input: completed(first, status: -1), at: instant(nanos: nanos))
    #expect(
      commands(policyFlush(&engine, at: instant(nanos: nanos))).count
        == (nanos < 1_500_000_000 ? 1 : 0))
  }
}

@Test func seededPreparedCancellationsCanResumeAndNeverManufactureRecoveryDebt() throws {
  var allowed = 0
  var denied = 0
  for seed in UInt64(1)...128 {
    var engine = readyEngine()
    _ = engine.handle(input: .observation(observation(1, at: 1)), at: instant(1))
    let prepared = engine.handle(input: .drain, at: instant(1))
    if seed.isMultiple(of: 2) { _ = acknowledge(prepared, engine: &engine, at: instant(1)) }
    if seed.isMultiple(of: 3) {
      _ = engine.handle(
        input: .audioObserved(audioReading(2, .mono, override: .on)), at: instant(1))
    } else {
      _ = engine.handle(input: .automation(false), at: instant(1))
    }
    if !seed.isMultiple(of: 2) { _ = acknowledge(prepared, engine: &engine, at: instant(1)) }
    #expect(commands(policyFlush(&engine, at: instant(1))).isEmpty, "seed=\(seed)")
    denied += 1
    _ = engine.handle(input: .audioObserved(audioReading(3)), at: instant(2))
    _ = engine.handle(input: .automation(true), at: instant(2))
    _ = engine.handle(input: .observation(observation(1, at: 2)), at: instant(2))
    let resumed = commands(policyFlush(&engine, at: instant(2)))
    #expect(resumed.count == 1 && resumed.first?.target == .mono, "seed=\(seed)")
    allowed += resumed.count
  }
  #expect(allowed == 128 && denied == 128)
}

@Test func recoveryBudgetIsResetOnceAfterBlockedStereoAndCannotBeRenewedByOffInputs() throws {
  var engine = readyEngine()
  var time: UInt64 = 1
  var command = try #require(commands(delegate(2, engine: &engine, seconds: time)).first)
  for delay: UInt64 in [5, 30, 120, 0] {
    _ = engine.handle(input: completed(command, status: -1), at: instant(time))
    if delay == 0 { break }
    time += delay
    _ = engine.handle(input: .tick, at: instant(time))
    // Keep the base healthy without relying on a heartbeat from an expired stream.
    _ = engine.handle(input: .streamStarted(epoch: time + 1, nonce: "retry"), at: instant(time))
    _ = engine.handle(
      input: .heartbeat(epoch: time + 1, nonce: "retry", sequence: 1), at: instant(time))
    var row = observation(2, at: time)
    row.context.streamEpoch = time + 1
    _ = engine.handle(input: .observation(row), at: instant(time))
    command = try #require(commands(policyFlush(&engine, at: instant(time))).first)
  }
  _ = engine.handle(input: .automation(false), at: instant(time))
  command = try #require(commands(policyFlush(&engine, at: instant(time))).first)
  #expect(command.recovery)
  var attempts = 1
  for delay: UInt64 in [5, 30, 120, 0] {
    _ = engine.handle(input: completed(command, status: -1), at: instant(time))
    for _ in 0..<20 { _ = engine.handle(input: .automation(false), at: instant(time)) }
    if delay == 0 { break }
    time += delay
    _ = engine.handle(input: .tick, at: instant(time))
    command = try #require(commands(policyFlush(&engine, at: instant(time))).first)
    attempts += 1
  }
  for _ in 0..<20 { _ = engine.handle(input: .automation(false), at: instant(time + 1000)) }
  #expect(commands(policyFlush(&engine, at: instant(time + 1000))).isEmpty)
  #expect(attempts == 4)
}

@Test func newerDisagreementSurvivesReceiptAndNewEarDecisionBypassesCorrectionCooldown() throws {
  var engine = readyEngine()
  let first = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: .audioObserved(audioReading(2, .stereo)), at: instant(1))
  _ = engine.handle(input: completed(first), at: instant(1))
  #expect(commands(policyFlush(&engine, at: instant(1, fraction: 999_999_999))).isEmpty)
  let correction = try #require(commands(policyFlush(&engine, at: instant(2))).first)
  _ = engine.handle(input: completed(correction, status: -1), at: instant(2))
  #expect(commands(delegate(2, engine: &engine, seconds: 3)).map(\.target) == [.stereo])
}

@Test func systemOverrideDefersExistingDebtAndOffRestoresWithoutBase() throws {
  var engine = readyEngine()
  let mono = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: completed(mono), at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(2, .mono, override: .on)), at: instant(2))
  _ = engine.handle(input: .gap(epoch: 1, reason: .transport, faultTime: nil), at: instant(2))
  #expect(commands(policyFlush(&engine, at: instant(2))).isEmpty)
  _ = engine.handle(input: .audioObserved(audioReading(3, .mono)), at: instant(3))
  let restored = try #require(commands(policyFlush(&engine, at: instant(3))).first)
  #expect(restored.recovery && restored.target == .stereo)
}

@Test func uncertainCorrelatedReceiptsAlwaysBlockAndNeverGrantLastCompletion() throws {
  for quiescent in [false, true] {
    for persisted in [false, true] where !quiescent || !persisted {
      var engine = readyEngine()
      let command = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
      let input = EngineInput.writerCompleted(
        WriterReceipt(
          command: command, exitCode: 0,
          quiescent: quiescent, persisted: persisted))
      _ = engine.handle(input: input, at: instant(1))
      #expect(engine.snapshot.blocked && engine.snapshot.lastCompleted == nil)
      #expect(commands(policyFlush(&engine, at: instant(100))).isEmpty)
    }
  }
}

/// Independent interpretation of the schema keywords used by the audio contracts.
private struct AudioSchemaOracle {
  let definitions: [String: JSONValue]
  func accepts(_ value: JSONValue, schema: JSONValue) -> Bool {
    guard case .object(let rules) = schema else { return false }
    if case .string(let ref) = rules["$ref"] {
      guard let name = ref.split(separator: "/").last, let resolved = definitions[String(name)]
      else { return false }
      if !accepts(value, schema: resolved) { return false }
    }
    if let constant = rules["const"], value != constant { return false }
    if case .array(let choices) = rules["enum"], !choices.contains(value) { return false }
    for (keyword, exact) in [("oneOf", true), ("anyOf", false)] {
      if case .array(let options) = rules[keyword] {
        let matches = options.filter { accepts(value, schema: $0) }.count
        if exact ? matches != 1 : matches == 0 { return false }
      }
    }
    if case .array(let options) = rules["allOf"],
      !options.allSatisfy({ accepts(value, schema: $0) })
    {
      return false
    }
    if let condition = rules["if"] {
      let branch = accepts(value, schema: condition) ? "then" : "else"
      if let selected = rules[branch], !accepts(value, schema: selected) { return false }
    }
    if case .string(let type) = rules["type"] {
      switch (type, value) {
      case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool),
        ("null", .null):
        break
      case ("integer", .number(let raw)):
        if raw.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) == nil { return false }
      default: return false
      }
    }
    if case .number(let raw) = value, let number = Decimal(string: raw) {
      if case .number(let bound) = rules["minimum"], let minimum = Decimal(string: bound),
        number < minimum
      {
        return false
      }
      if case .number(let bound) = rules["maximum"], let maximum = Decimal(string: bound),
        number > maximum
      {
        return false
      }
    }
    if case .string(let text) = value, case .string(let pattern) = rules["pattern"],
      text.range(of: pattern, options: .regularExpression) == nil
    {
      return false
    }
    if case .object(let fields) = value {
      let properties: [String: JSONValue]
      if case .object(let declared) = rules["properties"] {
        properties = declared
      } else {
        properties = [:]
      }
      if case .array(let required) = rules["required"] {
        for key in required {
          guard case .string(let name) = key, fields[name] != nil else { return false }
        }
      }
      if rules["additionalProperties"] == .bool(false),
        !Set(fields.keys).isSubset(of: Set(properties.keys))
      {
        return false
      }
      for (name, item) in fields {
        if let property = properties[name], !accepts(item, schema: property) { return false }
      }
    }
    return true
  }
}

@Test func actualSchemaAndDecodersAgreeOnTheAudioNegativeCorpus() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let schema = try StrictJSON.parse(
    Data(contentsOf: root.appendingPathComponent("schemas/contract.schema.json")))
  guard case .object(let document) = schema, case .object(let definitions) = document["$defs"]
  else { throw ContractError.invalid }
  let oracle = AudioSchemaOracle(definitions: definitions)
  for text in [
    readingJSON,
    #"{"generation":18446744073709551615,"mode":null,"status":-2147483648,"systemMono":"unreadable"}"#,
  ] {
    let value = try StrictJSON.parse(Data(text.utf8))
    let rules = try #require(definitions["audioReading"])
    #expect(oracle.accepts(value, schema: rules))
    _ = try AudioReading.decode(Data(text.utf8))
    for mutation in try structuralMutations(value) {
      let data = Data(mutation.utf8)
      let accepted =
        (try? StrictJSON.parse(data)).map { oracle.accepts($0, schema: rules) } ?? false
      #expect(!accepted)
      #expect(throws: (any Error).self) { try AudioReading.decode(data) }
    }
  }
  for input in [
    EngineInput.audioObserved(audioReading(1)),
    .audioWriteSkipped(
      WriterCommand(run: 1, id: 2, context: .test, target: .mono, recovery: false)),
  ] {
    let data = try JSONEncoder().encode(input)
    let value = try StrictJSON.parse(data)
    let rules = try #require(definitions["input"])
    #expect(oracle.accepts(value, schema: rules))
    #expect(try ContractValidation.decode(EngineInput.self, data: data).valid)
    for mutation in try incompatibleMutations(value) {
      let bytes = Data(mutation.utf8)
      let accepted =
        (try? StrictJSON.parse(bytes)).map { oracle.accepts($0, schema: rules) } ?? false
      #expect(!accepted)
      #expect(throws: (any Error).self) {
        let input = try ContractValidation.decode(EngineInput.self, data: bytes)
        guard input.valid else { throw ContractError.invalid }
      }
    }
  }
}

private struct MediaDecision: Equatable {
  var time: UInt64
  var action: String
  var context: ObservationContext
}

/// Same ear/player stream twice, with independent audio events superimposed on one copy.
/// Only media command IDs are discarded; decision time and every context field must match.
private func mediaTranscript(seed: UInt64, audioEvents: Bool) -> [MediaDecision] {
  var engine = readyEngine()
  var decisions: [MediaDecision] = []
  var random = seed
  func send(_ input: EngineInput, at now: Instant) {
    var queue = [input, EngineInput.drain]
    var budget = 0
    while !queue.isEmpty && budget < 40 {
      budget += 1
      let actions = engine.handle(input: queue.removeFirst(), at: now)
      for action in actions {
        switch action {
        case .persist(let request):
          queue += [.persistenceAcknowledged(run: 1, id: request.id, success: true), .drain]
        case .writeTarget(let command): queue += [completed(command), .drain]
        case .emitHeartbeat(let epoch, let nonce, let sequence):
          queue.append(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence))
        case .play(let command):
          decisions.append(
            MediaDecision(time: now.continuousNanos, action: "play", context: command.context))
          queue.append(.playCompleted(run: 1, id: command.id, accepted: true))
        case .pause(let context):
          decisions.append(
            MediaDecision(time: now.continuousNanos, action: "pause", context: context))
        default: break
        }
      }
    }
    #expect(budget < 40, "seed=\(seed), FIFO did not settle")
  }
  for step in UInt64(1)...200 {
    random = random &* 6_364_136_223_846_793_005 &+ 1
    let now = instant(nanos: step * 100_000_000)
    let input: EngineInput
    switch (random >> 33) % 9 {
    case 0, 1:
      input = .observation(
        Observation(
          sourceTime: now.utc, source: .s1, provenance: .live,
          context: .test, receivedContinuousNanos: now.continuousNanos,
          value: .count(Int((random >> 20) % 3), detection: .on)))
    case 2: input = .nowPlaying(epoch: 1, playing: false, sourceTime: now.utc)
    case 3: input = .nowPlaying(epoch: 1, playing: true, sourceTime: now.utc)
    case 4: input = .pause(now.utc)
    case 5, 6:
      input = .observation(
        Observation(
          sourceTime: now.utc, source: .m, provenance: .live,
          context: .test, receivedContinuousNanos: now.continuousNanos,
          value: (random >> 20) % 2 == 0
            ? .transition(from: .both, to: .one) : .transition(from: .one, to: .both)))
    case 7: input = .gap(epoch: 1, reason: .sourceUnreadable, faultTime: now.utc)
    default: input = .tick
    }
    send(input, at: now)
    if audioEvents {
      let override: SystemMono = step % 7 == 0 ? .on : step % 3 == 0 ? .unreadable : .off
      send(
        .audioObserved(
          audioReading(step + 1, step.isMultiple(of: 2) ? .mono : .stereo, override: override)),
        at: now)
      send(.audioObserved(audioReading(1, .mono, override: .on)), at: now)
    }
  }
  return decisions
}

@Test func seededAudioEventsPreserveEveryMediaDecisionTimeAndContext() {
  var plays = 0
  var pauses = 0
  for seed in UInt64(1)...100 {
    let reference = mediaTranscript(seed: seed, audioEvents: false)
    #expect(mediaTranscript(seed: seed, audioEvents: true) == reference, "seed=\(seed)")
    plays += reference.filter { $0.action == "play" }.count
    pauses += reference.filter { $0.action == "pause" }.count
  }
  #expect(plays > 0 && pauses > 0)
}

@Test func returningEarDecisionIsNotAnExternalCorrectionEvenAfterAnInterveningFailure() throws {
  var engine = readyEngine()
  let mono = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: completed(mono), at: instant(1))
  _ = engine.handle(input: .audioObserved(audioReading(2, .stereo)), at: instant(2))
  let correction = try #require(commands(policyFlush(&engine, at: instant(3))).first)
  _ = engine.handle(input: completed(correction, status: -1), at: instant(3))
  let stereo = try #require(commands(delegate(2, engine: &engine, seconds: 4)).first)
  _ = engine.handle(input: completed(stereo, status: -1), at: instant(4))
  #expect(commands(delegate(1, engine: &engine, seconds: 5)).map(\.target) == [.mono])
}

@Test func previousWriterFailureDoesNotDelayOrSpendTheQuitBudget() throws {
  var engine = readyEngine()
  let normal = try #require(commands(delegate(1, engine: &engine, seconds: 1)).first)
  _ = engine.handle(input: .quit(.user), at: instant(1))
  _ = engine.handle(input: completed(normal, status: -1), at: instant(1))
  let stereo = try #require(commands(policyFlush(&engine, at: instant(1))).first)
  #expect(stereo.recovery && stereo.target == .stereo)
}

/// Independent writer invariants over random readings, ear counts, failures, skips and Quit.
@Test func seededWriterSequencesKeepOverrideCooldownAndQuitInvariants() {
  var writes = 0
  var corrections = 0
  var cooldownComparisons = 0
  var overrideSteps = 0
  var quitWrites = 0
  var failures = 0
  var skips = 0
  for seed in UInt64(1)...256 {
    var engine = readyEngine()
    var random = seed
    func roll(_ bound: UInt64) -> UInt64 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      return (random >> 33) % bound
    }
    var time: UInt64 = 1_000_000_000
    var generation: UInt64 = 1
    var override = SystemMono.off
    var active: WriterCommand?
    var activeDecision: UInt64 = 0
    var applied: (target: Target, decision: UInt64)?
    var decision: UInt64 = 0
    var lastTarget: Target?
    var lastCorrection: UInt64?
    var quitAt: UInt64?
    var attemptsInQuit = 0
    func check(_ command: WriterCommand) {
      #expect(active == nil, "seed=\(seed): overlapping writer")
      #expect(override != .on, "seed=\(seed): writer during system override")
      writes += 1
      if let quitAt {
        attemptsInQuit += 1
        quitWrites += 1
        #expect(command.recovery && command.target == .stereo, "seed=\(seed)")
        #expect(time - quitAt < 1_500_000_000, "seed=\(seed)")
        #expect(attemptsInQuit <= 3, "seed=\(seed)")
      } else if !command.recovery, let applied, applied.target == command.target,
        applied.decision == decision
      {
        corrections += 1
        if let lastCorrection {
          cooldownComparisons += 1
          #expect(time - lastCorrection >= 10_000_000_000, "seed=\(seed)")
        }
        lastCorrection = time
      }
      active = command
      activeDecision = decision
    }
    func send(_ input: EngineInput) {
      let now = instant(nanos: time)
      var queue = [input, EngineInput.drain]
      var budget = 0
      while !queue.isEmpty, budget < 40 {
        budget += 1
        for action in engine.handle(input: queue.removeFirst(), at: now) {
          switch action {
          case .persist(let request):
            queue += [.persistenceAcknowledged(run: 1, id: request.id, success: true), .drain]
          case .emitHeartbeat(let epoch, let nonce, let sequence):
            queue.append(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence))
          case .writeTarget(let command): check(command)
          default: break
          }
        }
      }
      #expect(budget < 40, "seed=\(seed): FIFO did not settle")
    }
    for step in 1...270 {
      time += quitAt == nil ? (1 + roll(20)) * 100_000_000 : 100_000_000
      if step == 240 {
        quitAt = time
        send(.quit(.user))
        continue
      }
      if let command = active, roll(3) != 0 {
        active = nil
        switch roll(8) {
        case 0:
          failures += 1
          send(completed(command, status: -1))
        case 1:
          skips += 1
          generation += 1
          override = .on
          send(.audioObserved(audioReading(generation, command.target, override: .on)))
          send(.audioWriteSkipped(command))
        default:
          applied = (command.target, activeDecision)
          send(completed(command))
        }
      }
      switch roll(10) {
      case 0, 1:
        generation += 1
        override = roll(8) == 0 ? .on : roll(8) == 0 ? .unreadable : .off
        let mode: Target? = roll(6) == 0 ? nil : roll(2) == 0 ? .mono : .stereo
        send(.audioObserved(audioReading(generation, mode, override: override)))
      case 2, 3:
        let value = Int(roll(3))
        let target: Target = value == 1 ? .mono : .stereo
        if lastTarget != target { decision += 1 }
        lastTarget = target
        send(
          .observation(
            Observation(
              sourceTime: instant(nanos: time).utc, source: .s1, provenance: .live,
              context: .test, receivedContinuousNanos: time,
              value: .count(value, detection: .on))))
      case 4: send(.automation(roll(4) != 0))
      case 5: send(.environment(awake: true, bluetooth: roll(4) != 0))
      case 6: send(.gap(epoch: 1, reason: .sourceUnreadable, faultTime: nil))
      default: send(.tick)
      }
      if override == .on {
        overrideSteps += 1
        #expect(engine.snapshot.desiredTarget == nil, "seed=\(seed)")
      }
      if engine.snapshot.terminated { break }
    }
  }
  // The seeds are fixed: floors at about half of the measured reach keep every branch exercised.
  #expect(writes >= 3000 && corrections >= 250 && cooldownComparisons >= 150)
  #expect(overrideSteps >= 5000 && quitWrites >= 100 && failures >= 400 && skips >= 400)
}

@Test func semanticallyInvalidJournalsStayBlockedAndAreNeverRewritten() {
  var valid = crashedJournal(restoreRequired: true)
  valid.audio.nextId = 10
  valid.audio.phase = .uncertain
  valid.audio.active = nil
  valid.audio.lastCompleted = nil
  #expect(valid.contractValid)
  let mutations: [(inout JournalRecord) -> Void] = [
    { $0.audio.phase = .running },
    { $0.audio.phase = .prepared },
    { $0.audio.phase = .completed },
    { $0.audio.phase = .idle },
    { $0.audio.restoreRequired = false },
    { record in
      record.audio.phase = .restoreCommandCompleted
      record.audio.restoreRequired = false
      record.audio.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 1)
    },
    { record in
      record.audio.phase = .restoreCommandCompleted
      record.audio.restoreRequired = false
      record.audio.lastCompleted = CommandReceipt(id: 2, target: .mono, exitCode: 0)
    },
    { $0.audio.active = AudioCommand(id: 10, target: .mono) },
    { $0.audio.lastCompleted = CommandReceipt(id: 11, target: .mono, exitCode: 0) },
    { $0.audio.nextId = 0 },
    { $0.audio.recoveryTarget = .mono },
    { $0.audio.initial = "mono" },
    { $0.lifecycle.run = 0 },
    { $0.v = 2 },
  ]
  for mutate in mutations {
    var record = valid
    mutate(&record)
    #expect(!record.contractValid)
    var engine = Engine(
      build: String(repeating: "a", count: 64), run: 1,
      boot: "00000000-0000-4000-8000-000000000001")
    let actions = engine.handle(input: .journalLoaded(.record(record)), at: instant(0))
    #expect(actions.contains(.showNotice(.recoveryBlocked)))
    #expect(!actions.contains { if case .persist = $0 { true } else { false } })
    #expect(engine.snapshot.blocked)
    #expect(commands(policyFlush(&engine, at: instant(1))).isEmpty)
    let quit = engine.handle(input: .quit(.user), at: instant(1))
    #expect(!quit.contains { if case .persist = $0 { true } else { false } })
  }
}

@Test func externalResetsCannotAdvanceAQuitRetry() throws {
  let hostile: [EngineInput] = [
    .route(nil), .automation(false), .environment(awake: true, bluetooth: false),
    .connection(Connection(epoch: 99, boundary: nil)),
  ]
  for input in hostile {
    var engine = readyEngine()
    _ = engine.handle(input: .quit(.user), at: instant(1))
    let first = try #require(commands(policyFlush(&engine, at: instant(1))).first)
    _ = engine.handle(input: completed(first, status: -1), at: instant(1))
    _ = engine.handle(input: input, at: instant(1, fraction: 100_000_000))
    #expect(commands(policyFlush(&engine, at: instant(1, fraction: 199_000_000))).isEmpty)
    #expect(commands(policyFlush(&engine, at: instant(1, fraction: 200_000_000))).count == 1)
  }
}
