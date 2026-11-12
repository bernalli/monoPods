import Darwin
import Foundation

/// One child's deadline and stop escalation. All mutable state and signal sends share the lock.
final class ChildTermination: @unchecked Sendable {
  typealias Schedule = @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void
  private static let queue = DispatchQueue(
    label: "io.github.bernalli.monopods.child-termination", qos: .userInitiated)
  private let lock = NSLock()
  private let clock: @Sendable () -> UInt64
  private let schedule: Schedule
  private let signal: @Sendable (pid_t, Int32) -> Void
  private let deadline: UInt64?
  private var pid: pid_t?
  private var exited = false
  private var killDue: UInt64?
  private var killed = false

  /// The scheduler must run independently of the main actor. The signal sender runs under the
  /// lock to serialize it with didExit(), and must not reenter this object.
  init(
    timeoutSeconds: UInt64?,
    clock: @escaping @Sendable () -> UInt64 = { SystemClock.now().continuousNanos },
    schedule: @escaping Schedule = ChildTermination.background,
    signal: @escaping @Sendable (pid_t, Int32) -> Void
  ) {
    self.clock = clock
    self.schedule = schedule
    self.signal = signal
    deadline = timeoutSeconds.map {
      let (nanos, overflow) = $0.multipliedReportingOverflow(by: 1_000_000_000)
      return overflow ? UInt64.max : Self.adding(nanos, to: clock())
    }
  }

  /// Construct before spawn and publish the PID only after a successful run(). An exit notified
  /// before PID publication stays final, so even a zero-second timeout cannot signal it later.
  func arm(pid: pid_t) {
    let due = lock.withLock { () -> UInt64? in
      guard !exited, self.pid == nil, pid > 0 else { return nil }
      self.pid = pid
      return deadline
    }
    if let due { schedule(due) { [weak self] in self?.fireDeadline() } }
  }

  func stop() {
    let due = lock.withLock { () -> UInt64? in
      guard !exited, let pid, killDue == nil else { return nil }
      let due = Self.adding(2_000_000_000, to: clock())
      killDue = due
      signal(pid, SIGTERM)
      return due
    }
    if let due { schedule(due) { [weak self] in self?.fireKill() } }
  }

  func didExit() { lock.withLock { exited = true } }

  private func fireDeadline() {
    let due = lock.withLock { () -> UInt64? in
      guard !exited, pid != nil, killDue == nil else { return nil }
      return deadline
    }
    guard let due else { return }
    if clock() < due {
      schedule(due) { [weak self] in self?.fireDeadline() }
    } else {
      stop()
    }
  }

  private func fireKill() {
    let retry = lock.withLock { () -> UInt64? in
      guard !exited, !killed, let pid, let killDue else { return nil }
      guard clock() >= killDue else { return killDue }
      killed = true
      signal(pid, SIGKILL)
      return nil
    }
    if let retry { schedule(retry) { [weak self] in self?.fireKill() } }
  }

  private static func adding(_ nanos: UInt64, to start: UInt64) -> UInt64 {
    let (sum, overflow) = start.addingReportingOverflow(nanos)
    return overflow ? UInt64.max : sum
  }

  private static func background(_ due: UInt64, _ action: @escaping @Sendable () -> Void) {
    let now = SystemClock.now().continuousNanos
    queue.asyncAfter(
      deadline: .now() + .nanoseconds(Int(clamping: due > now ? due - now : 0)), execute: action)
  }
}
