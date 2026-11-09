import Foundation
import MonoPodsCore

@MainActor public final class EngineFIFO {
  public typealias Reply = @MainActor (EngineInput) -> Void
  public typealias Executor = @MainActor (EngineAction, @escaping Reply) -> Void
  private var engine: Engine
  private var pending: [(EngineInput, Instant?)] = []
  private var processing = false
  private var scheduled = false
  private var tickQueued = false
  private let clock: () -> Instant
  private let execute: Executor
  /// Called only for inputs the diary keeps; see `recordsInDiary`.
  public var observe: ((EngineInput, Instant, [EngineAction]) -> Void)?
  /// Called at the end of every flush, when `nextDeadline` may have moved.
  public var flushed: (() -> Void)?
  public init(engine: Engine, clock: @escaping () -> Instant, execute: @escaping Executor) {
    self.engine = engine
    self.clock = clock
    self.execute = execute
  }
  public var snapshot: EngineSnapshot { engine.snapshot }
  public var nextDeadline: UInt64? { engine.nextDeadline }
  public func enqueue(_ input: EngineInput, at instant: Instant? = nil) {
    pending.append((input, instant))
    guard !scheduled, !processing else { return }
    scheduled = true
    Task { @MainActor [weak self] in
      self?.scheduled = false
      self?.flush()
    }
  }
  /// The periodic clock queues a tick only when a core deadline is due, one at a time.
  @discardableResult public func tickIfDue() -> Bool {
    guard !tickQueued, !engine.snapshot.terminated, let due = engine.nextDeadline,
      clock().continuousNanos >= due
    else { return false }
    tickQueued = true
    enqueue(.tick)
    return true
  }
  public func flush() {
    guard !processing else { return }
    processing = true
    defer { processing = false }
    while !engine.snapshot.terminated {
      if !pending.isEmpty {
        let (input, instant) = pending.removeFirst()
        if case .tick = input { tickQueued = false }
        guard input.valid else { continue }
        apply(input, at: instant)
      } else {
        apply(.drain)
        if pending.isEmpty { break }
      }
    }
    if engine.snapshot.terminated {
      pending.removeAll()
      tickQueued = false
    }
    flushed?()
  }
  private func apply(_ input: EngineInput, at instant: Instant? = nil) {
    let now = instant ?? clock()
    let before = engine
    let actions = engine.handle(input: input, at: now)
    if Self.recordsInDiary(input, actions: actions, changed: engine != before) {
      observe?(input, now, actions)
    }
    for action in actions { execute(action) { [weak self] in self?.enqueue($0) } }
  }
  /// An input with no actions and no state change is left out of the diary: replaying the
  /// diary still reproduces every action. Ticks stay, because the report uses them to expire
  /// deadlines, and so do inputs that the report inspects on its own or that exist only as
  /// diagnostics.
  public static func recordsInDiary(
    _ input: EngineInput, actions: [EngineAction], changed: Bool
  ) -> Bool {
    if changed || !actions.isEmpty { return true }
    switch input {
    case .tick, .route, .connection, .streamStarted, .heartbeat, .observation, .history, .gap,
      .nowPlaying, .pause, .sentinelPlay, .sentinelToggle, .writerCompleted, .playCompleted,
      .persistenceAcknowledged, .audioObserved, .audioWriteSkipped:
      return true
    case .ownerWaiting, .ownerAcquired, .journalLoaded, .streamFinished, .sentinelAvailable,
      .environment, .automation, .ownerConfirmed, .reopen,
      .noticePresented, .quit, .drain, .prepareUpdate, .endUpdateHold:
      return false
    }
  }
}
