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
  private var timedOut = false
  private var timeout: Task<Void, Never>?
  public init() {}
  public func start(
    executable: String = "/usr/bin/log", arguments: [String], timeoutSeconds: UInt64? = nil,
    chunk: @escaping @MainActor @Sendable (Data) -> Void,
    finished: @escaping @MainActor @Sendable (Int32) -> Void
  ) throws {
    guard child == nil else { throw RuntimeError.busy }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    timedOut = false
    try process.run()
    child = process
    if let timeoutSeconds {
      timeout = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        if !Task.isCancelled {
          self?.timedOut = true
          self?.stop()
        }
      }
    }
    Task.detached {
      do {
        while let data = try pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
          await chunk(data)
        }
      } catch {
        // Exit callback reports a broken capture through framing and status.
      }
      process.waitUntilExit()
      let status = process.terminationStatus
      await MainActor.run { [weak self] in
        self?.timeout?.cancel()
        self?.timeout = nil
        self?.child = nil
        finished(self?.timedOut == true ? -1 : status)
      }
    }
  }
  public func stop() {
    guard let child, child.isRunning else { return }
    child.terminate()
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }
  }
}
