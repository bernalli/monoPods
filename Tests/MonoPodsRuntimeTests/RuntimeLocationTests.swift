import Darwin
import Foundation
import Testing

@testable import MonoPodsRuntime

private let product = RuntimeLocation.productIdentifier
private let harness = "io.github.bernalli.monopods.test.0123abcd"
private let supportSuffix = "/Library/Application Support/io.github.bernalli.monopods"
private let temporaryEnvironment = RuntimeEnvironment(
  home: "/Users/a", temporaryRoots: ["/var/folders/T", "/private/var/folders/T", "/private/tmp"])

private func harnessText(_ runtime: String, _ agents: String) -> String {
  #"{"v":1,"runtimeDirectory":"\#(runtime)","launchAgentsDirectory":"\#(agents)"}"#
}
private func harnessFile(_ runtime: String, _ agents: String) -> Data {
  Data(harnessText(runtime, agents).utf8)
}
private let validHarnessText = harnessText("/private/tmp/h/runtime", "/private/tmp/h/agents")
private let validHarnessFile = Data(validHarnessText.utf8)

private func resolve(
  _ identifier: String?, _ file: Data?, _ environment: RuntimeEnvironment = temporaryEnvironment
) throws -> RuntimeLocation {
  try RuntimeLocation.resolve(identifier: identifier, harnessFile: file, environment: environment)
}
private func mode(_ path: String) throws -> Int {
  var info = stat()
  guard lstat(path, &info) == 0 else { throw RuntimeError.io(errno) }
  return Int(info.st_mode & 0o7777)
}
private func owner(_ path: String) throws -> uid_t {
  var info = stat()
  guard lstat(path, &info) == 0 else { throw RuntimeError.io(errno) }
  return info.st_uid
}
/// The spelling AtomicRuntimeFiles keeps: Foundation drops /private from temporary paths.
private func canonical(_ path: String) -> String {
  path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
}
private func exists(_ path: String) -> Bool {
  var info = stat()
  return lstat(path, &info) == 0
}

