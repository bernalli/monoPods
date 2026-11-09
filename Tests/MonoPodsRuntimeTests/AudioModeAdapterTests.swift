import CoreAudio
import Foundation
import Testing

@testable import MonoPodsCore
@testable import MonoPodsRuntime

private final class FakeAudioHardware: AudioHardware, @unchecked Sendable {
  struct State {
    var reading = AudioHardwareReading(status: 0, rawValue: 0, byteCount: 4)
    var afterSet: AudioHardwareReading?
    var has = AudioPropertyCheck(status: 0, value: true)
    var settable = AudioPropertyCheck(status: 0, value: true)
    var setStatus: Int32 = 0
    var preference: Any? = false
    var preferenceReads = 0
    var enableOnSecondRead = false
    var inlineAdd = false
    var inlineAddProperty: AudioHardwareProperty?
    var resetsDuringAdd = 0
    var resetAfterNextAdd = false
    var resetDuringModeAdd = false
    var inlineSet = false
    var inlineSetProperty: AudioHardwareProperty = .mode
    var duringSet: (@Sendable () -> Void)?
    var preferencePhases: [JournalPhase] = []
    var addErrors: [AudioHardwareProperty: Int32] = [:]
    var removeError: Int32 = 0
    var listeners: [AudioHardwareProperty: AudioHardwareListener] = [:]
    var oldListeners: [AudioHardwareListener] = []
    var events: [String] = []
    var writes: [UInt32] = []
    var mainAccess = false
    var runningAtSet = false
    var files: AtomicRuntimeFiles?
  }
  private let lock = NSLock()
  private var state = State()
  func access<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }
  private func note(_ name: String) {
    access {
      $0.events.append(name)
      $0.mainAccess = $0.mainAccess || Thread.isMainThread
    }
  }
  func hasMode() -> AudioPropertyCheck {
    note("has")
    return access { $0.has }
  }
  func modeIsSettable() -> AudioPropertyCheck {
    note("settable")
    return access { $0.settable }
  }
  func readMode() -> AudioHardwareReading {
    note("get")
    return access { $0.reading }
  }
  func readSystemMono() -> SystemMono {
    note("preference")
    return access {
      $0.preferenceReads += 1
      if let files = $0.files, case .record(let record) = files.load() {
        $0.preferencePhases.append(record.audio.phase)
      }
      if $0.enableOnSecondRead && $0.preferenceReads == 2 { $0.preference = true }
      return SystemMonoPreference.decode($0.preference, synchronized: true)
    }
  }
  func setMode(_ value: UInt32) -> Int32 {
    note("set")
    let (status, callback, duringSet) = access { state in
      state.writes.append(value)
      if let files = state.files, case .record(let record) = files.load() {
        state.runningAtSet = record.audio.phase == .running
      }
      if let afterSet = state.afterSet {
        state.reading = afterSet
      } else if state.setStatus == 0 {
        state.reading = AudioHardwareReading(status: 0, rawValue: value, byteCount: 4)
      }
      return (
        state.setStatus, state.inlineSet ? state.listeners[state.inlineSetProperty] : nil,
        state.duringSet
      )
    }
    duringSet?()
    callback?.callback()
    return status
  }
  func addListener(_ listener: AudioHardwareListener) -> Int32 {
    note("add-\(listener.property)")
    let (status, inline, restart) = access { state in
      state.oldListeners.append(listener)
      let status = state.addErrors[listener.property] ?? 0
      if status == 0 { state.listeners[listener.property] = listener }
      let resetDuringAdd = listener.property == .serviceRestarted && state.resetsDuringAdd > 0
      var restart: AudioHardwareListener?
      let resetOnMode = listener.property == .mode && state.resetDuringModeAdd
      if status == 0 && (resetDuringAdd || state.resetAfterNextAdd || resetOnMode) {
        if resetDuringAdd { state.resetsDuringAdd -= 1 }
        if resetOnMode { state.resetDuringModeAdd = false }
        state.resetAfterNextAdd = false
        restart = state.listeners[.serviceRestarted]
        state.listeners.removeAll()
      }
      let inline =
        state.inlineAdd
        && (state.inlineAddProperty == nil || state.inlineAddProperty == listener.property)
      return (status, inline, restart)
    }
    if inline { listener.callback() }
    restart?.callback()
    return status
  }
  func removeListener(_ listener: AudioHardwareListener) -> Int32 {
    note("remove-\(listener.property)")
    return access {
      if $0.listeners[listener.property] === listener { $0.listeners[listener.property] = nil }
      return $0.removeError
    }
  }
  func fire(_ property: AudioHardwareProperty) { access { $0.listeners[property] }?.callback() }
}

private final class FakeAudioScheduler: AudioAdapterScheduler, @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [(TimeInterval, @Sendable () -> Void)] = []
  func after(_ delay: TimeInterval, perform: @escaping @Sendable () -> Void) {
    lock.withLock { pending.append((delay, perform)) }
  }
  var delays: [TimeInterval] { lock.withLock { pending.map(\.0) } }
  func advance() {
    let callbacks = lock.withLock {
      let copy = pending
      pending.removeAll()
      return copy
    }
    for (_, callback) in callbacks { callback() }
  }
}

