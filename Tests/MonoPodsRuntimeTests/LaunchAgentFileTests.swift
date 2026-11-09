import Darwin
import Foundation
import Testing

@testable import MonoPodsRuntime

private let agentLabel = "io.github.bernalli.monopods.agent"
private let agentExecutable = "/Applications/MonoPods.app/Contents/MacOS/MonoPods"

private func agentFile(_ directory: URL, label: String = agentLabel) -> LaunchAgentFile {
  LaunchAgentFile(
    directory: directory.path, label: label, executable: agentExecutable,
    bundleIdentifier: "io.github.bernalli.monopods")
}
private func plistURL(_ directory: URL, label: String = agentLabel) -> URL {
  directory.appendingPathComponent(label + ".plist")
}
private func mode(_ url: URL) throws -> Int {
  var info = stat()
  guard lstat(url.path, &info) == 0 else { throw RuntimeError.io(errno) }
  return Int(info.st_mode & 0o7777)
}
private func entries(_ directory: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}
private func decoded(_ data: Data) throws -> [String: Any] {
  try #require(
    try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Test func absentLaunchAgentIsWrittenWithTheRenderedBytesAndMode0644() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = agentFile(root)
  #expect(try file.apply(enabled: true))
  #expect(try Data(contentsOf: plistURL(root)) == file.render())
  #expect(try mode(plistURL(root)) == 0o644)
  #expect(try entries(root) == [agentLabel + ".plist"])
  let plist = try decoded(file.render())
  #expect(Array(plist.keys).count == 8)
  #expect(plist["Label"] as? String == agentLabel)
  #expect(plist["ProgramArguments"] as? [String] == [agentExecutable])
  #expect((plist["RunAtLoad"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
  #expect(plist["RunAtLoad"] as? Bool == true)
  #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
  #expect(plist["ThrottleInterval"] as? Int == 10)
  #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
  #expect(plist["ProcessType"] as? String == "Interactive")
  #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["io.github.bernalli.monopods"])
}

@Test func renderedKeysKeepTheContractOrder() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let text = try #require(String(data: try agentFile(root).render(), encoding: .utf8))
  let order = try [
    "Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ThrottleInterval",
    "LimitLoadToSessionType", "ProcessType", "AssociatedBundleIdentifiers",
  ].map { try #require(text.range(of: "<key>\($0)</key>")?.lowerBound) }
  #expect(order == order.sorted())
}

@Test func identicalLaunchAgentIsNotRewritten() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = agentFile(root)
  try file.apply(enabled: true)
  let before = try FileManager.default.attributesOfItem(atPath: plistURL(root).path)
  #expect(try !file.apply(enabled: true))
  let after = try FileManager.default.attributesOfItem(atPath: plistURL(root).path)
  #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
  #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
}

@Test func anyDifferentLaunchAgentIsReplacedByTheRendering() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = agentFile(root)
  let rendered = try file.render()
  let text = try #require(String(data: rendered, encoding: .utf8))
  let variants: [Data] = [
    Data(
      text.replacingOccurrences(
        of: "</dict>\n</plist>", with: "\t<key>Extra</key>\n\t<true/>\n</dict>\n</plist>"
      ).utf8),
    Data(
      text.replacingOccurrences(
        of: "\t<key>ProcessType</key>\n\t<string>Interactive</string>\n", with: ""
      ).utf8),
    Data(
      text.replacingOccurrences(
        of: "<key>RunAtLoad</key>\n\t<true/>", with: "<key>RunAtLoad</key>\n\t<integer>1</integer>"
      ).utf8),
    Data(
      text.replacingOccurrences(
        of: "\t<key>ThrottleInterval</key>\n\t<integer>10</integer>\n", with: ""
      ).replacingOccurrences(
        of: "</dict>\n</plist>",
        with: "\t<key>ThrottleInterval</key>\n\t<integer>10</integer>\n</dict>\n</plist>"
      ).utf8),
    Data(),
    rendered.prefix(rendered.count / 2),
  ]
  for variant in variants {
    #expect(variant != rendered)
    try variant.write(to: plistURL(root))
    #expect(try file.apply(enabled: true))
    #expect(try Data(contentsOf: plistURL(root)) == rendered)
    #expect(try mode(plistURL(root)) == 0o644)
  }
  try file.apply(enabled: true)
  #expect(chmod(plistURL(root).path, 0o600) == 0)
  #expect(try file.apply(enabled: true))
  #expect(try mode(plistURL(root)) == 0o644)
  #expect(try entries(root) == [agentLabel + ".plist"])
}

