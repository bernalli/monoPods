import Darwin
import Foundation
import MonoPodsCore

public enum FileStage: Sendable { case fileSync, rename, directorySync }
public enum RuntimeError: Error {
  case unsafePath
  case io(Int32)
  case busy, invalid, child
}

/// All operations are relative to a pinned, private directory descriptor.
public final class AtomicRuntimeFiles: RuntimeFiles, @unchecked Sendable {
  public let directory: URL
  let descriptor: Int32
  private let before: @Sendable (FileStage) throws -> Void

  public init(directory: URL, before: @escaping @Sendable (FileStage) throws -> Void = { _ in })
    throws
  {
    guard directory.isFileURL, directory.path.hasPrefix("/"),
      !directory.pathComponents.contains("..")
    else {
      throw RuntimeError.unsafePath
    }
    // Foundation preserves the system /var and /tmp aliases on macOS.
    let path = directory.path
    let canonical =
      path.hasPrefix("/var/") || path.hasPrefix("/tmp/")
      ? URL(fileURLWithPath: "/private" + path) : directory
    // Walk each component without following links, including the final directory.
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw RuntimeError.io(errno) }
    for component in canonical.pathComponents.dropFirst() {
      let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      close(fd)
      guard next >= 0 else { throw RuntimeError.unsafePath }
      fd = next
    }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
      close(fd)
      throw RuntimeError.unsafePath
    }
    self.directory = canonical
    self.descriptor = fd
    self.before = before
  }
  deinit { close(descriptor) }

  func checkedFile(_ name: String, flags: Int32, create: Bool = false) throws -> Int32 {
    guard !name.contains("/"), name != ".", name != "..", !name.isEmpty else {
      throw RuntimeError.unsafePath
    }
    let fd = openat(
      descriptor, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (create ? O_CREAT : 0), 0o600)
    guard fd >= 0 else { throw RuntimeError.io(errno) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1
    else {
      close(fd)
      throw RuntimeError.unsafePath
    }
    return fd
  }
  public func read(_ name: String, limit: Int = 65536) throws -> Data? {
    let fd: Int32
    do { fd = try checkedFile(name, flags: O_RDONLY) } catch RuntimeError.io(ENOENT) { return nil }
    defer { close(fd) }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0 {
        if errno == EINTR { continue }
        throw RuntimeError.io(errno)
      }
      guard result.count + count <= limit else { throw RuntimeError.invalid }
      result.append(contentsOf: buffer.prefix(count))
    }
  }
  public func write(_ data: Data, name: String) throws {
    guard data.count <= 65536 else { throw RuntimeError.invalid }
    // Validate an existing target before replacement (never replace a link).
    if let fd = try existing(name) { close(fd) }
    let temporary = ".atomic-" + UUID().uuidString
    let fd = try checkedFile(temporary, flags: O_WRONLY | O_EXCL, create: true)
    defer {
      close(fd)
      unlinkat(descriptor, temporary, 0)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          throw RuntimeError.io(errno)
        }
        guard count > 0 else { throw RuntimeError.invalid }
        offset += count
      }
    }
    try before(.fileSync)
    guard fsync(fd) == 0 else { throw RuntimeError.io(errno) }
    try before(.rename)
    if let target = try existing(name) { close(target) }
    guard renameat(descriptor, temporary, descriptor, name) == 0 else {
      throw RuntimeError.io(errno)
    }
    try before(.directorySync)
    guard fsync(descriptor) == 0 else { throw RuntimeError.io(errno) }
  }
  private func existing(_ name: String) throws -> Int32? {
    do { return try checkedFile(name, flags: O_RDONLY) } catch RuntimeError.io(ENOENT) {
      return nil
    }
  }
  public func load() -> RuntimeLoad {
    do {
      guard let data = try read("restore.json") else { return .missing }
      return .record(try JournalRecord.decode(data))
    } catch { return .blocked }
  }
  public func persist(record: JournalRecord) throws {
    guard record.contractValid else { throw RuntimeError.invalid }
    try write(JSONEncoder().encode(record), name: "restore.json")
  }
}