@MainActor private final class AudioEvents {
  var readings: [AudioReading] = []
  var order: [String] = []
  var onMain = true
  var results: [AudioWriteResult] = []
  func observe(_ reading: AudioReading) {
    onMain = onMain && Thread.isMainThread
    readings.append(reading)
    order.append("reading")
  }
}

@MainActor private struct AudioFixture {
  let hardware = FakeAudioHardware()
  let scheduler = FakeAudioScheduler()
  let queue = DispatchQueue(label: "audio-test")
  let events = AudioEvents()
  let adapter: AudioModeAdapter
  let root: URL
  let files: AtomicRuntimeFiles
  let owner: InstanceLock
  let command = WriterCommand(run: 1, id: 1, context: nil, target: .stereo, recovery: true)
  init() throws {
    root = try temporaryRuntime()
    files = try AtomicRuntimeFiles(directory: root)
    owner = try InstanceLock(files: files, name: "owner.lock")
    var record = JournalRecord(run: 1, build: testBuild)
    record.audio.nextId = 2
    record.audio.restoreRequired = true
    record.audio.phase = .prepared
    record.audio.active = AudioCommand(id: 1, target: .stereo)
    try files.persist(record: record)
    adapter = AudioModeAdapter(hardware: hardware, queue: queue, scheduler: scheduler)
    hardware.access { $0.files = files }
  }
  func start() async {
    adapter.start { [events] in events.observe($0) }
    await settle()
  }
  func settle() async {
    // Two barriers also drain work queued by inline listener callbacks.
    for _ in 0..<2 {
      await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
  }
  func apply(_ command: WriterCommand? = nil, files: AtomicRuntimeFiles? = nil) async
    -> AudioWriteResult
  {
    await withCheckedContinuation { continuation in
      adapter.apply(command ?? self.command, files: files ?? self.files, owner: owner) { result in
        events.order.append("completion")
        continuation.resume(returning: result)
      }
    }
  }
  func close() async {
    adapter.stop()
    await settle()
    try? FileManager.default.removeItem(at: root)
  }
}

@Test @MainActor func audioReadsNormalizeAllNonzeroValuesAndPreserveErrors() async throws {
  let fixture = try AudioFixture()
  await fixture.start()
  for raw: UInt32 in [0, 1, 2, .max] {
    fixture.hardware.access {
      $0.reading = AudioHardwareReading(status: 0, rawValue: raw, byteCount: 4)
    }
    fixture.adapter.refresh(rearm: false)
    await fixture.settle()
    #expect(fixture.events.readings.last?.mode == (raw == 0 ? .stereo : .mono))
    #expect(fixture.events.readings.last?.status == 0)
  }
  for status: Int32 in [.min, -1, .max] {
    fixture.hardware.access {
      $0.reading = AudioHardwareReading(status: status, rawValue: 1, byteCount: 4)
    }
    fixture.adapter.refresh(rearm: false)
    await fixture.settle()
    #expect(fixture.events.readings.last?.mode == nil)
    #expect(fixture.events.readings.last?.status == status)
  }
  let generations = fixture.events.readings.map(\.generation)
  #expect(!generations.isEmpty)
  #expect(generations == (0..<generations.count).map { UInt64($0) + 1 })
  #expect(fixture.events.onMain)
  #expect(!fixture.hardware.access { $0.mainAccess })
  await fixture.close()
}

@Test @MainActor func audioWritesRequireEveryPreconditionAndExactReadback() async throws {
  // Each mutation removes one necessary condition for a successful transaction.
  for fault in 0..<10 {
    let fixture = try AudioFixture()
    await fixture.start()
    let expected: Int32
    switch fault {
    case 0:
      fixture.hardware.access { $0.has = AudioPropertyCheck(status: 0, value: false) }
      expected = kAudioHardwareUnknownPropertyError
    case 1:
      fixture.hardware.access { $0.has = AudioPropertyCheck(status: .min, value: true) }
      expected = .min
    case 2:
      fixture.hardware.access { $0.settable = AudioPropertyCheck(status: 0, value: false) }
      expected = kAudioHardwareIllegalOperationError
    case 3:
      fixture.hardware.access { $0.settable = AudioPropertyCheck(status: .max, value: true) }
      expected = .max
    case 4:
      fixture.hardware.access {
        $0.reading = AudioHardwareReading(status: 0, rawValue: 0, byteCount: 8)
      }
      expected = kAudioHardwareBadPropertySizeError
    case 5:
      fixture.hardware.access {
        $0.reading = AudioHardwareReading(status: .min, rawValue: 0, byteCount: 8)
      }
      expected = .min
    case 6:
      fixture.hardware.access {
        $0.setStatus = .max
        $0.afterSet = AudioHardwareReading(status: .min, rawValue: 0, byteCount: 4)
      }
      expected = .max
    case 7:
      fixture.hardware.access {
        $0.afterSet = AudioHardwareReading(status: .min, rawValue: 0, byteCount: 4)
      }
      expected = .min
    case 8:
      fixture.hardware.access {
        $0.afterSet = AudioHardwareReading(status: 0, rawValue: 0, byteCount: 3)
      }
      expected = kAudioHardwareBadPropertySizeError
    default:
      fixture.hardware.access {
        $0.afterSet = AudioHardwareReading(status: 0, rawValue: 1, byteCount: 4)
      }
      expected = kAudioHardwareUnspecifiedError
    }
    guard case .completed(let receipt) = await fixture.apply() else {
      Issue.record("Expected failed receipt")
      await fixture.close()
      continue
    }
    #expect(receipt.exitCode == expected)
    #expect(receipt.command == fixture.command && receipt.persisted && receipt.quiescent)
    #expect(fixture.hardware.access { $0.writes.count } == (fault < 6 ? 0 : 1))
    guard case .record(let journal) = fixture.files.load() else {
      Issue.record("Missing journal")
      await fixture.close()
      continue
    }
    #expect(journal.audio.lastCompleted?.exitCode == expected)
    #expect(journal.audio.restoreRequired)
    await fixture.close()
  }
}

@Test @MainActor func audioSizeFailuresNeverBecomeObservationsOrAuthorizeSet() async throws {
  for size: UInt32 in [0, 1, 3, 5, 8, .max] {
    let fixture = try AudioFixture()
    fixture.hardware.access {
      $0.reading = AudioHardwareReading(status: 0, rawValue: 0, byteCount: size)
    }
    await fixture.start()
    #expect(fixture.events.readings.last?.status == kAudioHardwareBadPropertySizeError)
    #expect(fixture.events.readings.last?.mode == nil)
    guard case .completed(let receipt) = await fixture.apply() else {
      Issue.record("Expected size error")
      await fixture.close()
      continue
    }
    #expect(receipt.exitCode == kAudioHardwareBadPropertySizeError)
    #expect(fixture.hardware.access { $0.writes.isEmpty })
    await fixture.close()
  }
}

@Test @MainActor func audioSuccessIsDurableAndUsesOneOrZeroWithNonzeroReadback() async throws {
  for target: Target in [.mono, .stereo] {
    let fixture = try AudioFixture()
    var command = fixture.command
    command.target = target
    command.recovery = target == .stereo
    command.context = ObservationContext(
      routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1)
    guard case .record(var journal) = fixture.files.load() else { throw RuntimeError.invalid }
    journal.audio.active = AudioCommand(id: 1, target: target)
    try fixture.files.persist(record: journal)
    if target == .mono {
      fixture.hardware.access {
        $0.afterSet = AudioHardwareReading(status: 0, rawValue: .max, byteCount: 4)
      }
    }
    await fixture.start()
    guard case .completed(let receipt) = await fixture.apply(command) else {
      Issue.record("Expected receipt")
      await fixture.close()
      continue
    }
    #expect(receipt.exitCode == 0 && receipt.quiescent && receipt.persisted)
    #expect(fixture.hardware.access { $0.writes } == [target == .mono ? 1 : 0])
    #expect(fixture.hardware.access { $0.runningAtSet })
    let events = fixture.hardware.access { $0.events }
    let set = try #require(events.firstIndex(of: "set"))
    #expect(
      Array(events[(set - 4)...(set + 1)])
        == ["has", "settable", "get", "preference", "set", "get"])
    guard case .record(let completed) = fixture.files.load() else { throw RuntimeError.invalid }
    #expect(completed.audio.lastCompleted?.target == target)
    #expect(completed.audio.restoreRequired == (target == .mono))
    #expect(!fixture.hardware.access { $0.mainAccess })
    await fixture.close()
  }
}

