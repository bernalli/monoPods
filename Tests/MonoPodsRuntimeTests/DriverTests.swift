import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

func envelopeFixture() throws -> [Data] {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/system-log.ndjson")
  return try Data(contentsOf: url).split(separator: 10).map { Data($0) }
}

@Test func actualSystemEnvelopeProjectsProcessPathAndTerminal() throws {
  let fixture = try envelopeFixture()
  var events = 0
  for line in fixture {
    switch try SystemLogEnvelope.decode(line) {
    case .event(let record):
      #expect(["bluetoothd", "audioaccessoryd", "mediaremoted"].contains(record.process))
      #expect(EarLine.parse(record: record) != .gap)
      events += 1
    case .finished(let count): #expect(count == events)
    }
  }
  #expect(events == 22)
  #expect(try LogRecord.decode(fixture[0]).process == "audioaccessoryd")
}

@Test func unknownEnvelopeKeysAndWrongTypesFailClosed() throws {
  let line = try envelopeFixture()[0]
  var object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
  object["newUnverifiedField"] = 1
  #expect(throws: (any Error).self) {
    try SystemLogEnvelope.decode(JSONSerialization.data(withJSONObject: object))
  }
  object.removeValue(forKey: "newUnverifiedField")
  for key in ["timestamp", "processImagePath", "subsystem", "eventMessage", "bootUUID"] {
    var bad = object
    bad[key] = true
    #expect(throws: (any Error).self) {
      try SystemLogEnvelope.decode(JSONSerialization.data(withJSONObject: bad))
    }
  }
  var bad = object
  bad["backtrace"] = ["frames": [["imageOffset": 1, "imageUUID": "bad", "new": 1]]]
  #expect(throws: (any Error).self) {
    try SystemLogEnvelope.decode(JSONSerialization.data(withJSONObject: bad))
  }
}

@Test func envelopeTruncationsDuplicateKeysAndBadTerminalAreRejected() throws {
  let line = try envelopeFixture()[0]
  for end in 0..<line.count {
    #expect(throws: (any Error).self) { try SystemLogEnvelope.decode(line.prefix(end)) }
  }
  for value in [
    #"{"count":true,"finished":1}"#, #"{"count":1,"finished":0}"#,
    #"{"count":1,"finished":1,"extra":0}"#, #"{"count":1,"finished":1,"count":2}"#,
  ] {
    #expect(throws: (any Error).self) { try SystemLogEnvelope.decode(Data(value.utf8)) }
  }
}

@Test func framingBoundsLinesAcrossArbitraryChunks() throws {
  var framer = NDJSONFramer()
  #expect(framer.feed(Data("abc".utf8)).isEmpty)
  #expect(framer.feed(Data("\ndef\n".utf8)) == [.line(Data("abc".utf8)), .line(Data("def".utf8))])
  #expect(framer.feed(Data(repeating: 65, count: 65537)) == [.gap])
  #expect(framer.feed(Data("discard\nnext\n".utf8)) == [.line(Data("next".utf8))])
  #expect(!framer.finish())
  _ = framer.feed(Data("partial".utf8))
  #expect(framer.finish())
}

@Test func historyRequiresSuccessfulExitAndMatchingFinalCount() throws {
  let fixture = try envelopeFixture()
  var capture = HistoryCapture()
  for line in fixture { capture.consume(line) }
  #expect(capture.complete(exitCode: 0, truncated: false))
  #expect(!capture.complete(exitCode: 1, truncated: false))
  #expect(!capture.complete(exitCode: 0, truncated: true))
  capture.consume(fixture[0])
  #expect(!capture.complete(exitCode: 0, truncated: false))
  var noTrailer = HistoryCapture()
  noTrailer.consume(fixture[0])
  #expect(!noTrailer.complete(exitCode: 0, truncated: false))
}

