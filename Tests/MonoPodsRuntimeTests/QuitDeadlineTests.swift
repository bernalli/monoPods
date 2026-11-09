import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

final class QuitClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: UInt64 = 0
  private var jobs: [(UInt64, @Sendable () -> Void)] = []
  private var events: [String] = []
  var now: UInt64 { lock.withLock { time } }
  var recorded: [String] { lock.withLock { events } }
  func record(_ event: String) { lock.withLock { events.append(event) } }
  func schedule(_ deadline: UInt64, _ action: @escaping @Sendable () -> Void) {
    lock.withLock { jobs.append((deadline, action)) }
  }
  func advance(_ milliseconds: UInt64) {
    lock.withLock { time = milliseconds * 1_000_000 }
    while let action = lock.withLock({ () -> (@Sendable () -> Void)? in
      guard
        let index = jobs.indices.filter({ jobs[$0].0 <= time }).min(by: { jobs[$0].0 < jobs[$1].0 })
      else { return nil }
      return jobs.remove(at: index).1
    }) { action() }
  }
}

@Test func watchdogWarnsAndTerminatesAtAbsoluteDeadlinesWithoutMainActor() {
  let clock = QuitClock()
  let deadline = QuitDeadline(clock: { clock.now }, schedule: clock.schedule)
  deadline.arm(warn: { clock.record("warn") }, terminate: { clock.record("terminate") })
  for milliseconds: UInt64 in [199, 200, 599, 600, 1499] {
    clock.advance(milliseconds)
    #expect(clock.recorded.isEmpty)
    #expect(deadline.canStartAttempt)
  }
  deadline.arm(warn: { clock.record("duplicate") }, terminate: { clock.record("duplicate") })
  clock.advance(1500)
  #expect(!deadline.canStartAttempt)
  #expect(clock.recorded == ["warn"])
  clock.advance(1999)
  #expect(!deadline.expired)
  clock.advance(2000)
  #expect(deadline.expired)
  #expect(clock.recorded == ["warn", "terminate"])
  deadline.finish(confirmed: false)
  #expect(clock.recorded == ["warn", "terminate"])
}

@Test func successfulCloseSuppressesWarningAndFailedCloseWarnsOnceBeforeExit() {
  for confirmed in [true, false] {
    let clock = QuitClock()
    let deadline = QuitDeadline(clock: { clock.now }, schedule: clock.schedule)
    deadline.arm(warn: { clock.record("warn") }, terminate: { clock.record("terminate") })
    deadline.finish(confirmed: confirmed)
    clock.advance(2000)
    #expect(clock.recorded == (confirmed ? ["terminate"] : ["warn", "terminate"]))
  }
}

@Test func confirmedRestoreStillHasAWatchdogForHungFinalPersistence() {
  let clock = QuitClock()
  let deadline = QuitDeadline(clock: { clock.now }, schedule: clock.schedule)
  deadline.arm(warn: { clock.record("warn") }, terminate: { clock.record("terminate") })
  deadline.confirmRestore(true)
  clock.advance(1500)
  #expect(clock.recorded.isEmpty)
  clock.advance(2000)
  #expect(clock.recorded == ["terminate"])
}

@Test func detachedStereoWarningFallsBackOnlyWhenSpawnFails() {
  for succeeds in [false, true] {
    let clock = QuitClock()
    let warning = StereoRestoreWarning(
      spawn: {
        clock.record("spawn")
        return succeeds
      }, fallback: { clock.record("fallback") })
    warning.warn()
    warning.warn()
    #expect(clock.recorded == (succeeds ? ["spawn"] : ["spawn", "fallback"]))
  }
}

@Test func newTraceRotationNeverTouchesOldDiagnosticFiles() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  let old = Data("old shortcut trace\n".utf8)
  for name in ["diagnostic.jsonl", "diagnostic.jsonl.1"] { try files.write(old, name: name) }
  let log = DiagnosticLog(files: files, maximumBytes: 300)
  for seq: UInt64 in 1...4 {
    try log.append(
      TraceRecord(
        build: testBuild, run: 1, seq: seq, m: seq,
        payload: .end(EndPayload(utc: SystemClock.now().utc, exitCode: 0))))
  }
  for name in ["diagnostic.jsonl", "diagnostic.jsonl.1"] { #expect(try files.read(name) == old) }
  #expect(try files.read("trace-v2.jsonl") != nil)
  #expect(try files.read("trace-v2.jsonl.1") != nil)
}

@Test func earlyQuitCompletionQueuesWarningAndTerminationTogether() {
  let clock = QuitClock()
  let deadline = QuitDeadline(clock: { clock.now }, schedule: clock.schedule)
  deadline.arm(warn: { clock.record("warn") }, terminate: { clock.record("terminate") })
  deadline.finish(confirmed: false)
  #expect(clock.recorded.isEmpty)
  #expect(!deadline.canStartAttempt)
  clock.advance(0)
  #expect(clock.recorded == ["warn", "terminate"])
}

