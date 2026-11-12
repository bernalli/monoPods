import Darwin
import Foundation
import Testing

@testable import MonoPodsRuntime

private final class ChildClock: @unchecked Sendable {
  struct Signal: Equatable {
    let pid: pid_t
    let value: Int32
  }
  private let lock = NSLock()
  private var time: UInt64 = 0
  private var jobs: [(UInt64, @Sendable () -> Void)] = []
  private var signals: [Signal] = []
  var now: UInt64 { lock.withLock { time } }
  var recorded: [Signal] { lock.withLock { signals } }
  var pending: Int { lock.withLock { jobs.count } }
  func send(_ pid: pid_t, _ value: Int32) {
    lock.withLock { signals.append(Signal(pid: pid, value: value)) }
  }
  func schedule(_ due: UInt64, _ action: @escaping @Sendable () -> Void) {
    lock.withLock { jobs.append((due, action)) }
  }
  func fireNext() {
    let action = lock.withLock { jobs.isEmpty ? nil : jobs.removeFirst().1 }
    action?()
  }
  func advance(_ milliseconds: UInt64) {
    lock.withLock { time = milliseconds * 1_000_000 }
    while let action = lock.withLock({ () -> (@Sendable () -> Void)? in
      guard let index = jobs.indices.min(by: { jobs[$0].0 < jobs[$1].0 }),
        jobs[index].0 <= time
      else { return nil }
      return jobs.remove(at: index).1
    }) { action() }
  }
  func termination(seconds: UInt64? = 1) -> ChildTermination {
    ChildTermination(
      timeoutSeconds: seconds, clock: { self.now }, schedule: schedule, signal: send)
  }
}

@Test func childDeadlineSendsTermAtTheAbsoluteDeadlineAndKillAfterGrace() {
  let clock = ChildClock()
  clock.advance(100)
  let child = clock.termination()
  child.arm(pid: 42)
  clock.advance(1099)
  #expect(clock.recorded.isEmpty)
  clock.advance(1100)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM)])
  clock.advance(3099)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM)])
  clock.advance(3100)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM), .init(pid: 42, value: SIGKILL)])
  clock.advance(10000)
  #expect(clock.recorded.count == 2)
}

@Test func earlyChildTimersRecheckTheClockBeforeEitherSignal() {
  let clock = ChildClock()
  let child = clock.termination()
  child.arm(pid: 42)
  clock.advance(999)
  clock.fireNext()
  #expect(clock.recorded.isEmpty)
  #expect(clock.pending == 1)
  clock.advance(1000)
  clock.advance(2999)
  clock.fireNext()
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM)])
  #expect(clock.pending == 1)
  clock.advance(3000)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM), .init(pid: 42, value: SIGKILL)])
}

@Test func childExitBeforeDeadlineSuppressesAllSignals() {
  let clock = ChildClock()
  let child = clock.termination()
  child.arm(pid: 42)
  clock.advance(999)
  child.didExit()
  child.stop()
  clock.advance(10000)
  #expect(clock.recorded.isEmpty)
}

@Test func childExitBeforePidPublicationSuppressesAllSignals() {
  let clock = ChildClock()
  let child = clock.termination()
  child.didExit()
  child.arm(pid: 42)
  child.stop()
  clock.advance(10000)
  #expect(clock.recorded.isEmpty)
}

@Test func childExitDuringGraceSuppressesKill() {
  let clock = ChildClock()
  let child = clock.termination()
  child.arm(pid: 42)
  clock.advance(1000)
  clock.advance(2999)
  child.didExit()
  child.stop()
  clock.advance(10000)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM)])
}

@Test func repeatedChildStopSendsTermImmediatelyAndSchedulesOnlyOneEscalation() {
  let clock = ChildClock()
  let child = clock.termination(seconds: nil)
  child.arm(pid: 42)
  clock.advance(250)
  child.stop()
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM)])
  #expect(clock.pending == 1)
  clock.advance(500)
  child.stop()
  #expect(clock.pending == 1)
  clock.advance(2249)
  #expect(clock.recorded.count == 1)
  clock.advance(2250)
  child.stop()
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM), .init(pid: 42, value: SIGKILL)])
  #expect(clock.pending == 0)
}

