import Foundation
import MonoPodsCore

@MainActor public final class LogTransport {
  private let driver: ObservationDriver
  private let submit: @MainActor @Sendable (EngineInput) -> Void
  private let stream = LogProcess()
  private var framer = NDJSONFramer()
  private let historyReader: HistoryReader
  var activeHistoryCount: Int { historyReader.activeCount }
  var pendingHistoryCount: Int { historyReader.pendingCount }
  private var restart: Task<Void, Never>?
  private var running = false
  private var stopped = false
  private var pendingStart = false
  public convenience init(
    driver: ObservationDriver, boot: String,
    submit: @escaping @MainActor @Sendable (EngineInput) -> Void
  ) {
    self.init(
      driver: driver, boot: boot, clock: { SystemClock.now().continuousNanos },
      schedule: DeadlineAlarm.mainQueue, makeHistoryProcess: { LogProcess() }, submit: submit)
  }
  init(
    driver: ObservationDriver, boot: String,
    clock: @escaping () -> UInt64, schedule: @escaping OneShotSchedule,
    makeHistoryProcess: @escaping @MainActor () -> any HistoryProcess,
    submit: @escaping @MainActor @Sendable (EngineInput) -> Void
  ) {
    self.driver = driver
    self.submit = submit
    self.historyReader = HistoryReader(
      driver: driver, boot: boot, clock: clock, schedule: schedule, makeProcess: makeHistoryProcess)
  }
  public func start() {
    guard !stopped, !running else { return }
    do {
      let epoch = try driver.beginStream(nonce: UUID().uuidString)
      framer = NDJSONFramer()
      running = true
      try stream.start(
        arguments: LogArguments.stream,
        chunk: { [weak self] data in
          guard let self else { return }
          for item in self.framer.feed(data) {
            switch item {
            case .line(let line): self.driver.consume(line, epoch: epoch)
            case .gap: self.driver.transportGap(epoch: epoch)
            }
          }
        },
        finished: { [weak self] _ in
          guard let self else { return }
          self.running = false
          self.submit(.streamFinished(epoch: epoch))
          if self.pendingStart {
            self.pendingStart = false
            self.start()
          }
        })
    } catch {
      running = false
      submit(.streamFinished(epoch: driver.streamEpoch))
    }
  }
  public func restart(epoch: UInt64, afterNanos: UInt64) {
    guard !stopped, epoch == driver.streamEpoch, restart == nil else { return }
    stream.stop()
    restart = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: afterNanos)
      guard !Task.isCancelled, let self, !self.stopped else { return }
      self.restart = nil
      if self.running { self.pendingStart = true } else { self.start() }
    }
  }
  public func history(id: UInt64, context: ObservationContext) {
    historyReader.request(id: id, context: context)
  }
  public func stop() {
    stopped = true
    restart?.cancel()
    restart = nil
    pendingStart = false
    stream.stop()
    historyReader.stop()
  }
}