@Test func routeValidationRejectsBooleanAndFractionalProductIDs() {
  for product: Any in [true, 1.5, "1", NSNull()] {
    #expect(
      RouteIdentity.resolve(
        uid: "00-11-22-33-44-55", address: "00:11:22:33:44:55",
        connected: true, paired: true, bluetoothTransport: true, productID: product) == nil)
  }
  #expect(
    RouteIdentity.resolve(
      uid: "00-11-22-33-44-55", address: "00:11:22:33:44:55",
      connected: true, paired: true, bluetoothTransport: true, productID: NSNumber(value: 123))
      == "00:11:22:33:44:55")
  #expect(
    RouteIdentity.resolve(
      uid: "11-11-22-33-44-55", address: "00:11:22:33:44:55",
      connected: true, paired: true, bluetoothTransport: true, productID: 1) == nil)
  #expect(
    RouteIdentity.resolve(
      uid: "00-11-22-33-44-55:output", address: "00-11-22-33-44-55",
      connected: true, paired: true, bluetoothTransport: true, productID: NSNumber(value: 123))
      == "00:11:22:33:44:55")
  for uid in [
    "00-11-22-33-44-55:input", "00-11-22-33-44-55:output:output", "00-11-22-33-44-55output",
  ] {
    #expect(RouteIdentity.uidAddress(uid) == nil)
  }
}

@MainActor @Test func driverNeverInventsConnectionBoundaryOrAcceptsStaleStream() throws {
  var inputs: [EngineInput] = []
  let now = Instant(continuousNanos: 2, utc: try SourceTime("2026-11-06T12:00:00Z"))
  let driver = ObservationDriver(clock: { now }, submit: { inputs.append($0) })
  driver.route(address: "00:11:22:33:44:55")
  #expect(inputs.contains(.connection(Connection(epoch: 1, boundary: nil))))
  let epoch = try driver.beginStream(nonce: "test")
  let before = inputs.count
  driver.consume(try envelopeFixture()[0], epoch: epoch + 1)
  #expect(inputs.count == before)
  driver.consume(try envelopeFixture().last!, epoch: epoch)
  #expect(inputs.contains(.gap(epoch: epoch, reason: .finished, faultTime: nil)))
}

@MainActor @Test func fakeLogChildDrainsOutputBeforeCompletion() async throws {
  let process = LogProcess()
  var output = Data()
  let code: Int32 = await withCheckedContinuation { continuation in
    do {
      try process.start(
        executable: "/usr/bin/printf", arguments: ["first\\nsecond\\n"],
        chunk: { output.append($0) }, finished: { continuation.resume(returning: $0) })
    } catch { continuation.resume(returning: -1) }
  }
  #expect(code == 0)
  #expect(String(data: output, encoding: .utf8) == "first\nsecond\n")
}

@MainActor @Test func timedOutHistoryCannotReportSuccessfulCapture() async {
  let process = LogProcess()
  // This child lives until it is killed. Hold the main actor past the deadline on purpose:
  // neither delayed watchdog scheduling nor callback delivery may turn the capture into success.
  let startFailed = Int32.min
  let code: Int32 = await withCheckedContinuation { continuation in
    do {
      try process.start(
        executable: "/usr/bin/tail", arguments: ["-f", "/dev/null"], timeoutSeconds: 0,
        chunk: { _ in }, finished: { continuation.resume(returning: $0) })
    } catch {
      continuation.resume(returning: startFailed)
      return
    }
    Thread.sleep(forTimeInterval: 2)
  }
  #expect(code == -1)
}

@MainActor @Test func childThatExitsByItselfAfterTheDeadlineIsATimeout() async {
  let process = LogProcess()
  // Hold the main actor while the child normally exits after the zero-second deadline.
  // The background watchdog and the child's own exit can happen in either order.
  // The capture must report a timeout in both orders.
  let startFailed = Int32.min
  let code: Int32 = await withCheckedContinuation { continuation in
    do {
      try process.start(
        executable: "/bin/sleep", arguments: ["0.2"], timeoutSeconds: 0,
        chunk: { _ in }, finished: { continuation.resume(returning: $0) })
    } catch {
      continuation.resume(returning: startFailed)
      return
    }
    Thread.sleep(forTimeInterval: 1)
  }
  #expect(code == -1)
}

