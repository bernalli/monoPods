import Darwin
import Foundation
import MonoPodsCore

/// Input is already a closed, sanitized trace contract; raw system messages never enter this sink.
public final class DiagnosticLog {
  private let files: AtomicRuntimeFiles
  private let maximumBytes: Int64
  private let openTrace: () throws -> Int32
  public init(files: AtomicRuntimeFiles, maximumBytes: Int64 = Int64(DiagnosticLimits.fileBytes)) {
    self.files = files
    self.maximumBytes = maximumBytes
    self.openTrace = {
      try files.checkedFile("trace-v2.jsonl", flags: O_WRONLY | O_APPEND, create: true)
    }
  }
  init(files: AtomicRuntimeFiles, maximumBytes: Int64, openTrace: @escaping () throws -> Int32) {
    self.files = files
    self.maximumBytes = maximumBytes
    self.openTrace = openTrace
  }
  public func append(_ record: TraceRecord) throws {
    guard record.valid else { throw RuntimeError.invalid }
    var line = try JSONEncoder().encode(record)
    line.append(10)
    guard line.count <= 65536 else { throw RuntimeError.invalid }
    var fd = try openTrace()
    defer {
      if fd >= 0 { close(fd) }
    }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw RuntimeError.io(errno) }
    if info.st_size > 0 && info.st_size + Int64(line.count) > maximumBytes {
      if let old = try files.read("trace-v2.jsonl.1", limit: Int(maximumBytes) + 65536) {
        _ = old
      }
      guard
        renameat(files.descriptor, "trace-v2.jsonl", files.descriptor, "trace-v2.jsonl.1") == 0
      else {
        throw RuntimeError.io(errno)
      }
      close(fd)
      fd = -1
      fd = try openTrace()
    }
    try line.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(
          fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard written > 0 else { throw RuntimeError.io(errno) }
        offset += written
      }
    }
  }
}
