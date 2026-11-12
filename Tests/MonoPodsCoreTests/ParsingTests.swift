import Foundation
import MonoPodsCore
import Testing

let address = "00:11:22:33:44:55"
func s1(
  _ primary: String = "in ear", _ secondary: String = "in case",
  time: String = "2001-01-01T00:00:01.000000001Z"
) -> LogRecord {
  LogRecord(
    timestamp: time, process: "bluetoothd", subsystem: "com.apple.bluetooth",
    category: "Server.AACP",
    message:
      "received in-ear state update from device \(address) primary bud state = \(primary), secondary bud state = \(secondary)"
  )
}
@Test func allBudPairsCountWithoutInferringSides() {
  let values = ["in ear", "out of ear", "in case", "unknown"]
  let counts: [[Int?]] = [[2, 1, 1, nil], [1, 0, 0, nil], [1, 0, 0, nil], [nil, nil, nil, nil]]
  for i in values.indices {
    for j in values.indices {
      guard case .state(let state) = EarLine.parse(record: s1(values[i], values[j])) else {
        Issue.record("Expected recognized state")
        continue
      }
      #expect(state.count == counts[i][j])
    }
  }
}
@Test func sanitizedHistoryFixtureParsesAllSourceFamilies() throws {
  let url = try #require(
    Bundle.module.url(forResource: "history", withExtension: "jsonl", subdirectory: "Fixtures"))
  let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
  #expect(lines.count == 524)
  var counts = [0, 0]
  for line in lines {
    let record = try LogRecord.decodeProjection(Data(line.utf8))
    switch EarLine.parse(record: record) {
    case .state: counts[0] += 1
    case .transition: counts[1] += 1
    default: Issue.record("Fixture rejected")
    }
  }
  #expect(counts == [509, 15])
}
@Test func malformedRecognizedSourcesInvalidate() {
  let record = s1()
  for addr in ["<private>", "", "00:11:22", "00:11-22:33:44:55"] {
    let changed = LogRecord(
      timestamp: record.timestamp, process: record.process, subsystem: record.subsystem,
      category: record.category,
      message: record.message.replacingOccurrences(of: address, with: addr))
    #expect(EarLine.parse(record: changed) == .gap)
  }
  for value in ["", "<private>", "invalid", "in ea"] {
    guard case .state(let state) = EarLine.parse(record: s1(value)) else {
      Issue.record("Malformed state must preserve identity and invalidate count")
      continue
    }
    #expect(state.count == nil)
  }
}
@Test func strictJSONRejectsEveryTruncationAndAmbiguity() throws {
  let valid = Data(
    #"{"timestamp":"2001-01-01T00:00:01Z","process":"bluetoothd","subsystem":"com.apple.bluetooth","category":"Server.AACP","eventMessage":"unrelated"}"#
      .utf8)
  _ = try LogRecord.decodeProjection(valid)
  for end in 0..<valid.count {
    #expect(throws: (any Error).self) { try LogRecord.decodeProjection(valid.prefix(end)) }
  }
  for bad in [
    Data([0xff]), Data(#"{"a":{"x":1,"x":2}}"#.utf8),
    Data(#"{"timestamp":true}"#.utf8), Data(repeating: 32, count: 65537),
  ] {
    #expect(throws: (any Error).self) { try LogRecord.decodeProjection(bad) }
  }
}
@Test func timestampsPreserveNanosecondsOffsetAndValidateCalendar() throws {
  let a = try SourceTime("2001-01-01T01:00:01.000000001+01:00")
  let b = try SourceTime("2001-01-01T00:00:01.000000002Z")
  #expect(a < b)
  #expect(b.nanos - a.nanos == 1)
  #expect(a.raw.hasSuffix("+01:00"))
  for bad in [
    "2001-02-30T00:00:00Z", "2001-01-01T25:00:00Z", "2001-01-01", "2001-01-01T00:00:00.1234567890Z",
  ] {
    #expect(throws: (any Error).self) { try SourceTime(bad) }
  }
}
@Test func latestUnknownAndIncompleteHistoryCannotResurrectOldState() {
  var context = HistoryContext(
    address: address, connection: "2001-01-01T00:00:00Z", readTime: "2001-01-01T00:00:10Z",
    complete: true)
  #expect(
    HistorySnapshot.select(records: [s1()], context: context)
      == .known(EarState(address: address, primary: .inEar, secondary: .inCase), s1().timestamp))
  #expect(
    HistorySnapshot.select(
      records: [s1(), s1("unknown", time: "2001-01-01T00:00:02Z")], context: context) == .unknown)
  context.complete = false
  #expect(HistorySnapshot.select(records: [s1()], context: context) == .incomplete)
  context.complete = true
  context.connection = nil
  #expect(HistorySnapshot.select(records: [s1()], context: context) == .unknown)
  context.connection = "2001-01-01T00:00:02Z"
  #expect(HistorySnapshot.select(records: [s1()], context: context) == .unknown)
  context.connection = "2001-01-01T00:00:00Z"
  context.faultTime = "2001-01-01T00:00:02Z"
  #expect(HistorySnapshot.select(records: [s1()], context: context) == .unknown)
}

