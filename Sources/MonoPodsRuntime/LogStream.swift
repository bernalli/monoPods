import Darwin
import Foundation
import MonoPodsCore

public enum FramedLine: Equatable, Sendable {
  case line(Data)
  case gap
}
public struct NDJSONFramer: Sendable {
  private var buffer = Data()
  private var discarding = false
  public init() {}
  public mutating func feed(_ chunk: Data) -> [FramedLine] {
    var output: [FramedLine] = []
    for byte in chunk {
      if byte == 10 {
        if !discarding { output.append(.line(buffer)) }
        buffer.removeAll(keepingCapacity: true)
        discarding = false
      } else if !discarding {
        if buffer.count == 65536 {
          output.append(.gap)
          discarding = true
          buffer.removeAll(keepingCapacity: true)
        } else {
          buffer.append(byte)
        }
      }
    }
    return output
  }
  public func finish() -> Bool { discarding || !buffer.isEmpty }
}
public struct HistoryCapture: Sendable {
  public private(set) var records: [LogRecord] = []
  public private(set) var malformed = false
  private var finalCount: UInt64?
  public init() {}
  public mutating func invalidate() { malformed = true }
  public mutating func consume(_ data: Data) {
    guard !malformed, finalCount == nil, records.count < 10000 else {
      malformed = true
      return
    }
    do {
      switch try SystemLogEnvelope.decode(data) {
      case .event(let record): records.append(record)
      case .finished(let count): finalCount = count
      }
    } catch { malformed = true }
  }
  public func complete(exitCode: Int32, truncated: Bool) -> Bool {
    exitCode == 0 && !truncated && !malformed && finalCount == UInt64(records.count)
  }
}

public enum LogArguments {
  public static let predicate =
    "(process == 'bluetoothd' AND subsystem == 'com.apple.bluetooth' AND category == 'Server.AACP')"
    + " OR (process == 'audioaccessoryd' AND subsystem == 'com.apple.bluetooth' AND category == 'BTSmartRoutingDaemon')"
    + " OR (process == 'mediaremoted' AND subsystem == 'com.apple.amp.mediaremote' AND category == 'MediaRemote')"
    + " OR (process == 'mediaremoted' AND subsystem == 'com.apple.amp.mediaremote' AND category == 'NowPlaying'"
    + " AND eventMessage BEGINSWITH '" + EarLine.nowPlayingPrefix + "')"
    + " OR (subsystem == 'io.github.bernalli.monopods' AND category == 'heartbeat')"
  public static let stream = [
    "stream", "--style", "ndjson", "--level", "default", "--type", "log", "--predicate", predicate,
  ]
  public static func history(boot: String) -> [String] {
    [
      "show", "--style", "ndjson", "--last", "15m", "--predicate",
      "(" + predicate + ") AND bootUUID == '" + boot + "'",
    ]
  }
}

/// Owns only its log child. Output is bounded and drained before the exit callback.
@MainActor public final class LogProcess {
  private var child: Process?
  private var termination: ChildTermination?
  private let makeProcess: @MainActor () -> Process
  public init() { makeProcess = { Process() } }
  init(makeProcess: @escaping @MainActor () -> Process) { self.makeProcess = makeProcess }
  public func start(
    executable: String = "/usr/bin/log", arguments: [String], timeoutSeconds: UInt64? = nil,
    chunk: @escaping @MainActor @Sendable (Data) -> Void,
    finished: @escaping @MainActor @Sendable (Int32) -> Void
  ) throws {
    guard child == nil else { throw RuntimeError.busy }
    let process = makeProcess()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    // Check the absolute deadline off the main actor after output drains and waitUntilExit returns.
    // A late child exit cannot succeed, even when the background deadline runs late.
    // Delayed draining or scheduling can conservatively time out an earlier exit.
    // This does not impose a deadline on callback delivery.
    let deadline = timeoutSeconds.map { ContinuousClock.now + .seconds($0) }
    let termination = ChildTermination(timeoutSeconds: timeoutSeconds) { pid, signal in
      // Foundation can reap before its handler acquires our lock. isRunning narrows that window;
      // exit/reaping between this check and kill remains a residual PID-reuse race with POSIX PIDs.
      if process.isRunning { kill(pid, signal) }
    }
    process.terminationHandler = { [weak termination] _ in termination?.didExit() }
    try process.run()
    child = process
    self.termination = termination
    termination.arm(pid: process.processIdentifier)
    Task.detached {
      do {
        while let data = try pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
          await chunk(data)
        }
      } catch {
        // Exit callback reports a broken capture through framing and status.
      }
      process.waitUntilExit()
      termination.didExit()
      let status = process.terminationStatus
      let late = deadline.map { ContinuousClock.now >= $0 } ?? false
      await MainActor.run { [weak self] in
        self?.termination = nil
        self?.child = nil
        finished(late ? -1 : status)
      }
    }
  }
  public func stop() {
    termination?.stop()
  }
}