/// The update preparation reuses the Quit boundaries; its limit reports instead of exiting.
@Test func updatePreparationReusesTheBoundariesWithoutExiting() {
  for confirmAt: UInt64? in [nil, 1499, 1999] {
    let clock = QuitClock()
    let deadline = QuitDeadline(clock: { clock.now }, schedule: clock.schedule)
    deadline.arm(warn: {}, terminate: { clock.record("limit") })
    #expect(deadline.allowsWrite(recovery: true) && !deadline.allowsWrite(recovery: false))
    if let confirmAt {
      clock.advance(confirmAt)
      deadline.finish(confirmed: true)
      clock.advance(confirmAt)
      #expect(clock.recorded == ["limit"])
    }
    clock.advance(1500)
    #expect(!deadline.canStartAttempt)
    clock.advance(2000)
    #expect(clock.recorded == ["limit"])
  }
}

@Test func updateAlarmUsesAbsoluteTimesAndRejectsResultsBeforeADelayedTimer() {
  for milliseconds: UInt64 in [1499, 1500, 1999, 2000, 2001] {
    let clock = QuitClock()
    let alarm = UpdatePreparationDeadline(clock: { clock.now }, schedule: { _, _ in })
    alarm.arm(warn: { clock.record("warn") }, expire: { clock.record("expire") })
    clock.advance(milliseconds)
    #expect(alarm.canStartAttempt == (milliseconds < 1500))
    #expect(
      alarm.resolve(.stereoConfirmed) == (milliseconds < 2000 ? .stereoConfirmed : .unconfirmed))
    #expect(clock.recorded == (milliseconds < 1500 ? [] : ["warn"]))
  }
}

@Test func updateAlarmFiresWithoutTheMainActorAndSuppressesCancelledWarnings() {
  for cancel in [false, true] {
    let clock = QuitClock()
    let alarm = UpdatePreparationDeadline(clock: { clock.now }, schedule: clock.schedule)
    alarm.arm(warn: { clock.record("warn") }, expire: { clock.record("expire") })
    if cancel { alarm.cancel() }
    clock.advance(1499)
    #expect(clock.recorded.isEmpty)
    clock.advance(1500)
    #expect(clock.recorded == (cancel ? [] : ["warn"]))
    clock.advance(2000)
    #expect(clock.recorded == (cancel ? [] : ["warn", "expire"]))
    #expect(alarm.resolve(.nothingToRestore) == .unconfirmed)
  }
}

@MainActor @Test func updateWatchdogFiresWhileMainActorIsBlocked() {
  let fired = DispatchSemaphore(value: 0)
  let clock = QuitClock()
  let alarm = UpdatePreparationDeadline(
    clock: { SystemClock.now().continuousNanos }, schedule: UpdatePreparationDeadline.background)
  alarm.arm(warn: { clock.record("warn") }, expire: { fired.signal() })
  #expect(fired.wait(timeout: .now() + 3) == .success)
  #expect(clock.recorded == ["warn"])
  #expect(alarm.resolve(.stereoConfirmed) == .unconfirmed)
}

@Test func updateWorkerPermissionClosesAtTheAttemptDeadline() {
  let clock = QuitClock()
  let alarm = UpdatePreparationDeadline(clock: { clock.now }, schedule: clock.schedule)
  let permission = UpdateWritePermission()
  alarm.arm(warn: {}, expire: {})
  permission.hold(alarm)
  clock.advance(1499)
  #expect(permission.allowsWrite(recovery: true))
  #expect(!permission.allowsWrite(recovery: false))
  clock.advance(1500)
  #expect(!permission.allowsWrite(recovery: true))
  clock.advance(2001)
  #expect(!permission.allowsWrite(recovery: true))
  permission.hold(nil)
  #expect(permission.allowsWrite(recovery: false))
}

@Test func reorderedUpdateAlarmsWarnOnceBeforeExpiring() {
  let clock = QuitClock()
  let alarm = UpdatePreparationDeadline(
    clock: { clock.now },
    schedule: { due, action in
      clock.schedule(due == 1_500_000_000 ? 3_000_000_000 : due, action)
    })
  alarm.arm(warn: { clock.record("warn") }, expire: { clock.record("expire") })
  clock.advance(2001)
  #expect(clock.recorded == ["warn", "expire"])
  clock.advance(3000)
  #expect(clock.recorded == ["warn", "expire"])
}

@Test func endingTheWorkerHoldCancelsItsPendingUpdateAlarm() {
  let clock = QuitClock()
  let alarm = UpdatePreparationDeadline(clock: { clock.now }, schedule: clock.schedule)
  let permission = UpdateWritePermission()
  alarm.arm(warn: { clock.record("warn") }, expire: { clock.record("expire") })
  permission.hold(alarm)
  permission.hold(nil)
  clock.advance(2000)
  #expect(clock.recorded.isEmpty)
}