@Test func childDeadlineDoesNotRestartTheGraceOfAnExplicitStop() {
  let clock = ChildClock()
  let child = clock.termination()
  child.arm(pid: 42)
  clock.advance(500)
  child.stop()
  clock.advance(1000)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM)])
  #expect(clock.pending == 1)
  clock.advance(2500)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM), .init(pid: 42, value: SIGKILL)])
}

@Test func delayedChildDeadlineAllowsTwoSecondsFromTheActualTerm() {
  let clock = ChildClock()
  let child = clock.termination()
  child.arm(pid: 42)
  clock.advance(5000)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM)])
  clock.advance(6999)
  #expect(clock.recorded.count == 1)
  clock.advance(7000)
  #expect(clock.recorded == [.init(pid: 42, value: SIGTERM), .init(pid: 42, value: SIGKILL)])
}

@MainActor @Test func logChildDiesWhileMainActorIsBlocked() async {
  let child = Process()
  let process = LogProcess(makeProcess: { child })
  var checked = false
  var callbacks = 0
  let code: Int32 = await withCheckedContinuation { continuation in
    do {
      try process.start(
        executable: "/usr/bin/tail", arguments: ["-f", "/dev/null"],
        timeoutSeconds: 1,
        chunk: { _ in },
        finished: { status in
          callbacks += 1
          continuation.resume(returning: status)
        })
    } catch {
      continuation.resume(returning: Int32.min)
      return
    }
    // Never yield the main actor after start. Read the PID directly from the spawned Process,
    // so observing termination does not depend on the child running any setup code first.
    // Allow up to 50 s for heavily loaded CI runners to schedule the background worker.
    let pid = child.processIdentifier
    #expect(pid > 0)
    let end = ContinuousClock.now + .seconds(50)
    Thread.sleep(forTimeInterval: 4)
    while ContinuousClock.now < end {
      if pid > 0, kill(pid, 0) == -1 && errno == ESRCH {
        checked = true
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(checked)
    #expect(callbacks == 0)
    if !checked, pid > 0, child.isRunning { kill(pid, SIGKILL) }
    process.stop()
  }
  #expect(callbacks == 1)
  #expect(code == -1)
}

@MainActor @Test func logProcessRejectsDoubleStartAndCanRestartAfterDrainedCompletion() async {
  let process = LogProcess()
  var busy = false
  var callbacks = 0
  let first: Int32 = await withCheckedContinuation { continuation in
    do {
      try process.start(
        executable: "/usr/bin/tail", arguments: ["-f", "/dev/null"],
        chunk: { _ in },
        finished: { status in
          callbacks += 1
          continuation.resume(returning: status)
        })
    } catch {
      continuation.resume(returning: Int32.min)
      return
    }
    do {
      try process.start(
        executable: "/usr/bin/false", arguments: [], chunk: { _ in },
        finished: { _ in Issue.record("A rejected start must not finish") })
      Issue.record("A running child must reject another start")
    } catch RuntimeError.busy {
      busy = true
    } catch { Issue.record(error) }
    process.stop()
    process.stop()
  }
  #expect(busy)
  #expect(first == SIGTERM)
  #expect(callbacks == 1)
  var output = Data()
  let second: Int32 = await withCheckedContinuation { continuation in
    do {
      try process.start(
        executable: "/usr/bin/printf", arguments: ["drained\\n"], timeoutSeconds: 3600,
        chunk: { output.append($0) },
        finished: { status in
          callbacks += 1
          #expect(String(data: output, encoding: .utf8) == "drained\n")
          continuation.resume(returning: status)
        })
    } catch { continuation.resume(returning: Int32.min) }
  }
  #expect(second == 0)
  #expect(callbacks == 2)
  process.stop()
}