@Test func historyRequiresNewReadableStateAfterRedactionAndPreservesDetectionOff() {
  let broken = LogRecord(
    timestamp: "2001-01-01T00:00:02Z", process: "bluetoothd", subsystem: "com.apple.bluetooth",
    category: "Server.AACP",
    message:
      "received in-ear state update from device <private> primary bud state = in ear, secondary bud state = in case"
  )
  let context = HistoryContext(
    address: address, connection: "2001-01-01T00:00:00Z", readTime: "2001-01-01T00:00:10Z",
    complete: true)
  #expect(
    HistorySnapshot.select(records: [s1(), broken], context: context)
      != .known(EarState(address: address, primary: .inEar, secondary: .inCase), s1().timestamp))
  let fresh = s1(time: "2001-01-01T00:00:03Z")
  #expect(
    HistorySnapshot.select(records: [s1(), broken, fresh], context: context)
      == .known(EarState(address: address, primary: .inEar, secondary: .inCase), fresh.timestamp))
  let disabled = LogRecord(
    timestamp: "2001-01-01T00:00:04Z", process: "audioaccessoryd", subsystem: "com.apple.bluetooth",
    category: "BTSmartRoutingDaemon",
    message:
      "SmartRouting CONNECTED STATE shows inEar: no for device \(address) primary:Disabled secondary:Disabled"
  )
  #expect(
    HistorySnapshot.select(records: [disabled], context: context)
      == .known(
        EarState(address: address, primary: .disabled, secondary: .disabled), disabled.timestamp))
}

@Test func allS3PairsPreserveDisabledUnknownAndRoleSymmetry() {
  let states = ["InEar", "OutOfEar", "InCase", "Unknown", "Disabled"]
  let counts: [[Int?]] = [
    [2, 1, 1, nil, nil], [1, 0, 0, nil, nil], [1, 0, 0, nil, nil],
    [nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil],
  ]
  for i in states.indices {
    for j in states.indices {
      let record = LogRecord(
        timestamp: "2001-01-01T00:00:01Z", process: "audioaccessoryd",
        subsystem: "com.apple.bluetooth", category: "BTSmartRoutingDaemon",
        message:
          "SmartRouting CONNECTED STATE shows inEar: no for device \(address) primary:\(states[i]) secondary:\(states[j])"
      )
      guard case .state(let state) = EarLine.parse(record: record) else {
        Issue.record("Rejected S3 pair")
        continue
      }
      #expect(state.count == counts[i][j])
      #expect(state.detectionOff == (i == 4 || j == 4))
    }
  }
}
@Test func recognizedMessagesRejectTruncationSuffixRedactionAndUnknownValues() {
  func record(_ base: LogRecord, _ message: String) -> LogRecord {
    LogRecord(
      timestamp: base.timestamp, process: base.process, subsystem: base.subsystem,
      category: base.category, message: message)
  }
  let s3 = LogRecord(
    timestamp: "2001-01-01T00:00:01Z", process: "audioaccessoryd",
    subsystem: "com.apple.bluetooth", category: "BTSmartRoutingDaemon",
    message:
      "SmartRouting CONNECTED STATE shows inEar: yes for device \(address) primary:InEar secondary:InCase"
  )
  let m = LogRecord(
    timestamp: "2001-01-01T00:00:01Z", process: "mediaremoted",
    subsystem: "com.apple.amp.mediaremote", category: "MediaRemote",
    message:
      "[AccessoryController] Device <MRDBluetoothDevice 0x1 \(address)> ear status changed from Both to One"
  )
  for base in [s1(), s3, m] {
    let message = Array(base.message)
    for end in 0..<message.count {
      let result = EarLine.parse(record: record(base, String(message[..<end])))
      if case .state(let state) = result { #expect(state.count == nil, "end=\(end)") }
      if case .transition = result { Issue.record("truncated M accepted at \(end)") }
    }
    for suffix in [" ", " extra", "\n", "<private>"] {
      let result = EarLine.parse(record: record(base, base.message + suffix))
      if case .state(let state) = result { #expect(state.count == nil, "suffix=\(suffix)") }
      if case .transition = result { Issue.record("extended M accepted") }
    }
  }
  for value in ["Two", "both", "<private>", ""] {
    let changed = m.message.replacingOccurrences(of: "to One", with: "to \(value)")
    #expect(EarLine.parse(record: record(m, changed)) == .gap)
  }
  #expect(
    EarLine.parse(record: record(m, m.message.replacingOccurrences(of: address, with: "<private>")))
      == .gap)
  let beat = LogRecord(
    timestamp: "2001-01-01T00:00:01Z", process: "MonoPods",
    subsystem: "io.github.bernalli.monopods", category: "heartbeat", message: "HEARTBEAT n 1")
  #expect(EarLine.parse(record: beat) == .heartbeat("n", 1))
  for bad in [
    "HEARTBEAT n 0", "HEARTBEAT n 18446744073709551616", "HEARTBEAT n 1 x", "HEARTBEAT n 1\n",
    "HEARTBEAT  1",
  ] {
    #expect(EarLine.parse(record: record(beat, bad)) == .gap, "\(bad)")
  }
}

@Test func historyConflictsDependOnSourceTimeInsteadOfDeliveryOrder() {
  let context = HistoryContext(
    address: address, connection: "2001-01-01T00:00:00Z",
    readTime: "2001-01-01T00:00:10Z", complete: true)
  let first = s1(time: "2001-01-01T00:00:01Z")
  let conflicting = s1("out of ear", time: first.timestamp)
  let fresh = s1(time: "2001-01-01T00:00:02Z")
  let expected = HistorySnapshot.select(records: [fresh], context: context)
  for rows in [
    [first, conflicting, fresh], [first, fresh, conflicting],
    [conflicting, first, fresh], [conflicting, fresh, first],
    [fresh, first, conflicting], [fresh, conflicting, first],
  ] {
    #expect(HistorySnapshot.select(records: rows, context: context) == expected)
  }
  for rows in [[first, conflicting], [conflicting, first], [first, conflicting, first]] {
    #expect(HistorySnapshot.select(records: rows, context: context) == .unknown)
  }
}