@Test func systemMonoPreferenceAcceptsOnlyBooleansAndExactZeroOrOne() {
  let cases: [(Any?, SystemMono)] = [
    (true, .on), (false, .off), (0, .off), (1, .on), (2, .unreadable), (-1, .unreadable),
    (1.0, .unreadable), (0.0, .unreadable),
    (1.5, .unreadable), ("1", .unreadable), ([], .unreadable), (["value": 1], .unreadable),
    (nil, .unreadable), (NSNull(), .unreadable), (Int64.max, .unreadable),
    (UInt64.max, .unreadable),
  ]
  for (value, expected) in cases {
    #expect(SystemMonoPreference.decode(value, synchronized: true) == expected)
    #expect(SystemMonoPreference.decode(value, synchronized: false) == .unreadable)
  }
}

@Test @MainActor func systemMonoSkipsBeforeRunningAndImmediatelyBeforeSet() async throws {
  for afterRunning in [false, true] {
    let fixture = try AudioFixture()
    await fixture.start()
    fixture.hardware.access {
      $0.preferenceReads = 0
      $0.preferencePhases.removeAll()
      $0.preference = !afterRunning
      $0.enableOnSecondRead = afterRunning
    }
    guard case .systemMono(let command) = await fixture.apply() else {
      Issue.record("Expected correlated skip")
      await fixture.close()
      continue
    }
    #expect(command == fixture.command)
    #expect(fixture.hardware.access { $0.writes.isEmpty })
    #expect(fixture.events.readings.last?.systemMono == .on)
    guard case .record(let journal) = fixture.files.load() else { throw RuntimeError.invalid }
    #expect(journal.audio.lastCompleted == nil)
    #expect(journal.audio.restoreRequired)
    #expect(journal.audio.phase == (afterRunning ? .running : .prepared))
    #expect(
      fixture.hardware.access { $0.preferencePhases }
        == (afterRunning ? [.prepared, .running] : [.prepared]))
    await fixture.close()
  }
}

