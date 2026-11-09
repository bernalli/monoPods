import Darwin
import Foundation

/// The login launch agent: a closed eight-key plist, written atomically or removed.
/// Nothing else is read or changed: no launchctl and no other file.
public struct LaunchAgentFile: Sendable {
  public let directory: String
  public let label: String
  public let executable: String
  public let bundleIdentifier: String
  private let before: @Sendable (FileStage) throws -> Void
  private static let fileMode: mode_t = 0o644
  private static let directoryMode: mode_t = 0o755
  private static let readLimit = 65536

  public init(
    directory: String, label: String, executable: String, bundleIdentifier: String,
    before: @escaping @Sendable (FileStage) throws -> Void = { _ in }
  ) {
    self.directory = directory
    self.label = label
    self.executable = executable
    self.bundleIdentifier = bundleIdentifier
    self.before = before
  }
  public var path: String { directory + "/" + name }
  private var name: String { label + ".plist" }

  /// The agent for the running bundle, or nil when the bundle is not installed: only a copy
  /// under /Applications or an isolated test copy launches at login.
  public static func installed(_ bundle: Bundle, location: RuntimeLocation) -> LaunchAgentFile? {
    guard let identifier = bundle.bundleIdentifier,
      location.role == .isolatedHarness || bundle.bundleURL.path.hasPrefix("/Applications/")
    else { return nil }
    return LaunchAgentFile(
      directory: location.launchAgentsDirectory, label: identifier + ".agent",
      executable: bundle.bundleURL.appendingPathComponent("Contents/MacOS/MonoPods").path,
      bundleIdentifier: identifier)
  }

  /// Fixed template; every value is escaped, and a control character is an error.
  public func render() throws -> Data {
    let label = try Self.escaped(label)
    let executable = try Self.escaped(executable)
    let identifier = try Self.escaped(bundleIdentifier)
    let lines = [
      #"<?xml version="1.0" encoding="UTF-8"?>"#,
      #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "#
        + #""http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
      #"<plist version="1.0">"#,
      "<dict>",
      "\t<key>Label</key>",
      "\t<string>\(label)</string>",
      "\t<key>ProgramArguments</key>",
      "\t<array>",
      "\t\t<string>\(executable)</string>",
      "\t</array>",
      "\t<key>RunAtLoad</key>",
      "\t<true/>",
      "\t<key>KeepAlive</key>",
      "\t<dict>",
      "\t\t<key>SuccessfulExit</key>",
      "\t\t<false/>",
      "\t</dict>",
      "\t<key>ThrottleInterval</key>",
      "\t<integer>10</integer>",
      "\t<key>LimitLoadToSessionType</key>",
      "\t<string>Aqua</string>",
      "\t<key>ProcessType</key>",
      "\t<string>Interactive</string>",
      "\t<key>AssociatedBundleIdentifiers</key>",
      "\t<array>",
      "\t\t<string>\(identifier)</string>",
      "\t</array>",
      "</dict>",
      "</plist>",
    ]
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }
  private static func escaped(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
      throw RuntimeError.invalid
    }
    var result = ""
    for character in value.unicodeScalars {
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&apos;"
      default: result.unicodeScalars.append(character)
      }
    }
    return result
  }

  /// Writes the agent when enabled and different, removes it when disabled.
  /// Returns whether the file changed.
  @discardableResult public func apply(enabled: Bool) throws -> Bool {
    if enabled {
      let data = try render()
      let folder = try openDirectory()
      defer { close(folder) }
      guard try differs(from: data, in: folder) else { return false }
      try write(data, in: folder)
      return true
    }
    let folder = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard folder >= 0 else {
      guard errno == ENOENT else { throw RuntimeError.io(errno) }
      return false
    }
    defer { close(folder) }
    var info = stat()
    if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw RuntimeError.io(errno) }
      return false
    }
    // unlink removes a link itself, never its target; a directory fails.
    guard unlinkat(folder, name, 0) == 0 else { throw RuntimeError.io(errno) }
    guard fsync(folder) == 0 else { throw RuntimeError.io(errno) }
    return true
  }
  private func openDirectory() throws -> Int32 {
    var fd = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if fd < 0, errno == ENOENT {
      // Only the last component is created; the parent must exist.
      guard mkdir(directory, Self.directoryMode) == 0 else { throw RuntimeError.io(errno) }
      fd = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0 else { throw RuntimeError.io(errno) }
      guard fchmod(fd, Self.directoryMode) == 0 else {
        close(fd)
        throw RuntimeError.io(errno)
      }
    }
    guard fd >= 0 else { throw RuntimeError.io(errno) }
    return fd
  }
  /// Different = absent, not a regular file, other bytes, or a mode other than 0644.
  private func differs(from data: Data, in folder: Int32) throws -> Bool {
    var info = stat()
    if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw RuntimeError.io(errno) }
      return true
    }
    if info.st_mode & S_IFMT == S_IFDIR { throw RuntimeError.unsafePath }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == Self.fileMode,
      Int(info.st_size) == data.count
    else { return true }
    let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return true }
    defer { close(fd) }
    var current = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while current.count <= Self.readLimit {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { return current != data }
      if count < 0 {
        if errno == EINTR { continue }
        throw RuntimeError.io(errno)
      }
      current.append(contentsOf: buffer.prefix(count))
    }
    return true
  }
  private func write(_ data: Data, in folder: Int32) throws {
    let temporary = "." + name + "." + UUID().uuidString
    let fd = openat(
      folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, Self.fileMode)
    guard fd >= 0 else { throw RuntimeError.io(errno) }
    var renamed = false
    defer {
      close(fd)
      if !renamed { unlinkat(folder, temporary, 0) }
    }
    guard fchmod(fd, Self.fileMode) == 0 else { throw RuntimeError.io(errno) }
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
    guard renameat(folder, temporary, folder, name) == 0 else { throw RuntimeError.io(errno) }
    renamed = true
    try before(.directorySync)
    guard fsync(folder) == 0 else { throw RuntimeError.io(errno) }
  }
}