@MainActor @Test func childThatExitsBeforeTheDeadlineKeepsItsStatus() async {
  let process = LogProcess()
  // An early exit keeps its status only while scheduling delays stay below the deadline: delays
  // can time out an earlier exit on the safe side. A loaded CI runner delayed this check by more
  // than 30 s, so the deadline is far beyond any scheduling delay.
  let startFailed = Int32.min
  let code: Int32 = await withCheckedContinuation { continuation in
    do {
      try process.start(
        executable: "/usr/bin/false", arguments: [], timeoutSeconds: 3600,
        chunk: { _ in }, finished: { continuation.resume(returning: $0) })
    } catch {
      continuation.resume(returning: startFailed)
    }
  }
  #expect(code == 1)
}
@Test func envelopeRejectsMissingKeysAndMistypedMetadata() throws {
  let line = try envelopeFixture()[0]
  let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
  func rejects(_ value: [String: Any]) {
    #expect(throws: (any Error).self) {
      try SystemLogEnvelope.decode(JSONSerialization.data(withJSONObject: value))
    }
  }
  for key in ["timestamp", "processImagePath", "subsystem", "category", "eventMessage"] {
    var bad = object
    bad.removeValue(forKey: key)
    rejects(bad)
  }
  let frameUUID = "00000000-0000-4000-8000-000000000001"
  let mutations: [(String, Any)] = [
    ("machTimestamp", "1"), ("machTimestamp", -1), ("machTimestamp", 1.5), ("traceID", true),
    ("personaType", 2_147_483_648), ("personaType", "x"), ("bootUUID", "not-a-uuid"),
    ("processImageUUID", ""), ("source", "x"), ("processImagePath", "bluetoothd"),
    ("processImagePath", "/usr/sbin/"), ("timestamp", "2026-11-05 25:00:00+0100"),
    ("backtrace", ["frames": [["imageOffset": -1, "imageUUID": frameUUID]]]),
    ("backtrace", ["frames": [["imageOffset": 1]]]),
  ]
  for (key, value) in mutations {
    var bad = object
    bad[key] = value
    rejects(bad)
  }
  #expect(throws: (any Error).self) { try SystemLogEnvelope.decode(Data([0x7b, 0xff, 0x7d])) }
}
@MainActor private func streamDriver() throws -> (
  ObservationDriver, () -> [EngineInput], () -> [EvidenceKind], UInt64
) {
  var inputs: [EngineInput] = []
  var evidence: [EvidenceKind] = []
  let now = Instant(continuousNanos: 2, utc: try SourceTime("2026-11-06T12:00:00Z"))
  let driver = ObservationDriver(clock: { now }, submit: { inputs.append($0) })
  driver.evidence = { kind, hash in
    #expect(ContractValidation.hash(hash))
    evidence.append(kind)
  }
  let epoch = try driver.beginStream(nonce: "test")
  return (driver, { inputs }, { evidence }, epoch)
}

private func isGap(_ input: EngineInput) -> Bool {
  if case .gap = input { true } else { false }
}

@MainActor @Test func streamHeaderIsAcceptedOnlyAsTheFirstLine() throws {
  let envelope = try envelopeFixture()[0]
  let header = Data(#"Filtering the log data using "process == \"bluetoothd\"""#.utf8)
  let (accepted, acceptedInputs, acceptedEvidence, epoch) = try streamDriver()
  accepted.consume(header, epoch: epoch)
  accepted.consume(envelope, epoch: epoch)
  #expect(!acceptedInputs().contains(where: isGap))
  #expect(acceptedEvidence() == [.streamAccessible])
  let (late, lateInputs, _, lateEpoch) = try streamDriver()
  late.consume(envelope, epoch: lateEpoch)
  late.consume(header, epoch: lateEpoch)
  #expect(lateInputs().contains(.gap(epoch: lateEpoch, reason: .sourceUnreadable, faultTime: nil)))
  let (repeated, repeatedInputs, _, repeatedEpoch) = try streamDriver()
  repeated.consume(header, epoch: repeatedEpoch)
  repeated.consume(header, epoch: repeatedEpoch)
  #expect(repeatedInputs().contains(where: isGap))
  let (other, otherInputs, otherEvidence, otherEpoch) = try streamDriver()
  other.consume(Data("Some other informational line".utf8), epoch: otherEpoch)
  #expect(otherInputs().contains(where: isGap))
  #expect(otherEvidence().isEmpty)
}

@MainActor @Test func streamEvidenceIsRecordedOncePerStreamStart() throws {
  let fixture = try envelopeFixture()
  let (driver, _, evidence, epoch) = try streamDriver()
  driver.consume(fixture[0], epoch: epoch)
  driver.consume(fixture[1], epoch: epoch)
  #expect(evidence() == [.streamAccessible])
  let next = try driver.beginStream(nonce: "again")
  driver.consume(fixture[0], epoch: epoch)
  #expect(evidence() == [.streamAccessible])
  driver.consume(fixture[0], epoch: next)
  #expect(evidence() == [.streamAccessible, .streamAccessible])
}

/// `log stream --style ndjson` emits `"bootUUID":""` on every row (measured 2026-11-07, 10 of 10
/// rows); `log show` emits a real UUID. A stream row must still be read.
@MainActor @Test func streamRowWithEmptyBootUUIDIsRead() throws {
  let line = try envelopeFixture()[1]
  var object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
  object["bootUUID"] = ""
  let streamRow = try JSONSerialization.data(withJSONObject: object)
  guard case .event(let record) = try SystemLogEnvelope.decode(streamRow) else {
    Issue.record("stream row decoded as a terminal row")
    return
  }
  #expect(record.process == "bluetoothd")
  let (driver, inputs, evidence, epoch) = try streamDriver()
  driver.consume(streamRow, epoch: epoch)
  #expect(!inputs().contains(where: isGap))
  #expect(evidence() == [.streamAccessible])
  for key in ["processImageUUID", "senderImageUUID"] {
    var bad = object
    bad[key] = ""
    #expect(throws: (any Error).self) {
      try SystemLogEnvelope.decode(JSONSerialization.data(withJSONObject: bad))
    }
  }
}

