import Darwin
import Foundation
import MonoPodsCore

/// Absolute process deadline, independent of the main actor and the audio worker.
public final class QuitDeadline: @unchecked Sendable {
  public typealias Schedule = @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void
  private let lock = NSLock()
  private let clock: @Sendable () -> UInt64
  private let schedule: Schedule
  private var start: UInt64?
  private var confirmed = false
  private var warned = false
  private var finished = false
  private var finishing = false
  private var warn: (@Sendable () -> Void)?
  private var terminate: (@Sendable () -> Void)?

  public convenience init() {
    let queue = DispatchQueue(label: "io.github.bernalli.monopods.quit", qos: .userInitiated)
    self.init(
      clock: { SystemClock.now().continuousNanos },
      schedule: { due, action in
        let now = SystemClock.now().continuousNanos
        queue.asyncAfter(
          deadline: .now() + .nanoseconds(Int(min(due > now ? due - now : 0, UInt64(Int.max)))),
          execute: action)
      })
  }
  /// The injected scheduler must deliver callbacks serially, independently of the main actor.
  public init(clock: @escaping @Sendable () -> UInt64, schedule: @escaping Schedule) {
    self.clock = clock
    self.schedule = schedule
  }
  public var canStartAttempt: Bool { allowsWrite(recovery: true) }
  public func allowsWrite(recovery: Bool) -> Bool {
    lock.withLock {
      guard let start else { return !finished && !finishing }
      let now = clock()
      return recovery && !finishing && !finished && now >= start && now - start < 1_500_000_000
    }
  }
  public var expired: Bool {
    lock.withLock {
      let now = clock()
      return start.map { now >= $0 && now - $0 >= 2_000_000_000 } ?? false
    }
  }
  public func arm(warn: @escaping @Sendable () -> Void, terminate: @escaping @Sendable () -> Void) {
    let now = clock()
    let armed = lock.withLock {
      guard start == nil else { return false }
      start = now
      self.warn = warn
      self.terminate = terminate
      return true
    }
    guard armed else { return }
    schedule(now &+ 1_500_000_000) { [self] in warnIfNeeded() }
    schedule(now &+ 2_000_000_000) { [self] in finishOnQueue(confirmed: nil) }
  }
  public func confirmRestore(_ value: Bool) { lock.withLock { confirmed = value } }
  private func warnIfNeeded() {
    let action = lock.withLock { () -> (@Sendable () -> Void)? in
      guard !finished, !confirmed, !warned else { return nil }
      warned = true
      return warn
    }
    action?()
  }
  /// `nil` is the watchdog: use the last durable confirmation published by the host.
  public func finish(confirmed value: Bool?) {
    let queued = lock.withLock {
      guard !finished, !finishing else { return false }
      finishing = true
      if let value { confirmed = value }
      return true
    }
    guard queued else { return }
    // The scheduler is serial: a warning already spawning there must finish before termination.
    // In particular, the main actor never waits for that queue or performs the detached spawn.
    schedule(clock()) { [self] in finishOnQueue(confirmed: value) }
  }
  private func finishOnQueue(confirmed value: Bool?) {
    let actions = lock.withLock { () -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?) in
      guard !finished else { return (nil, nil) }
      if let value { confirmed = value }
      let warning = !confirmed && !warned ? warn : nil
      warned = warned || !confirmed
      finished = true
      return (warning, terminate)
    }
    actions.0?()
    actions.1?()
  }
}

/// One detached warning, with an in-process panel only as a fallback for spawn failure.
public final class StereoRestoreWarning: @unchecked Sendable {
  private let lock = NSLock()
  private var shown = false
  private let spawn: @Sendable () -> Bool
  private let fallback: @Sendable () -> Void
  public init(spawn: @escaping @Sendable () -> Bool, fallback: @escaping @Sendable () -> Void) {
    self.spawn = spawn
    self.fallback = fallback
  }
  public func warn() {
    guard
      lock.withLock({
        if shown { return false }
        shown = true
        return true
      })
    else { return }
    if !spawn() { fallback() }
  }
}