@Test @MainActor func unreadablePreferenceAllowsWritingAndRefreshReadsFreshPreference() async throws
{
  let fixture = try AudioFixture()
  fixture.hardware.access { $0.preference = "unavailable" }
  await fixture.start()
  #expect(fixture.events.readings.last?.systemMono == .unreadable)
  guard case .completed(let receipt) = await fixture.apply() else { throw RuntimeError.invalid }
  #expect(receipt.exitCode == 0)
  fixture.hardware.access { $0.preference = true }
  fixture.adapter.refresh(rearm: false)
  await fixture.settle()
  #expect(fixture.events.readings.last?.systemMono == .on)
  fixture.hardware.access { $0.preference = false }
  fixture.adapter.refresh(rearm: false)
  await fixture.settle()
  #expect(fixture.events.readings.last?.systemMono == .off)
  await fixture.close()
}

@Test @MainActor func synchronousSetCallbackIsQueuedAfterCompletionAndSchedulesOnlyOneFollowup()
  async throws
{
  let fixture = try AudioFixture()
  await fixture.start()
  fixture.events.order.removeAll()
  fixture.hardware.access { $0.inlineSet = true }
  _ = await fixture.apply()
  await fixture.settle()
  #expect(fixture.events.order == ["completion", "reading"])
  #expect(fixture.scheduler.delays == [1])
  fixture.scheduler.advance()
  await fixture.settle()
  #expect(fixture.events.order == ["completion", "reading", "reading"])
  #expect(fixture.scheduler.delays.isEmpty)
  await fixture.close()
}

@Test @MainActor func rearmReplacesBothListenersEvenWhenRemovalFailsOrBackendLosesThem()
  async throws
{
  let fixture = try AudioFixture()
  await fixture.start()
  for reset in [false, true] {
    let stale = fixture.hardware.access { state in
      let old = Array(state.listeners.values)
      state.listeners.removeAll()
      state.events.removeAll()
      state.removeError = kAudioHardwareBadObjectError
      return old
    }
    if reset {
      stale.first { $0.property == .serviceRestarted }?.callback()
    } else {
      fixture.adapter.refresh(rearm: true)
    }
    await fixture.settle()
    let events = fixture.hardware.access { $0.events }
    #expect(events.filter { $0.hasPrefix("remove-") }.count == 2)
    #expect(events.filter { $0.hasPrefix("add-") }.count == 2)
    #expect(fixture.hardware.access { $0.listeners.count } == 2)
    #expect(fixture.events.readings.last?.status == 0)
    let before = fixture.events.readings.count
    for listener in stale { listener.callback() }
    await fixture.settle()
    #expect(fixture.events.readings.count == before)
  }
  await fixture.close()
}

@Test @MainActor func resetDuringListenerInstallationRestoresBothSubscriptions() async throws {
  let fixture = try AudioFixture()
  fixture.hardware.access { $0.resetsDuringAdd = 1 }
  await fixture.start()
  #expect(fixture.hardware.access { $0.listeners.count } == 2)
  #expect(fixture.events.readings.last?.status == 0)
  let beforeMode = fixture.events.readings.count
  fixture.hardware.access {
    $0.reading = AudioHardwareReading(status: 0, rawValue: 1, byteCount: 4)
  }
  fixture.hardware.fire(.mode)
  await fixture.settle()
  #expect(fixture.events.readings.count == beforeMode + 1)
  #expect(fixture.events.readings.last?.mode == .mono)
  fixture.hardware.access { $0.events.removeAll() }
  fixture.hardware.fire(.serviceRestarted)
  await fixture.settle()
  #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("add-") }.count } == 2)
  #expect(fixture.hardware.access { $0.listeners.count } == 2)
  #expect(!fixture.hardware.access { $0.mainAccess })
  await fixture.close()
}

