import CryptoKit
import Foundation
import MonoPodsCore

@MainActor private final class HistoryRead {
  var framer = NDJSONFramer()
  var capture = HistoryCapture()
  var bytes = 0
  var digest = SHA256()
  let process = LogProcess()
  var evidenceHash: String { digest.finalize().map { String(format: "%02x", $0) }.joined() }
}

@MainActor public final class LogTransport {
  private let driver: ObservationDriver
  private let boot: String
  private let submit: @MainActor @Sendable (EngineInput) -> Void
  private let stream = LogProcess()
  private var framer = NDJSONFramer()
  private var reads: [UInt64: HistoryRead] = [:]
  private var restart: Task<Void, Never>?
  private var running = false
  private var stopped = false
  private var pendingStart = false
  public init(
    driver: ObservationDriver, boot: String,
    submit: @escaping @MainActor @Sendable (EngineInput) -> Void
  ) {
    self.driver = driver
    self.boot = boot
    self.submit = submit
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
    guard !stopped, reads[id] == nil, ContractValidation.uuid(boot) else { return }
    let read = HistoryRead()
    reads[id] = read
    do {
      try read.process.start(
        arguments: LogArguments.history(boot: boot), timeoutSeconds: 30,
        chunk: { data in
          read.bytes += data.count
          read.digest.update(data: data)
          guard read.bytes <= 8 * 1024 * 1024 else {
            read.capture.invalidate()
            read.process.stop()
            return
          }
          for item in read.framer.feed(data) {
            switch item {
            case .line(let line): read.capture.consume(line)
            case .gap: read.capture.invalidate()
            }
          }
        },
        finished: { [weak self] code in
          guard let self else { return }
          self.reads.removeValue(forKey: id)
          guard !self.stopped else { return }
          self.driver.history(
            read.capture, id: id, context: context, exitCode: code, truncated: read.framer.finish(),
            evidenceHash: read.evidenceHash)
        })
    } catch {
      reads.removeValue(forKey: id)
      driver.history(
        read.capture, id: id, context: context, exitCode: -1, truncated: true,
        evidenceHash: read.evidenceHash)
    }
  }
  public func stop() {
    stopped = true
    restart?.cancel()
    restart = nil
    pendingStart = false
    stream.stop()
    for read in reads.values { read.process.stop() }
    reads.removeAll()
  }
}