@Test func symlinkAtTheLaunchAgentPathIsReplacedAndItsTargetKept() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let agents = root.appendingPathComponent("LaunchAgents")
  try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: false)
  let target = root.appendingPathComponent("target")
  try Data("target".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(at: plistURL(agents), withDestinationURL: target)
  let file = agentFile(agents)
  #expect(try file.apply(enabled: true))
  let values = try plistURL(agents).resourceValues(forKeys: [.isSymbolicLinkKey])
  #expect(values.isSymbolicLink == false)
  #expect(try Data(contentsOf: plistURL(agents)) == file.render())
  #expect(try Data(contentsOf: target) == Data("target".utf8))
}

@Test func directoryAtTheLaunchAgentPathFailsWithoutTouchingAnything() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let blocker = plistURL(root)
  try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
  try Data("inner".utf8).write(to: blocker.appendingPathComponent("inner"))
  #expect(throws: (any Error).self) { try agentFile(root).apply(enabled: true) }
  #expect(throws: (any Error).self) { try agentFile(root).apply(enabled: false) }
  #expect(try entries(root) == [agentLabel + ".plist"])
  #expect(try entries(blocker) == ["inner"])
}

@Test func markupCharactersRoundTripWithTheirTypes() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let hostile = "a&\u{301}b<c>d\"e'f"
  let file = LaunchAgentFile(
    directory: root.path, label: hostile, executable: "/Applications/x&<>\"'.app/MonoPods",
    bundleIdentifier: hostile)
  let plist = try decoded(file.render())
  #expect(plist["Label"] as? String == hostile)
  #expect(plist["ProgramArguments"] as? [String] == ["/Applications/x&<>\"'.app/MonoPods"])
  #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [hostile])
  #expect((plist["RunAtLoad"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true)
  #expect(plist["ThrottleInterval"] as? Int == 10)
}

@Test func controlCharactersFailWithoutWriting() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  for value in ["a\u{0}b", "a\nb", "a\tb", "a\u{1b}b", "a\u{7f}b"] {
    let file = LaunchAgentFile(
      directory: root.path, label: agentLabel, executable: "/Applications/" + value,
      bundleIdentifier: "io.github.bernalli.monopods")
    #expect(throws: (any Error).self) { try file.render() }
    #expect(throws: (any Error).self) { try file.apply(enabled: true) }
  }
  #expect(try entries(root).isEmpty)
}

@Test func missingLaunchAgentsDirectoryIsCreatedWithMode0755() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let agents = root.appendingPathComponent("LaunchAgents")
  #expect(try agentFile(agents).apply(enabled: true))
  #expect(try mode(agents) == 0o755)
  #expect(try entries(agents) == [agentLabel + ".plist"])
  let orphan = root.appendingPathComponent("missing/LaunchAgents")
  #expect(throws: (any Error).self) { try agentFile(orphan).apply(enabled: true) }
  #expect(!FileManager.default.fileExists(atPath: orphan.deletingLastPathComponent().path))
}

@Test func offRemovesOnlyTheLaunchAgentPath() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = agentFile(root)
  #expect(try !file.apply(enabled: false))
  try file.apply(enabled: true)
  #expect(try file.apply(enabled: false))
  #expect(try entries(root).isEmpty)
  let missing = root.appendingPathComponent("absent")
  #expect(try !agentFile(missing).apply(enabled: false))
  let target = root.appendingPathComponent("target")
  try Data("target".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(at: plistURL(root), withDestinationURL: target)
  #expect(try file.apply(enabled: false))
  #expect(try entries(root) == ["target"])
  #expect(try Data(contentsOf: target) == Data("target".utf8))
}

