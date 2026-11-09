import Foundation
import MonoPodsCore

/// A delayed main actor call that can be cancelled. The delay is in nanoseconds.
public typealias OneShotSchedule =
  @MainActor (_ delayNanos: UInt64, _ fire: @escaping @MainActor @Sendable () -> Void) ->
  (@MainActor () -> Void)

/// Steps the Stereo ripple through its frames with one-shot timers. Each step schedules only the
/// next one, and the resting frame schedules nothing, so the animation stops by itself. `stop()`
/// cancels the pending step, and a step that fires after `stop()` or a new `start()` is dropped.
@MainActor public final class WaveAnimator {
  public private(set) var frame = StereoRipple.restingFrame
  public private(set) var running = false
  /// Receives each frame as it becomes current.
  public var onFrame: (@MainActor (Int) -> Void)?
  private let schedule: OneShotSchedule
  private var cancel: (@MainActor () -> Void)?
  private var generation: UInt64 = 0

  public init(schedule: @escaping OneShotSchedule = WaveAnimator.mainQueue) {
    self.schedule = schedule
  }

  public func start() {
    stop()
    running = true
    show(0)
    scheduleNext()
  }

  public func stop() {
    generation &+= 1
    cancel?()
    cancel = nil
    running = false
  }

  private func scheduleNext() {
    guard frame < StereoRipple.restingFrame else {
      running = false
      cancel = nil
      return
    }
    let current = generation
    cancel = schedule(StereoRipple.frameIntervalNanos) { [weak self] in
      guard let self, self.running, self.generation == current else { return }
      self.show(self.frame + 1)
      self.scheduleNext()
    }
  }

  private func show(_ next: Int) {
    frame = next
    onFrame?(next)
  }

  /// One-shot work on the main queue. The main queue is served in every run loop mode, so the
  /// ripple also moves while the menu is open.
  public static func mainQueue(
    _ delayNanos: UInt64, _ fire: @escaping @MainActor @Sendable () -> Void
  ) -> (@MainActor () -> Void) {
    let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
    let delay = Int(clamping: delayNanos)
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(delay), execute: item)
    return { item.cancel() }
  }
}