@Test @MainActor func resetBetweenListenerAddsPreservesBothSubscriptions() async throws {
  for rearming in [false, true] {
    let fixture = try AudioFixture()
    if rearming { await fixture.start() }
    fixture.hardware.access { $0.resetAfterNextAdd = true }
    if rearming {
      fixture.adapter.refresh(rearm: true)
      await fixture.settle()
    } else {
      await fixture.start()
    }
    #expect(fixture.hardware.access { $0.listeners.count } == 2)
    #expect(fixture.events.readings.last?.status == 0)
    let beforeMode = fixture.events.readings.count
    fixture.hardware.access {
      $0.reading = AudioHardwareReading(status: 0, rawValue: 1, byteCount: 4)
    }
    fixture.hardware.fire(.mode)
    await fixture.settle()
    #expect(fixture.events.readings.count == beforeMode + 1)
    #expect(fixture.events.readings.last?.mode == .mono)
    fixture.hardware.access { $0.events.removeAll() }
    fixture.hardware.fire(.serviceRestarted)
    await fixture.settle()
    #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("add-") }.count } == 2)
    #expect(fixture.hardware.access { $0.listeners.count } == 2)
    await fixture.close()
  }
}

@Test @MainActor func repeatedInlineInstallationResetsFailBoundedlyAndRecoverOnRefresh()
  async throws
{
  let fixture = try AudioFixture()
  fixture.hardware.access { $0.resetsDuringAdd = .max }
  await fixture.start()
  #expect(fixture.events.readings.last?.status == kAudioHardwareUnspecifiedError)
  #expect(fixture.events.readings.last?.mode == nil)
  #expect(fixture.hardware.access { $0.listeners.isEmpty })
  #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("add-") }.count } <= 4)
  #expect(fixture.scheduler.delays.isEmpty)
  fixture.hardware.access { $0.resetsDuringAdd = 0 }
  fixture.adapter.refresh(rearm: true)
  await fixture.settle()
  #expect(fixture.hardware.access { $0.listeners.count } == 2)
  #expect(fixture.events.readings.last?.status == 0)
  let before = fixture.events.readings.count
  fixture.hardware.fire(.mode)
  await fixture.settle()
  #expect(fixture.events.readings.count == before + 1)
  await fixture.close()
}

@Test @MainActor func partialRegistrationRollsBackAndCanRecoverWithoutPolling() async throws {
  for property: AudioHardwareProperty in [.mode, .serviceRestarted] {
    let fixture = try AudioFixture()
    fixture.hardware.access {
      $0.addErrors[property] = .min
      $0.inlineAdd = true
    }
    await fixture.start()
    #expect(fixture.hardware.access { $0.listeners.isEmpty })
    #expect(fixture.events.readings.last?.status == .min)
    #expect(fixture.events.readings.last?.mode == nil)
    #expect(fixture.scheduler.delays.isEmpty)
    fixture.hardware.access {
      $0.addErrors.removeAll()
      $0.inlineAdd = false
    }
    fixture.adapter.refresh(rearm: true)
    await fixture.settle()
    #expect(fixture.hardware.access { $0.listeners.count } == 2)
    #expect(fixture.events.readings.last?.status == 0)
    await fixture.close()
  }
}

@Test @MainActor func stopInvalidatesInlineDuplicateAndDelayedCallbacksAcrossRestart() async throws
{
  let fixture = try AudioFixture()
  fixture.hardware.access {
    $0.inlineAdd = true
    $0.inlineAddProperty = .mode
  }
  await fixture.start()
  #expect(fixture.hardware.access { $0.listeners[.mode] != nil })
  #expect(fixture.hardware.access { $0.listeners[.serviceRestarted] != nil })
  #expect(fixture.events.readings.last?.status == 0)
  let afterStart = fixture.events.readings.count
  let old = fixture.hardware.access { $0.oldListeners }
  fixture.hardware.fire(.mode)
  fixture.hardware.fire(.mode)
  await fixture.settle()
  #expect(fixture.events.readings.count == afterStart + 2)
  #expect(fixture.scheduler.delays == [1, 1, 1])
  fixture.adapter.stop()
  let before = fixture.events.readings.count
  for listener in old { listener.callback() }
  fixture.scheduler.advance()
  await fixture.settle()
  #expect(fixture.events.readings.count == before)
  #expect(fixture.hardware.access { $0.listeners.isEmpty })
  fixture.hardware.access { $0.inlineAdd = false }
  await fixture.start()
  let generation = try #require(fixture.events.readings.last?.generation)
  for listener in old { listener.callback() }
  await fixture.settle()
  #expect(fixture.events.readings.last?.generation == generation)
  fixture.hardware.fire(.mode)
  await fixture.settle()
  #expect(fixture.events.readings.last?.generation == generation + 1)
  await fixture.close()
}