@Test func failedWriteStagesLeaveNoTemporaryFile() throws {
  for stage in [FileStage.fileSync, .rename, .directorySync] {
    let root = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = LaunchAgentFile(
      directory: root.path, label: agentLabel, executable: agentExecutable,
      bundleIdentifier: "io.github.bernalli.monopods",
      before: { if $0 == stage { throw RuntimeError.invalid } })
    #expect(throws: (any Error).self) { try file.apply(enabled: true) }
    let names = try entries(root)
    #expect(stage == .directorySync ? names == [agentLabel + ".plist"] : names.isEmpty)
  }
}

private func fakeBundle(
  in root: URL, identifier: String, runtime: URL? = nil, agents: URL
) throws -> Bundle {
  let app = root.appendingPathComponent("MonoPods-\(UUID().uuidString).app")
  let resources = app.appendingPathComponent("Contents/Resources")
  try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
  let info: [String: Any] = [
    "CFBundleIdentifier": identifier, "CFBundleExecutable": "MonoPods",
    "CFBundlePackageType": "APPL",
  ]
  try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: app.appendingPathComponent("Contents/Info.plist"))
  if let runtime {
    let config =
      #"{"v":1,"runtimeDirectory":"\#(runtime.path)","#
      + #""launchAgentsDirectory":"\#(agents.path)"}"#
    try Data(config.utf8).write(
      to: resources.appendingPathComponent(RuntimeLocation.harnessFileName))
  }
  return try #require(Bundle(url: app))
}

@Test func onlyAnInstalledBundleGetsALaunchAgent() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let environment = RuntimeEnvironment(home: root.path + "/home", temporaryRoots: [root.path])
  let agents = root.appendingPathComponent("LaunchAgents")
  let loose = try fakeBundle(in: root, identifier: "io.github.bernalli.monopods", agents: agents)
  let product = try RuntimeLocation.resolve(bundle: loose, environment: environment)
  #expect(product.role == .product)
  #expect(LaunchAgentFile.installed(loose, location: product) == nil)
  let test = "io.github.bernalli.monopods.test.\(UUID().uuidString)"
  let isolated = try fakeBundle(
    in: root, identifier: test, runtime: root.appendingPathComponent("runtime"), agents: agents)
  let location = try RuntimeLocation.resolve(bundle: isolated, environment: environment)
  let file = try #require(LaunchAgentFile.installed(isolated, location: location))
  #expect(file.label == test + ".agent")
  #expect(file.bundleIdentifier == test)
  #expect(file.directory == location.launchAgentsDirectory)
  // Foundation spells temporary paths without /private; the location keeps the canonical form.
  let canonicalAgents =
    agents.path.hasPrefix("/var/") || agents.path.hasPrefix("/tmp/")
    ? "/private" + agents.path : agents.path
  #expect(file.directory == canonicalAgents)
  #expect(
    file.executable == isolated.bundleURL.appendingPathComponent("Contents/MacOS/MonoPods").path)
  #expect(!FileManager.default.fileExists(atPath: agents.path))
}

@Test func launchAgentPathCaseChangeIsRewrittenExactlyOnce() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let old = LaunchAgentFile(
    directory: root.path, label: agentLabel,
    executable: "/Applications/monoPods.app/Contents/MacOS/MonoPods",
    bundleIdentifier: "io.github.bernalli.monopods")
  try old.apply(enabled: true)
  let file = agentFile(root)
  #expect(try file.apply(enabled: true))
  let before = try FileManager.default.attributesOfItem(atPath: file.path)
  #expect(try !file.apply(enabled: true))
  let after = try FileManager.default.attributesOfItem(atPath: file.path)
  #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
  #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
  let plist = try decoded(Data(contentsOf: URL(fileURLWithPath: file.path)))
  #expect(plist["Label"] as? String == "io.github.bernalli.monopods.agent")
  #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["io.github.bernalli.monopods"])
  #expect(
    plist["ProgramArguments"] as? [String] == ["/Applications/MonoPods.app/Contents/MacOS/MonoPods"]
  )
}