@MainActor @Test func historyEvidenceRequiresCaptureThroughTheFinalRow() throws {
  let fixture = try envelopeFixture()
  let (driver, _, evidence, _) = try streamDriver()
  var complete = HistoryCapture()
  for line in fixture { complete.consume(line) }
  let context = ObservationContext(
    routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1)
  let hash = ArtifactHash.data(Data("history".utf8))
  driver.history(
    complete, id: 1, context: context, exitCode: 1, truncated: false, evidenceHash: hash)
  driver.history(
    complete, id: 2, context: context, exitCode: 0, truncated: true, evidenceHash: hash)
  var partial = HistoryCapture()
  for line in fixture.dropLast() { partial.consume(line) }
  driver.history(
    partial, id: 3, context: context, exitCode: 0, truncated: false, evidenceHash: hash)
  #expect(evidence().isEmpty)
  driver.history(
    complete, id: 4, context: context, exitCode: 0, truncated: false, evidenceHash: hash)
  #expect(evidence() == [.historyAccessible])
}

@MainActor @Test func historySelectsTheStateWhenATransitionSharesItsSourceTime() throws {
  let fixture = try envelopeFixture()
  let state = fixture[17]
  let stamp = try #require(
    (JSONSerialization.jsonObject(with: state) as? [String: Any])?["timestamp"] as? String)
  var object = try #require(JSONSerialization.jsonObject(with: fixture[18]) as? [String: Any])
  object["timestamp"] = stamp
  let transition = try JSONSerialization.data(withJSONObject: object)
  let finished = Data(#"{"count":2,"finished":1}"#.utf8)
  let now = Instant(continuousNanos: 2, utc: try SourceTime("2026-11-06T12:00:00Z"))
  let context = ObservationContext(
    routeEpoch: 1, streamEpoch: 1, connectionEpoch: 2, deviceOrdinal: 1)
  for rows in [[state, transition], [transition, state]] {
    var inputs: [EngineInput] = []
    let driver = ObservationDriver(clock: { now }, submit: { inputs.append($0) })
    driver.route(address: "00:11:22:33:44:55")
    driver.connected(address: "00:11:22:33:44:55", at: try SourceTime("2026-11-05T12:00:00Z"))
    _ = try driver.beginStream(nonce: "test")
    var capture = HistoryCapture()
    for row in rows + [finished] { capture.consume(row) }
    driver.history(
      capture, id: 1, context: context, exitCode: 0, truncated: false,
      evidenceHash: ArtifactHash.data(Data("history".utf8)))
    guard case .history(_, _, let observation, let complete)? = inputs.last else {
      Issue.record("Expected a history reply")
      continue
    }
    #expect(complete)
    #expect(observation?.value == .count(2, detection: .on))
  }
}