@Test @MainActor func audioStatusFailuresKeepTheFirstErrorAtEveryBoundary() async throws {
  for status: Int32 in [.min, -1, .max] {
    for boundary in 0..<5 {
      let fixture = try AudioFixture()
      await fixture.start()
      fixture.hardware.access {
        switch boundary {
        case 0: $0.has = AudioPropertyCheck(status: status, value: false)
        case 1: $0.settable = AudioPropertyCheck(status: status, value: false)
        case 2: $0.reading = AudioHardwareReading(status: status, rawValue: 0, byteCount: 0)
        case 3:
          $0.setStatus = status
          $0.afterSet = AudioHardwareReading(status: -2, rawValue: 0, byteCount: 0)
        default: $0.afterSet = AudioHardwareReading(status: status, rawValue: 0, byteCount: 0)
        }
      }
      guard case .completed(let receipt) = await fixture.apply() else { throw RuntimeError.invalid }
      #expect(receipt.exitCode == status && receipt.quiescent && receipt.persisted)
      #expect(fixture.hardware.access { $0.writes.count } == (boundary < 3 ? 0 : 1))
      await fixture.close()
    }
  }
}

@Test @MainActor func audioWritesNeverRunWithoutDurableRunningOrInventDurableCompletion()
  async throws
{
  for failAfterSet in [false, true] {
    let fixture = try AudioFixture()
    await fixture.start()
    let hardware = fixture.hardware
    let failing = try AtomicRuntimeFiles(
      directory: fixture.root,
      before: { _ in
        if !failAfterSet || hardware.access({ !$0.writes.isEmpty }) { throw RuntimeError.invalid }
      })
    guard case .completed(let receipt) = await fixture.apply(files: failing) else {
      throw RuntimeError.invalid
    }
    #expect(receipt.quiescent == failAfterSet)
    #expect(!receipt.persisted)
    #expect(fixture.hardware.access { $0.writes.count } == (failAfterSet ? 1 : 0))
    guard case .record(let journal) = fixture.files.load() else { throw RuntimeError.invalid }
    #expect(journal.audio.phase == (failAfterSet ? .running : .prepared))
    #expect(journal.audio.restoreRequired && journal.audio.lastCompleted == nil)
    await fixture.close()
  }
}

@Test @MainActor func foreignAndRepeatedAudioCommandsCannotInvokeHardwareAgain() async throws {
  let fixture = try AudioFixture()
  await fixture.start()
  var foreign = fixture.command
  foreign.id += 1
  guard case .completed(let rejected) = await fixture.apply(foreign) else {
    throw RuntimeError.invalid
  }
  #expect(!rejected.persisted && !rejected.quiescent)
  #expect(fixture.hardware.access { $0.writes.isEmpty })
  guard case .completed(let completed) = await fixture.apply() else { throw RuntimeError.invalid }
  #expect(completed.exitCode == 0 && completed.persisted)
  guard case .completed(let repeated) = await fixture.apply() else { throw RuntimeError.invalid }
  #expect(!repeated.persisted && !repeated.quiescent)
  #expect(fixture.hardware.access { $0.writes } == [0])
  await fixture.close()
}

@Test @MainActor func serviceRestartInsideSetRearmsAfterCompletion() async throws {
  let fixture = try AudioFixture()
  await fixture.start()
  fixture.events.order.removeAll()
  fixture.hardware.access {
    $0.events.removeAll()
    $0.inlineSet = true
    $0.inlineSetProperty = .serviceRestarted
  }
  _ = await fixture.apply()
  await fixture.settle()
  #expect(fixture.events.order == ["completion", "reading"])
  #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("remove-") }.count } == 2)
  #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("add-") }.count } == 2)
  #expect(fixture.scheduler.delays.isEmpty)
  await fixture.close()
}

@Test @MainActor func stopReturnsWhileSetIsInFlightAndSuppressesItsLateObservations() async throws {
  let fixture = try AudioFixture()
  await fixture.start()
  let release = DispatchSemaphore(value: 0)
  let before = fixture.events.readings.count
  await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
    fixture.hardware.access {
      $0.inlineSet = true
      $0.duringSet = {
        entered.resume()
        #expect(release.wait(timeout: .now() + 5) == .success)
      }
    }
    fixture.adapter.apply(fixture.command, files: fixture.files, owner: fixture.owner) { result in
      fixture.events.results.append(result)
    }
  }
  fixture.adapter.stop()
  fixture.adapter.refresh(rearm: true)
  release.signal()
  await fixture.settle()
  #expect(fixture.events.readings.count == before)
  #expect(fixture.events.results.count == 1)
  guard case .completed(let receipt) = fixture.events.results.first else {
    throw RuntimeError.invalid
  }
  #expect(receipt.exitCode == 0 && receipt.quiescent && receipt.persisted)
  #expect(fixture.hardware.access { $0.writes } == [0])
  #expect(!fixture.hardware.access { $0.mainAccess })
  await fixture.close()
}

