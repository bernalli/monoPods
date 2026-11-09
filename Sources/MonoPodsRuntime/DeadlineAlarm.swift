import Dispatch
import MonoPodsCore

/// One exact one-shot timer at the engine's next deadline, beside the 100 ms pulse.
///
/// Measured over 10 "bud removed" episodes: Pause to Play took 165 ms (median, 101-339 ms) for a
/// 100 ms engine delay. The rest was the wait for the next pulse, and in 3 episodes the pulse did
/// not fire for 150-240 ms. The alarm wakes the host at the deadline itself; the pulse still runs
/// for the heartbeat and everything else.
@MainActor public final class DeadlineAlarm {
  private let clock: () -> Instant
  private let schedule: OneShotSchedule
  private let fire: @MainActor () -> Void
  private var armed: UInt64?
  private var cancel: (@MainActor () -> Void)?
  /// The deadline that last fired. It is not armed again: a deadline that stays due after its
  /// tick is left to the pulse, so the alarm can never spin.
  private var fired: UInt64?

  public init(
    clock: @escaping () -> Instant, schedule: @escaping OneShotSchedule = DeadlineAlarm.mainQueue,
    fire: @escaping @MainActor () -> Void
  ) {
    self.clock = clock
    self.schedule = schedule
    self.fire = fire
  }

  /// Arms the alarm for `deadline`, in continuous nanoseconds. A different deadline replaces the
  /// armed one; nil disarms.
  public func arm(_ deadline: UInt64?) {
    guard deadline != armed else { return }
    cancel?()
    cancel = nil
    armed = nil
    guard let deadline, deadline != fired else { return }
    armed = deadline
    wait(for: deadline)
  }

  private func wait(for deadline: UInt64) {
    let now = clock().continuousNanos
    cancel = schedule(deadline > now ? deadline - now : 0) { [weak self] in
      guard let self, self.armed == deadline else { return }
      // The dispatch clock and the continuous clock can differ by a few ticks: wait the rest.
      if self.clock().continuousNanos < deadline {
        self.wait(for: deadline)
        return
      }
      self.armed = nil
      self.cancel = nil
      self.fired = deadline
      self.fire()
    }
  }

  /// A strict dispatch timer on the main queue with a 1 ms leeway. The main queue is served in
  /// every run loop mode, so an open menu does not delay it.
  public static func mainQueue(
    _ delayNanos: UInt64, _ fire: @escaping @MainActor @Sendable () -> Void
  ) -> (@MainActor () -> Void) {
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    timer.schedule(
      deadline: .now() + .nanoseconds(Int(clamping: delayNanos)), leeway: .milliseconds(1))
    timer.setEventHandler {
      timer.cancel()
      MainActor.assumeIsolated { fire() }
    }
    timer.resume()
    return { timer.cancel() }
  }
}
