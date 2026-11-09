import Darwin
import Foundation

public enum RuntimeRole: Equatable, Sendable { case product, isolatedHarness }

public struct RuntimeEnvironment: Equatable, Sendable {
  public let home: String
  public let temporaryRoots: [String]
  public init(home: String, temporaryRoots: [String]) {
    self.home = home
    self.temporaryRoots = temporaryRoots
  }
  /// Home from the account database (getpwuid_r of getuid), never from the HOME variable.
  public static func current() throws -> RuntimeEnvironment {
    var size = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
    if size <= 0 { size = 16384 }
    var buffer = [CChar](repeating: 0, count: size)
    var record = passwd()
    var result: UnsafeMutablePointer<passwd>?
    let home: String? = buffer.withUnsafeMutableBufferPointer { storage in
      guard getpwuid_r(getuid(), &record, storage.baseAddress, storage.count, &result) == 0,
        result != nil, let directory = record.pw_dir
      else { return nil }
      return String(validatingCString: directory)
    }
    guard let home, RuntimeLocation.validHome(home) else { throw RuntimeError.unsafePath }
    let temporary = FileManager.default.temporaryDirectory.path
    let canonical = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
    return RuntimeEnvironment(home: home, temporaryRoots: [temporary, canonical, "/private/tmp"])
  }
}

public struct RuntimeLocation: Equatable, Sendable {
  public static let productIdentifier = "io.github.bernalli.monopods"
  public static let harnessIdentifierPrefix = "io.github.bernalli.monopods.test."
  public static let harnessFileName = "IsolatedRuntime.json"
  private static let harnessFileLimit = 65536
  public let role: RuntimeRole
  public let runtimeDirectory: String
  public let launchAgentsDirectory: String

  /// Pure: no file system and no environment access.
  public static func resolve(
    identifier: String?, harnessFile: Data?, environment: RuntimeEnvironment
  ) throws -> RuntimeLocation {
    // The home folder must be a safe absolute path.
    let home = environment.home
    guard validHome(home) else { throw RuntimeError.unsafePath }
    // A missing or empty bundle identifier is refused.
    guard let identifier, !identifier.isEmpty else { throw RuntimeError.invalid }
    // The product uses fixed folders and rejects any supplied harness file.
    if identifier == productIdentifier {
      guard harnessFile == nil else { throw RuntimeError.invalid }
      return RuntimeLocation(
        role: .product,
        runtimeDirectory: home + "/Library/Application Support/" + productIdentifier,
        launchAgentsDirectory: home + "/Library/LaunchAgents")
    }
    // Any other identifier must belong to the test harness.
    guard identifier.hasPrefix(harnessIdentifierPrefix) else { throw RuntimeError.invalid }
    // The harness suffix is short and plain.
    let suffix = identifier.dropFirst(harnessIdentifierPrefix.count)
    guard suffix.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else {
      throw RuntimeError.invalid
    }
    // The harness needs its configuration file.
    guard let harnessFile else { throw RuntimeError.invalid }
    // Both configured folders are normalized before any check.
    let config = try RuntimeConfiguration.decode(harnessFile)
    let runtime = try normalized(config.runtimeDirectory)
    let agents = try normalized(config.launchAgentsDirectory)
    let roots = environment.temporaryRoots.compactMap(normalizedRoot)
    // Both folders lie strictly inside a temporary root.
    for directory in [runtime, agents] {
      guard
        roots.contains(where: { directory.hasPrefix($0 + "/") && directory.count > $0.count + 1 })
      else { throw RuntimeError.unsafePath }
    }
    // Neither folder may contain the other.
    let first = components(runtime)
    let second = components(agents)
    guard !first.starts(with: second), !second.starts(with: first) else {
      throw RuntimeError.invalid
    }
    return RuntimeLocation(
      role: .isolatedHarness, runtimeDirectory: runtime, launchAgentsDirectory: agents)
  }

  /// Reads Contents/Resources/IsolatedRuntime.json when present (regular file, not a link,
  /// at most 65536 bytes), then calls the pure overload.
  public static func resolve(bundle: Bundle, environment: RuntimeEnvironment) throws
    -> RuntimeLocation
  {
    let path = bundle.bundleURL.appendingPathComponent("Contents/Resources/" + harnessFileName).path
    return try resolve(
      identifier: bundle.bundleIdentifier, harnessFile: try readHarnessFile(path),
      environment: environment)
  }

