import Darwin
import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

func temporaryRuntime() throws -> URL {
  let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("monopods-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: url, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  return url
}
let testBuild = String(repeating: "a", count: 64)

@Test func journalIsAtomicPrivateAndStrict() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  #expect(files.load() == .missing)
  let journal = JournalRecord(run: 1, build: testBuild)
  try files.persist(record: journal)
  #expect(files.load() == .record(journal))
  let mode =
    try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("restore.json").path)[.posixPermissions] as? Int
  #expect(mode == 0o600)
  try Data("{}".utf8).write(to: root.appendingPathComponent("restore.json"))
  #expect(files.load() == .blocked)
}

@Test func unsafeRuntimeAndSymlinkFilesFailClosed() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  try FileManager.default.createSymbolicLink(
    atPath: root.appendingPathComponent("restore.json").path,
    withDestinationPath: root.appendingPathComponent("other").path)
  #expect(files.load() == .blocked)
  #expect(throws: (any Error).self) {
    try files.persist(record: JournalRecord(run: 1, build: testBuild))
  }
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
}

@Test func failedPersistenceNeverDelegates() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(
    directory: root,
    before: { stage in
      if stage == .rename { throw ContractError.invalid }
    })
  #expect(throws: (any Error).self) {
    try files.persist(record: JournalRecord(run: 1, build: testBuild))
  }
  #expect(files.load() == .missing)
}

@Test func directorySyncFailureIsNotAcknowledged() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(
    directory: root,
    before: { stage in
      if stage == .directorySync { throw ContractError.invalid }
    })
  #expect(throws: (any Error).self) {
    try files.persist(record: JournalRecord(run: 1, build: testBuild))
  }
}

/// A posix_spawn running on another thread copies every open descriptor, including
/// O_CLOEXEC ones, and drops them only when the child's exec completes. A lock released
/// during that window stays busy for microseconds, so reacquisition waits a bounded time;
/// a descriptor that really stays open still fails here.
func acquireReleasedLock(files: AtomicRuntimeFiles, name: String) throws -> InstanceLock {
  for _ in 0..<50 {
    do {
      return try InstanceLock(files: files, name: name)
    } catch RuntimeError.busy {
      Thread.sleep(forTimeInterval: 0.01)
    }
  }
  return try InstanceLock(files: files, name: name)
}

@Test func lockExcludesSecondOwnerUntilDescriptorCloses() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  var first: InstanceLock? = try InstanceLock(files: files, name: "owner.lock")
  #expect(first != nil)
  #expect(throws: (any Error).self) { _ = try InstanceLock(files: files, name: "owner.lock") }
  first = nil
  _ = try acquireReleasedLock(files: files, name: "owner.lock")
}

@Test func onlyTheOwnerLockIsAnInstanceLock() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  for name in ["control.lock", "restore.json", ""] {
    var invalid = false
    do { _ = try InstanceLock(files: files, name: name) } catch RuntimeError.invalid {
      invalid = true
    } catch {}
    #expect(invalid, "\(name)")
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func writerPersistsRunningAndReceiptAroundFakeInvocation() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  let owner = try InstanceLock(files: files, name: "owner.lock")
  var record = JournalRecord(run: 1, build: testBuild)
  record.audio.nextId = 3
  record.audio.restoreRequired = true
  record.audio.phase = .prepared
  record.audio.active = AudioCommand(id: 2, target: .mono)
  try files.persist(record: record)
  let command = try JSONDecoder().decode(
    WriterCommand.self,
    from: Data(
      #"{"run":1,"id":2,"context":{"routeEpoch":1,"streamEpoch":1,"connectionEpoch":1,"deviceOrdinal":1},"target":"mono","recovery":false}"#
        .utf8))
  let receipt = DurableWriter.execute(command: command, files: files, owner: owner) { target in
    #expect(target == .mono)
    guard case .record(let running) = files.load() else {
      Issue.record("missing journal")
      return 1
    }
    #expect(running.audio.phase == .running)
    return 0
  }
  #expect(receipt.persisted && receipt.quiescent && receipt.exitCode == 0)
  guard case .record(let completed) = files.load() else {
    Issue.record("missing receipt")
    return
  }
  #expect(completed.audio.phase == .completed && completed.audio.restoreRequired)
  #expect(completed.audio.lastCompleted?.id == 2)
}