@Test @MainActor func audioWritesRequireAnActiveAdapterAndLeaveThePreparedJournal() async throws {
  for started in [false, true] {
    let fixture = try AudioFixture()
    if started {
      await fixture.start()
      fixture.adapter.stop()
    }
    guard case .completed(let receipt) = await fixture.apply() else { throw RuntimeError.invalid }
    #expect(receipt.command == fixture.command)
    #expect(!receipt.quiescent && !receipt.persisted)
    #expect(fixture.hardware.access { $0.writes.isEmpty })
    guard case .record(let journal) = fixture.files.load() else { throw RuntimeError.invalid }
    #expect(journal.audio.phase == .prepared && journal.audio.lastCompleted == nil)
    await fixture.close()
  }
}

@Test @MainActor func malformedLifecycleCallsPublishNothingAndKeepOneRegistration() async throws {
  let fixture = try AudioFixture()
  let events = fixture.events
  fixture.adapter.refresh(rearm: true)
  fixture.adapter.stop()
  fixture.adapter.stop()
  await fixture.settle()
  #expect(events.readings.isEmpty)
  #expect(fixture.hardware.access { $0.events.isEmpty })
  await fixture.start()
  let first = fixture.hardware.access { $0.oldListeners }
  fixture.adapter.start { events.observe($0) }
  await fixture.settle()
  #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("add-") }.count } == 4)
  #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("remove-") }.count } == 2)
  let before = events.readings.count
  for listener in first { listener.callback() }
  await fixture.settle()
  #expect(events.readings.count == before)
  fixture.hardware.fire(.mode)
  await fixture.settle()
  #expect(events.readings.count == before + 1)
  await fixture.close()
}

@Test @MainActor func resetDuringModeListenerInstallationRetriesBothSubscriptions() async throws {
  let fixture = try AudioFixture()
  fixture.hardware.access { $0.resetDuringModeAdd = true }
  await fixture.start()
  #expect(fixture.hardware.access { $0.events.filter { $0.hasPrefix("add-") }.count } == 4)
  #expect(fixture.hardware.access { $0.listeners.count } == 2)
  #expect(fixture.events.readings.last?.status == 0)
  await fixture.close()
}

@Test @MainActor func observationsReportMissingPropertyWithoutReadingItsValue() async throws {
  let cases: [(AudioPropertyCheck, Int32)] = [
    (AudioPropertyCheck(status: 0, value: false), kAudioHardwareUnknownPropertyError),
    (AudioPropertyCheck(status: .min, value: true), .min),
  ]
  for (check, expected) in cases {
    let fixture = try AudioFixture()
    fixture.hardware.access {
      $0.has = check
      $0.reading = AudioHardwareReading(status: 0, rawValue: 1, byteCount: 4)
    }
    await fixture.start()
    #expect(fixture.events.readings.last?.mode == nil)
    #expect(fixture.events.readings.last?.status == expected)
    #expect(!fixture.hardware.access { $0.events.contains("get") })
    await fixture.close()
  }
}

@Test @MainActor func modeFollowupSurvivesARearm() async throws {
  let fixture = try AudioFixture()
  await fixture.start()
  fixture.hardware.fire(.mode)
  await fixture.settle()
  fixture.adapter.refresh(rearm: true)
  await fixture.settle()
  let before = fixture.events.readings.count
  fixture.hardware.access { $0.preference = true }
  fixture.scheduler.advance()
  await fixture.settle()
  #expect(fixture.events.readings.count == before + 1)
  #expect(fixture.events.readings.last?.systemMono == .on)
  await fixture.close()
}

@Test @MainActor func selfCheckUsesOnlyFakeReadOperationsAndRejectsEveryUnavailableProperty() async
{
  let hardware = FakeAudioHardware()
  #expect(await AudioModeAdapter.checkReadiness(hardware: hardware))
  for fault in 0..<5 {
    let broken = FakeAudioHardware()
    broken.access {
      switch fault {
      case 0: $0.has.value = false
      case 1: $0.has.status = -1
      case 2: $0.settable.value = false
      case 3: $0.reading.status = -1
      default: $0.reading.byteCount = 8
      }
    }
    #expect(await !AudioModeAdapter.checkReadiness(hardware: broken))
    #expect(broken.access { $0.writes.isEmpty && !$0.mainAccess })
  }
  #expect(hardware.access { $0.writes.isEmpty && !$0.mainAccess })
}

@Test @MainActor func isolatedRuntimeBackendCannotWriteRealAudio() async throws {
  let fixture = try AudioFixture()
  let adapter = AudioModeAdapter.runtime(isolated: true)
  adapter.start { _ in }
  let result = await withCheckedContinuation { continuation in
    adapter.apply(fixture.command, files: fixture.files, owner: fixture.owner) {
      continuation.resume(returning: $0)
    }
  }
  guard case .systemMono(let command) = result else { throw RuntimeError.invalid }
  #expect(command == fixture.command)
  guard case .record(let journal) = fixture.files.load() else { throw RuntimeError.invalid }
  #expect(journal.audio.phase == .prepared && journal.audio.lastCompleted == nil)
  #expect(InertAudioHardware().setMode(1) != 0)
  adapter.stop()
  await fixture.close()
}