  private static func readHarnessFile(_ path: String) throws -> Data? {
    var info = stat()
    if lstat(path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError.io(errno) }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.unsafePath }
    guard info.st_size <= harnessFileLimit else { throw RuntimeError.invalid }
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw RuntimeError.unsafePath }
    defer { close(fd) }
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw RuntimeError.unsafePath
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0 {
        if errno == EINTR { continue }
        throw RuntimeError.io(errno)
      }
      guard result.count + count <= harnessFileLimit else { throw RuntimeError.invalid }
      result.append(contentsOf: buffer.prefix(count))
    }
  }

  static func validHome(_ home: String) -> Bool {
    home.hasPrefix("/") && home != "/" && !home.contains("\0") && !home.hasSuffix("/")
      && components(home).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  /// Components after the leading separator; empty strings mark repeated separators.
  private static func components(_ path: String) -> [Substring] {
    path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { $0 }
  }
  /// Only the system /var and /tmp aliases are rewritten; no other link is resolved.
  private static func aliased(_ path: String) -> String {
    path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
  }
  private static func normalized(_ path: String) throws -> String {
    guard validHome(path) else { throw RuntimeError.unsafePath }
    return aliased(path)
  }
  /// A malformed or empty root never contains anything.
  private static func normalizedRoot(_ root: String) -> String? {
    var root = root
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    return validHome(root) ? aliased(root) : nil
  }
}

public enum RuntimeDirectory {
  private static let mode: mode_t = 0o700
  private static let support = "Application Support"

  /// Creates the missing leaf (and, for the product, a missing Application Support) with mode
  /// 0700, then opens it with AtomicRuntimeFiles. Never changes an existing directory.
  public static func ensure(_ location: RuntimeLocation) throws -> AtomicRuntimeFiles {
    var path = canonicalComponents(location.runtimeDirectory)
    guard let leaf = path.popLast() else { throw RuntimeError.unsafePath }
    let parent: Int32
    switch location.role {
    case .product:
      // Everything up to <home>/Library must already exist.
      guard path.popLast() == support else { throw RuntimeError.unsafePath }
      let library = try walk(path)
      defer { close(library) }
      // Application Support may be created.
      parent = try openOrCreate(support, in: library)
    case .isolatedHarness:
      // The harness parent must already exist.
      parent = try walk(path)
    }
    defer { close(parent) }
    // The final folder is created with its mode, or must already exist.
    if mkdirat(parent, leaf, mode) == 0 {
      let fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw RuntimeError.unsafePath }
      defer { close(fd) }
      guard fchmod(fd, mode) == 0 else { throw RuntimeError.io(errno) }
    } else if errno != EEXIST {
      throw RuntimeError.io(errno)
    }
    // The files are opened inside the folder just checked.
    return try AtomicRuntimeFiles(directory: URL(fileURLWithPath: location.runtimeDirectory))
  }

  /// Read-only: nil when only the final component is missing; never creates anything.
  public static func openExisting(_ location: RuntimeLocation) throws -> AtomicRuntimeFiles? {
    var path = canonicalComponents(location.runtimeDirectory)
    guard let leaf = path.popLast() else { throw RuntimeError.unsafePath }
    let parent = try walk(path)
    defer { close(parent) }
    var info = stat()
    // Only a missing final component is allowed.
    if fstatat(parent, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw RuntimeError.io(errno) }
      return nil
    }
    return try AtomicRuntimeFiles(directory: URL(fileURLWithPath: location.runtimeDirectory))
  }

  private static func canonicalComponents(_ path: String) -> [String] {
    let canonical = path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
    return canonical.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(
      String.init)
  }
  /// Opens every component from the root without following links.
  private static func walk(_ components: [String]) throws -> Int32 {
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw RuntimeError.io(errno) }
    for component in components {
      guard !component.isEmpty, component != ".", component != ".." else {
        close(fd)
        throw RuntimeError.unsafePath
      }
      let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      close(fd)
      guard next >= 0 else { throw RuntimeError.unsafePath }
      fd = next
    }
    return fd
  }
  private static func openOrCreate(_ name: String, in folder: Int32) throws -> Int32 {
    if mkdirat(folder, name, mode) != 0, errno != EEXIST { throw RuntimeError.io(errno) }
    let fd = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw RuntimeError.unsafePath }
    return fd
  }
}