@Test func writerDoesNotExecuteWhenRunningCannotPersist() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  let owner = try InstanceLock(files: files, name: "owner.lock")
  var record = JournalRecord(run: 1, build: testBuild)
  record.audio.nextId = 3
  record.audio.restoreRequired = true
  record.audio.phase = .prepared
  record.audio.active = AudioCommand(id: 2, target: .stereo)
  try files.persist(record: record)
  let failing = try AtomicRuntimeFiles(
    directory: root, before: { _ in throw ContractError.invalid })
  let command = try JSONDecoder().decode(
    WriterCommand.self, from: Data(#"{"run":1,"id":2,"target":"stereo","recovery":true}"#.utf8))
  var invoked = false
  let receipt = DurableWriter.execute(command: command, files: failing, owner: owner) { _ in
    invoked = true
    return 0
  }
  #expect(!invoked && !receipt.persisted)
}

@MainActor @Test func fifoConsumesQueuedInvalidationBeforeWriterDrain() throws {
  var commands: [EngineAction] = []
  let now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:00Z"))
  let fifo = EngineFIFO(
    engine: Engine(
      build: testBuild, run: 1, boot: "00000000-0000-4000-8000-000000000001"),
    clock: { now },
    execute: { action, reply in
      commands.append(action)
      if case .persist(let request) = action {
        reply(.persistenceAcknowledged(run: 1, id: request.id, success: true))
      }
    }
  )
  fifo.enqueue(.journalLoaded(.missing))
  fifo.enqueue(.automation(false))
  fifo.flush()
  #expect(!commands.contains { if case .writeTarget = $0 { true } else { false } })
  #expect(fifo.snapshot.operational)
}

@Test func diagnosticRotationPreservesWholePrivateLines() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  let log = DiagnosticLog(files: files, maximumBytes: 400)
  let utc = try SourceTime("2026-01-01T00:00:00Z")
  for seq: UInt64 in 1...4 {
    try log.append(
      TraceRecord(
        build: testBuild, run: 1, seq: seq, m: seq,
        payload: .end(EndPayload(utc: utc, exitCode: 0))))
  }
  for name in ["trace-v2.jsonl", "trace-v2.jsonl.1"] {
    let loaded = try files.read(name)
    let data = try #require(loaded)
    #expect(data.last == 10)
    for line in data.split(separator: 10) { _ = try TraceRecord.decode(Data(line)) }
  }
}

@Test func failedReceiptAfterFakeEffectCannotClaimRecoveryComplete() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  let owner = try InstanceLock(files: files, name: "owner.lock")
  var record = JournalRecord(run: 1, build: testBuild)
  record.audio.nextId = 3
  record.audio.restoreRequired = true
  record.audio.phase = .prepared
  record.audio.active = AudioCommand(id: 2, target: .stereo)
  try files.persist(record: record)
  let marker = root.appendingPathComponent("effect")
  let failing = try AtomicRuntimeFiles(
    directory: root,
    before: { _ in
      if FileManager.default.fileExists(atPath: marker.path) { throw ContractError.invalid }
    })
  let command = try JSONDecoder().decode(
    WriterCommand.self, from: Data(#"{"run":1,"id":2,"target":"stereo","recovery":true}"#.utf8))
  let receipt = DurableWriter.execute(command: command, files: failing, owner: owner) { _ in
    try Data("fake Stereo".utf8).write(to: marker)
    return 0
  }
  #expect(!receipt.persisted)
  guard case .record(let saved) = files.load() else {
    Issue.record("journal missing")
    return
  }
  #expect(saved.audio.phase == .running && saved.audio.restoreRequired)
}

@MainActor @Test func preparedAckReevaluatesInputsQueuedBeforeDelegation() throws {
  let now = Instant(continuousNanos: 5_000_000_000, utc: try SourceTime("2026-01-01T00:00:05Z"))
  var actions: [EngineAction] = []
  let fifo = EngineFIFO(
    engine: Engine(
      build: testBuild, run: 1, boot: "00000000-0000-4000-8000-000000000001"),
    clock: { now },
    execute: { action, reply in
      actions.append(action)
      if case .persist(let request) = action {
        reply(.persistenceAcknowledged(run: 1, id: request.id, success: true))
        if request.record.audio.phase == .prepared { reply(.automation(false)) }
      }
    })
  fifo.enqueue(.journalLoaded(.missing))
  fifo.flush()
  fifo.enqueue(
    .audioObserved(AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)))
  fifo.enqueue(.route(Route(epoch: 1, deviceOrdinal: 1)))
  fifo.enqueue(.connection(Connection(epoch: 1, boundary: try SourceTime("2026-01-01T00:00:00Z"))))
  fifo.enqueue(.streamStarted(epoch: 1, nonce: "test"))
  fifo.enqueue(.heartbeat(epoch: 1, nonce: "test", sequence: 1))
  fifo.enqueue(
    .observation(
      Observation(
        sourceTime: now.utc, source: .s1, provenance: .live,
        context: ObservationContext(
          routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1),
        receivedContinuousNanos: now.continuousNanos, value: .count(1, detection: .on))))
  fifo.flush()
  #expect(
    actions.contains {
      if case .persist(let request) = $0 { request.record.audio.phase == .prepared } else { false }
    })
  #expect(!actions.contains { if case .writeTarget = $0 { true } else { false } })
}

@Test func systemClockFormatsCurrentUTCWithNanoseconds() {
  let instant = SystemClock.now()
  #expect(instant.utc.raw.count == 30 && instant.utc.raw.hasSuffix("Z"))
  #expect(abs(Double(instant.utc.nanos) / 1e9 - Date().timeIntervalSince1970) < 5)
}
