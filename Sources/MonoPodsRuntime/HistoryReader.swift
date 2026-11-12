import CryptoKit
import Foundation
import MonoPodsCore

@MainActor protocol HistoryProcess: AnyObject {
  func start(
    executable: String, arguments: [String], timeoutSeconds: UInt64?,
    chunk: @escaping @MainActor @Sendable (Data) -> Void,
    finished: @escaping @MainActor @Sendable (Int32) -> Void
  ) throws
  func stop()
}

extension LogProcess: HistoryProcess {}

private struct HistoryRequest: Equatable {
  let id: UInt64
  let context: ObservationContext
}

@MainActor private final class HistoryRead {
  let request: HistoryRequest
  let process: any HistoryProcess
  var framer = NDJSONFramer()
  var capture = HistoryCapture()
  var bytes = 0
  var digest = SHA256()
  var stopping = false
  var evidenceHash: String { digest.finalize().map { String(format: "%02x", $0) }.joined() }

  init(request: HistoryRequest, process: any HistoryProcess) {
    self.request = request
    self.process = process
  }
  func stop() {
    guard !stopping else { return }
    stopping = true
    process.stop()
  }
}

/// Admission is global across route and stream epochs. A successor never overlaps a child that
/// is still draining or terminating; only its completion callback releases the active slot.
@MainActor final class HistoryReader {
  private let driver: ObservationDriver
  private let boot: String
  private let clock: () -> UInt64
  private let schedule: OneShotSchedule
  private let makeProcess: @MainActor () -> any HistoryProcess
  private let minimumInterval: UInt64 = 1_000_000_000
  private var active: HistoryRead?
  private var pending: HistoryRequest?
  private var lastStart: UInt64?
  private var wakeID: UUID?
  private var cancelWake: (@MainActor () -> Void)?
  private var stopped = false
  var activeCount: Int { active == nil ? 0 : 1 }
  var pendingCount: Int { pending == nil ? 0 : 1 }

  init(
    driver: ObservationDriver, boot: String, clock: @escaping () -> UInt64,
    schedule: @escaping OneShotSchedule,
    makeProcess: @escaping @MainActor () -> any HistoryProcess
  ) {
    self.driver = driver
    self.boot = boot
    self.clock = clock
    self.schedule = schedule
    self.makeProcess = makeProcess
  }

  func request(id: UInt64, context: ObservationContext) {
    guard !stopped, ContractValidation.uuid(boot) else { return }
    let request = HistoryRequest(id: id, context: context)
    guard active?.request != request, pending != request else { return }
    pending = request
    pump()
  }

  private func pump() {
    guard !stopped, active == nil, let request = pending else { return }
    let now = clock()
    if let lastStart {
      let elapsed = now >= lastStart ? now - lastStart : 0
      if elapsed < minimumInterval {
        wait(after: minimumInterval - elapsed)
        return
      }
    }
    cancelWake?()
    cancelWake = nil
    wakeID = nil
    pending = nil
    lastStart = now
    let read = HistoryRead(request: request, process: makeProcess())
    active = read
    do {
      try read.process.start(
        executable: "/usr/bin/log", arguments: LogArguments.history(boot: boot), timeoutSeconds: 30,
        chunk: { [weak self, weak read] data in
          guard let self, let read, self.active === read, !self.stopped, !read.stopping else {
            return
          }
          guard data.count <= 8 * 1024 * 1024 - read.bytes else {
            read.capture.invalidate()
            read.stop()
            return
          }
          read.bytes += data.count
          read.digest.update(data: data)
          for item in read.framer.feed(data) {
            switch item {
            case .line(let line): read.capture.consume(line)
            case .gap: read.capture.invalidate()
            }
          }
        },
        finished: { [weak self, weak read] code in
          guard let self, let read else { return }
          self.finish(read, code: code)
        })
    } catch {
      read.capture.invalidate()
      finish(read, code: -1)
    }
  }

  private func wait(after delay: UInt64) {
    guard wakeID == nil else { return }
    let id = UUID()
    wakeID = id
    cancelWake = schedule(delay) { [weak self] in
      guard let self, self.wakeID == id else { return }
      self.wakeID = nil
      self.cancelWake = nil
      // Recheck continuous time: a timer can arrive early or after another request or stop.
      self.pump()
    }
  }

  private func finish(_ read: HistoryRead, code: Int32) {
    guard active === read else { return }
    active = nil
    guard !stopped else { return }
    driver.history(
      read.capture, id: read.request.id, context: read.request.context, exitCode: code,
      truncated: read.framer.finish(), evidenceHash: read.evidenceHash)
    pump()
  }

  func stop() {
    stopped = true
    pending = nil
    wakeID = nil
    cancelWake?()
    cancelWake = nil
    active?.stop()
  }
}