/// A temporary home with `Library` present; the caller removes `root`.
private struct TemporaryHome {
  let root: URL
  let home: String
  var environment: RuntimeEnvironment {
    RuntimeEnvironment(home: home, temporaryRoots: [root.path])
  }
  var library: String { home + "/Library" }
  var support: String { home + "/Library/Application Support" }
  var runtime: String { home + supportSuffix }
  init(library: Bool = true) throws {
    root = try temporaryRuntime()
    home = root.path + "/home"
    try FileManager.default.createDirectory(
      atPath: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    if library {
      try FileManager.default.createDirectory(
        atPath: home + "/Library", withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
  }
  func location() throws -> RuntimeLocation { try resolve(product, nil, environment) }
}

/// Deterministic generator with a fixed seed (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
private let componentAlphabet = Array(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
private func generatedComponents(_ generator: inout SeededGenerator) -> [String] {
  (0..<Int.random(in: 1...4, using: &generator)).map { _ in
    while true {
      let length = Int.random(in: 1...12, using: &generator)
      let text = String(
        (0..<length).map { _ in componentAlphabet.randomElement(using: &generator)! })
      if text != ".", text != ".." { return text }
    }
  }
}

@Test func productLocationComesFromTheHome() throws {
  for home in ["/Users/a", "/Users/a.b-c_d", "/Volumes/Home/x"] {
    let environment = RuntimeEnvironment(home: home, temporaryRoots: ["/private/tmp"])
    let location = try resolve(product, nil, environment)
    #expect(location.role == .product)
    #expect(location.runtimeDirectory == home + supportSuffix)
    #expect(location.launchAgentsDirectory == home + "/Library/LaunchAgents")
  }
}

@Test func productWithATestFileIsInvalid() {
  for file in [validHarnessFile, Data("{}".utf8), Data()] {
    #expect(throws: (any Error).self) { try resolve(product, file) }
  }
}

@Test func harnessUsesTheDirectoriesOfItsFile() throws {
  let location = try resolve(harness, validHarnessFile)
  #expect(location.role == .isolatedHarness)
  #expect(location.runtimeDirectory == "/private/tmp/h/runtime")
  #expect(location.launchAgentsDirectory == "/private/tmp/h/agents")
  let aliased = try resolve(
    harness, harnessFile("/var/folders/T/x/runtime", "/var/folders/T/x/agents"))
  #expect(aliased.runtimeDirectory == "/private/var/folders/T/x/runtime")
  #expect(aliased.launchAgentsDirectory == "/private/var/folders/T/x/agents")
}

@Test func harnessWithoutAFileIsInvalid() {
  #expect(throws: (any Error).self) { try resolve(harness, nil) }
}

@Test func harnessDirectoriesMustBothStayUnderATemporaryRoot() {
  #expect(throws: (any Error).self) {
    try resolve(harness, harnessFile("/Users/a/runtime", "/private/tmp/h/agents"))
  }
  #expect(throws: (any Error).self) {
    try resolve(harness, harnessFile("/private/tmp/h/runtime", "/Users/a/Library/LaunchAgents"))
  }
}

@Test func malformedHarnessFilesAreInvalid() {
  let runtime = "/private/tmp/h/runtime"
  let agents = "/private/tmp/h/agents"
  let valid = validHarnessText
  var cases = [
    #"{}"#,
    valid.replacingOccurrences(of: #""v":1"#, with: #""v":2"#),
    valid.replacingOccurrences(of: #""v":1"#, with: #""v":true"#),
    valid.replacingOccurrences(of: #""v":1"#, with: #""v":"1""#),
    #"{"v":1,"runtimeDirectory":"\#(runtime)"}"#,
    valid.replacingOccurrences(of: "\"}", with: "\",\"extra\":1}"),
    valid.replacingOccurrences(of: #"{"v":1,"#, with: #"{"v":1,"v":1,"#),
    harnessText("relative", agents),
    harnessText("/private/tmp/h/../runtime", agents),
    harnessText(runtime + "\\u0000", agents),
    valid.replacingOccurrences(of: "\"\(agents)\"", with: "null"),
    valid.replacingOccurrences(of: "\"\(agents)\"", with: "1"),
    harnessText("", agents),
    harnessText(runtime, runtime),
    harnessText(runtime, runtime + "/agents"),
    harnessText("/private/tmp", agents),
    harnessText("/private/tmpX/a", agents),
  ]
  // The valid file is ASCII, so every byte prefix is a character prefix.
  for length in 0..<valid.count {
    cases.append(String(valid.prefix(length)))
  }
  for text in cases {
    #expect(throws: (any Error).self, "\(text)") { try resolve(harness, Data(text.utf8)) }
  }
}

@Test func unknownAndMalformedIdentifiersAreInvalid() {
  let identifiers: [String?] = [
    nil, "", "io.github.bernalli.monopods2", "io.github.bernalli.monopods.test.",
    "io.github.bernalli.monopods.test.a/b", "io.github.bernalli.monopods.test..",
    "io.github.bernalli.monopods.test." + String(repeating: "a", count: 65),
    "IO.GITHUB.BERNALLI.MONOPODS", "io.github.bernalli.monopods.agent",
  ]
  for identifier in identifiers {
    #expect(throws: (any Error).self, "\(String(describing: identifier))") {
      try resolve(identifier, validHarnessFile)
    }
    #expect(throws: (any Error).self, "\(String(describing: identifier))") {
      try resolve(identifier, nil)
    }
  }
}

@Test func unsafeHomesAreRejected() {
  for home in [
    "relative", "/", "", "/Users/a/", "/Users//a", "/Users/./a", "/Users/../a", "/Users/a\u{0}b",
  ] {
    let environment = RuntimeEnvironment(home: home, temporaryRoots: ["/private/tmp"])
    #expect(throws: (any Error).self, "\(home)") { try resolve(product, nil, environment) }
  }
}

@Test func generatedHomesKeepTheRuntimeInsideTheHome() throws {
  var generator = SeededGenerator(state: 0x4D6F_6E6F_506F_6473)
  for _ in 0..<200 {
    let home = "/" + generatedComponents(&generator).joined(separator: "/")
    let environment = RuntimeEnvironment(home: home, temporaryRoots: ["/private/tmp"])
    let location = try resolve(product, nil, environment)
    #expect(location.role == .product)
    #expect(location.runtimeDirectory == home + supportSuffix)
    #expect(location.launchAgentsDirectory == home + "/Library/LaunchAgents")
    #expect(location.runtimeDirectory.hasPrefix(home + "/"))
  }
}

@Test func generatedHarnessPathsCompareAfterAliasNormalization() throws {
  var generator = SeededGenerator(state: 0x5275_6E74_696D_6521)
  let aliases = [("/var/folders/T", "/private/var/folders/T"), ("/tmp", "/private/tmp")]
  for _ in 0..<200 {
    let first = generatedComponents(&generator)
    let second = generatedComponents(&generator)
    for (short, long) in aliases {
      let environment = RuntimeEnvironment(home: "/Users/a", temporaryRoots: [long])
      let a = short + "/r/" + first.joined(separator: "/")
      let b = long + "/a/" + second.joined(separator: "/")
      // Disjoint after normalization: accepted, normalized spellings kept.
      let location = try resolve(harness, harnessFile(a, b), environment)
      #expect(location.runtimeDirectory == long + "/r/" + first.joined(separator: "/"))
      #expect(location.launchAgentsDirectory == b)
      // The same directory through the other alias, and a descendant through it: refused.
      let same = long + "/r/" + first.joined(separator: "/")
      let child = same + "/" + second[0]
      for (runtime, agents) in [(a, same), (same, a), (a, child), (child, a)] {
        #expect(throws: (any Error).self, "\(runtime) \(agents)") {
          try resolve(harness, harnessFile(runtime, agents), environment)
        }
      }
      // Dot components, repeated separators and a final slash are refused before comparing.
      for spelling in [
        short + "/r/./" + first.joined(separator: "/"),
        short + "/r//" + first.joined(separator: "/"),
        short + "/r/" + first.joined(separator: "/") + "/",
      ] {
        #expect(throws: (any Error).self, "\(spelling)") {
          try resolve(harness, harnessFile(spelling, b), environment)
        }
        #expect(throws: (any Error).self, "\(spelling)") {
          try resolve(harness, harnessFile(b, spelling), environment)
        }
      }
    }
  }
}

@Test func ensureCreatesApplicationSupportAndAPrivateLeaf() throws {
  let fixture = try TemporaryHome()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let files = try RuntimeDirectory.ensure(fixture.location())
  #expect(files.directory.path == canonical(fixture.runtime))
  #expect(try mode(fixture.support) == 0o700)
  #expect(try mode(fixture.runtime) == 0o700)
  #expect(try owner(fixture.runtime) == getuid())
}

@Test func ensureWithoutLibraryFailsAndCreatesNothing() throws {
  let fixture = try TemporaryHome(library: false)
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  #expect(throws: (any Error).self) { try RuntimeDirectory.ensure(fixture.location()) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home).isEmpty)
}

@Test func ensureRefusesAnExistingLeafWithAnotherModeWithoutChangingIt() throws {
  for existing in [0o755, 0o750, 0o711] {
    let fixture = try TemporaryHome()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.createDirectory(
      atPath: fixture.runtime, withIntermediateDirectories: true)
    #expect(chmod(fixture.runtime, mode_t(existing)) == 0)
    #expect(throws: (any Error).self) { try RuntimeDirectory.ensure(fixture.location()) }
    #expect(try mode(fixture.runtime) == existing)
  }
}

@Test func ensureRefusesLinksAndFiles() throws {
  let leafLink = try TemporaryHome()
  defer { try? FileManager.default.removeItem(at: leafLink.root) }
  let target = leafLink.root.path + "/target"
  try FileManager.default.createDirectory(
    atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  try FileManager.default.createDirectory(
    atPath: leafLink.support, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  try FileManager.default.createSymbolicLink(atPath: leafLink.runtime, withDestinationPath: target)
  #expect(throws: (any Error).self) { try RuntimeDirectory.ensure(leafLink.location()) }

  let leafFile = try TemporaryHome()
  defer { try? FileManager.default.removeItem(at: leafFile.root) }
  try FileManager.default.createDirectory(
    atPath: leafFile.support, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  try Data("file".utf8).write(to: URL(fileURLWithPath: leafFile.runtime))
  #expect(throws: (any Error).self) { try RuntimeDirectory.ensure(leafFile.location()) }

  let intermediate = try TemporaryHome(library: false)
  defer { try? FileManager.default.removeItem(at: intermediate.root) }
  let realLibrary = intermediate.root.path + "/real-library"
  try FileManager.default.createDirectory(
    atPath: realLibrary, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  try FileManager.default.createSymbolicLink(
    atPath: intermediate.library, withDestinationPath: realLibrary)
  #expect(throws: (any Error).self) { try RuntimeDirectory.ensure(intermediate.location()) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: realLibrary).isEmpty)
}

@Test func ensureTwiceChangesNothing() throws {
  let fixture = try TemporaryHome()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let first = try RuntimeDirectory.ensure(fixture.location())
  try first.write(Data("{}".utf8), name: "marker")
  let before = try FileManager.default.attributesOfItem(atPath: fixture.runtime)
  let second = try RuntimeDirectory.ensure(fixture.location())
  let after = try FileManager.default.attributesOfItem(atPath: fixture.runtime)
  #expect(second.directory == first.directory)
  #expect(try mode(fixture.runtime) == 0o700)
  #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.runtime) == ["marker"])
  #expect(try second.read("marker") == Data("{}".utf8))
}

@Test func ensureForATestCopyCreatesOnlyTheLeaf() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let environment = RuntimeEnvironment(home: "/Users/a", temporaryRoots: [root.path])
  let location = try resolve(
    harness, harnessFile(root.path + "/runtime", root.path + "/agents"), environment)
  let files = try RuntimeDirectory.ensure(location)
  #expect(files.directory.path == canonical(root.path + "/runtime"))
  #expect(try mode(root.path + "/runtime") == 0o700)
  #expect(!exists(root.path + "/agents"))
  let orphan = try resolve(
    harness, harnessFile(root.path + "/missing/runtime", root.path + "/agents"), environment)
  #expect(throws: (any Error).self) { try RuntimeDirectory.ensure(orphan) }
  #expect(!exists(root.path + "/missing"))
}

@Test func openExistingNeverCreates() throws {
  let fixture = try TemporaryHome()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try FileManager.default.createDirectory(
    atPath: fixture.support, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  #expect(try RuntimeDirectory.openExisting(fixture.location()) == nil)
  #expect(!exists(fixture.runtime))
  try FileManager.default.createDirectory(
    atPath: fixture.runtime, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o755])
  #expect(throws: (any Error).self) { try RuntimeDirectory.openExisting(fixture.location()) }
  #expect(chmod(fixture.runtime, 0o700) == 0)
  let files = try #require(try RuntimeDirectory.openExisting(fixture.location()))
  #expect(files.directory.path == canonical(fixture.runtime))
}

@Test func bundleTestFileMustBeASmallRegularFile() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let environment = RuntimeEnvironment(home: "/Users/a", temporaryRoots: [root.path])
  let app = root.appendingPathComponent("MonoPods.app")
  let resources = app.appendingPathComponent("Contents/Resources")
  try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": harness, "CFBundlePackageType": "APPL"],
    format: .xml, options: 0
  ).write(to: app.appendingPathComponent("Contents/Info.plist"))
  let bundle = try #require(Bundle(url: app))
  let file = resources.appendingPathComponent(RuntimeLocation.harnessFileName)
  let data = harnessFile(root.path + "/runtime", root.path + "/agents")
  #expect(throws: (any Error).self) {
    try RuntimeLocation.resolve(bundle: bundle, environment: environment)
  }
  try data.write(to: file)
  let location = try RuntimeLocation.resolve(bundle: bundle, environment: environment)
  #expect(location.runtimeDirectory == canonical(root.path + "/runtime"))
  try FileManager.default.removeItem(at: file)
  let elsewhere = root.appendingPathComponent("elsewhere.json")
  try data.write(to: elsewhere)
  try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
  #expect(throws: (any Error).self) {
    try RuntimeLocation.resolve(bundle: bundle, environment: environment)
  }
  try FileManager.default.removeItem(at: file)
  try (data + Data(repeating: 32, count: 65537 - data.count)).write(to: file)
  #expect(throws: (any Error).self) {
    try RuntimeLocation.resolve(bundle: bundle, environment: environment)
  }
}

@Test func currentEnvironmentHasAnAbsoluteHomeAndTheSystemTemporaryRoot() throws {
  let environment = try RuntimeEnvironment.current()
  #expect(environment.home.hasPrefix("/"))
  #expect(!environment.home.hasSuffix("/"))
  #expect(environment.temporaryRoots.contains("/private/tmp"))
}