@Test @MainActor func quitCutoffIsCheckedOnTheAudioQueueAfterRunningPersistence() async throws {
  let fixture = try AudioFixture()
  let adapter = AudioModeAdapter(
    hardware: fixture.hardware, queue: fixture.queue, scheduler: fixture.scheduler,
    writeAllowed: { _ in false })
  adapter.start { _ in }
  let result = await withCheckedContinuation { continuation in
    adapter.apply(fixture.command, files: fixture.files, owner: fixture.owner) {
      continuation.resume(returning: $0)
    }
  }
  guard case .completed(let receipt) = result else { throw RuntimeError.invalid }
  #expect(receipt.exitCode != 0 && receipt.persisted && receipt.quiescent)
  #expect(fixture.hardware.access { $0.writes.isEmpty })
  guard case .record(let journal) = fixture.files.load() else { throw RuntimeError.invalid }
  #expect(!journal.lifecycle.closedCleanly || journal.audio.restoreRequired)
  #expect(journal.audio.restoreRequired && journal.audio.phase == .completed)
  adapter.stop()
  await fixture.close()
}

@Test @MainActor func watchdogOutlivesHungSetOrFsyncWithoutAFalseCleanJournal() async throws {
  for hangInSet in [true, false] {
    let fixture = try AudioFixture()
    guard case .record(var record) = fixture.files.load() else { throw RuntimeError.invalid }
    record.lifecycle.closedCleanly = false
    try fixture.files.persist(record: record)
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { for _ in 0..<4 { release.signal() } }
    let workerFiles: AtomicRuntimeFiles
    if hangInSet {
      workerFiles = fixture.files
      fixture.hardware.access { state in
        state.duringSet = {
          entered.continuation.yield()
          release.wait()
        }
      }
    } else {
      workerFiles = try AtomicRuntimeFiles(
        directory: fixture.root,
        before: { stage in
          if stage == .fileSync {
            entered.continuation.yield()
            release.wait()
          }
        })
    }
    await fixture.start()
    let operation = Task { @MainActor in await fixture.apply(files: workerFiles) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    let clock = QuitClock()
    let deadline = QuitDeadline(clock: { clock.now }, schedule: clock.schedule)
    deadline.arm(warn: { clock.record("warn") }, terminate: { clock.record("terminate") })
    clock.advance(1999)
    #expect(clock.recorded == ["warn"])
    clock.advance(2000)
    #expect(clock.recorded == ["warn", "terminate"])
    guard case .record(let interrupted) = fixture.files.load() else { throw RuntimeError.invalid }
    #expect(!interrupted.lifecycle.closedCleanly && interrupted.audio.restoreRequired)
    // Release every possible persist boundary after the simulated process deadline.
    for _ in 0..<4 { release.signal() }
    _ = await operation.value
    guard case .record(let late) = fixture.files.load() else { throw RuntimeError.invalid }
    #expect(!late.lifecycle.closedCleanly)
    await fixture.close()
  }
}

@Test @MainActor func queuedNormalCommandCannotBeginItsSetAfterQuitWasRequested() async throws {
  let fixture = try AudioFixture()
  let clock = QuitClock()
  let deadline = QuitDeadline(clock: { clock.now }, schedule: clock.schedule)
  let adapter = AudioModeAdapter(
    hardware: fixture.hardware, queue: fixture.queue, scheduler: fixture.scheduler,
    writeAllowed: { deadline.allowsWrite(recovery: $0.recovery) })
  var command = fixture.command
  command.target = .mono
  command.recovery = false
  command.context = ObservationContext(
    routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1)
  guard case .record(var record) = fixture.files.load() else { throw RuntimeError.invalid }
  record.lifecycle.closedCleanly = false
  record.audio.active = AudioCommand(id: command.id, target: command.target)
  try fixture.files.persist(record: record)
  adapter.start { _ in }
  deadline.arm(warn: {}, terminate: {})
  #expect(!deadline.allowsWrite(recovery: false))
  #expect(deadline.allowsWrite(recovery: true))
  let result = await withCheckedContinuation { continuation in
    adapter.apply(command, files: fixture.files, owner: fixture.owner) {
      continuation.resume(returning: $0)
    }
  }
  guard case .completed(let receipt) = result else { throw RuntimeError.invalid }
  #expect(receipt.exitCode != 0 && receipt.persisted && receipt.quiescent)
  #expect(fixture.hardware.access { $0.writes.isEmpty })
  adapter.stop()
  await fixture.close()
}

@Test func onlyTheExactProductIdentityMayReachRealAudio() {
  #expect(RuntimeConfiguration.mayUseRealAudio(identifier: "io.github.bernalli.monopods"))
  let others: [String?] = [
    nil, "", "io.github.bernalli.monopods.test.abc", "io.github.bernalli.monopods2",
    "IO.GITHUB.BERNALLI.MONOPODS",
  ]
  for identifier in others {
    #expect(!RuntimeConfiguration.mayUseRealAudio(identifier: identifier))
  }
}