/// Preparation uses one absolute monotonic window, even if main-actor delivery is delayed.
public final class UpdatePreparationDeadline: @unchecked Sendable {
  public typealias Schedule = QuitDeadline.Schedule
  private static let queue = DispatchQueue(
    label: "io.github.bernalli.monopods.update-deadline", qos: .userInitiated)
  private let lock = NSLock()
  private let clock: @Sendable () -> UInt64
  private let schedule: Schedule
  private var window: UpdatePreparationWindow?
  private var finished = false
  private var warned = false
  private var warn: (@Sendable () -> Void)?
  private var expire: (@Sendable () -> Void)?

  public init(clock: @escaping @Sendable () -> UInt64, schedule: @escaping Schedule) {
    self.clock = clock
    self.schedule = schedule
  }
  public static func background(_ due: UInt64, _ action: @escaping @Sendable () -> Void) {
    let now = SystemClock.now().continuousNanos
    queue.asyncAfter(
      deadline: .now() + .nanoseconds(Int(clamping: due > now ? due - now : 0)), execute: action)
  }
  public var startedAt: UInt64? { lock.withLock { window?.start } }
  public var canStartAttempt: Bool {
    lock.withLock {
      guard let window, !finished else { return false }
      let now = clock()
      return now >= window.start && now < window.retryEnd
    }
  }
  public func arm(warn: @escaping @Sendable () -> Void, expire: @escaping @Sendable () -> Void) {
    let times = lock.withLock { () -> UpdatePreparationWindow? in
      guard window == nil, !finished else { return nil }
      let times = UpdatePreparationWindow(start: clock())
      window = times
      self.warn = warn
      self.expire = expire
      return times
    }
    guard let times else { return }
    schedule(times.warning) { [weak self] in self?.fireWarning() }
    schedule(times.end) { [weak self] in self?.fireDeadline() }
  }
  private func fireWarning() {
    var retry: UInt64?
    let action = lock.withLock { () -> (@Sendable () -> Void)? in
      guard let window, !finished, !warned else { return nil }
      guard clock() >= window.warning else {
        retry = window.warning
        return nil
      }
      warned = true
      return warn
    }
    if let retry { schedule(retry) { [weak self] in self?.fireWarning() } }
    action?()
  }
  private func fireDeadline() {
    var retry: UInt64?
    let actions = lock.withLock { () -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?) in
      guard let window, !finished else { return (nil, nil) }
      guard clock() >= window.end else {
        retry = window.end
        return (nil, nil)
      }
      finished = true
      let warning = warned ? nil : warn
      warned = true
      return (warning, expire)
    }
    if let retry { schedule(retry) { [weak self] in self?.fireDeadline() } }
    actions.0?()
    actions.1?()
  }
  /// A result delivered at or beyond 2000 ms is unconfirmed, regardless of timer ordering.
  public func resolve(_ result: UpdatePreparationResult) -> UpdatePreparationResult {
    let resolved = lock.withLock { () -> (UpdatePreparationResult, (@Sendable () -> Void)?) in
      guard let window, !finished else { return (.unconfirmed, nil) }
      let now = clock()
      let valid = now >= window.start && now < window.end
      let warning = !warned && (now >= window.warning || result == .unconfirmed) ? warn : nil
      warned = warned || warning != nil
      finished = true
      return (valid ? result : .unconfirmed, warning)
    }
    resolved.1?()
    return resolved.0
  }
  public func cancel() { lock.withLock { finished = true } }
}

/// The worker checks the same window immediately before each hardware write.
final class UpdateWritePermission: @unchecked Sendable {
  private let lock = NSLock()
  private var deadline: UpdatePreparationDeadline?
  func hold(_ deadline: UpdatePreparationDeadline?) {
    let previous = lock.withLock {
      let previous = self.deadline
      self.deadline = deadline
      return previous
    }
    if previous !== deadline { previous?.cancel() }
  }
  func allowsWrite(recovery: Bool) -> Bool {
    lock.withLock { deadline.map { recovery && $0.canStartAttempt } ?? true }
  }
}
