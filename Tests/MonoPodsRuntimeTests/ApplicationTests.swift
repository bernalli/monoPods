import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

/// The isolated runtime file of a test copy: the only runtime configuration a bundle can carry.
@Test func isolatedRuntimeFileRejectsMissingKeysRelativePathsAndUnknownVersions() throws {
  let valid = #"{"v":1,"runtimeDirectory":"/tmp/runtime","launchAgentsDirectory":"/tmp/agents"}"#
  for text in [
    #"{}"#, valid.replacingOccurrences(of: "\"v\":1", with: "\"v\":2"),
    valid.replacingOccurrences(of: "/tmp/runtime", with: "relative"),
    valid.replacingOccurrences(of: "\"}", with: "\",\"extra\":1}"),
    #"{"v":1,"runtimeDirectory":"/tmp/runtime"}"#,
    valid.replacingOccurrences(of: "/tmp/agents", with: "agents"),
    valid.replacingOccurrences(of: "/tmp/agents", with: "/tmp/../agents"),
    valid.replacingOccurrences(of: "/tmp/agents", with: "/tmp/agents\\u0000"),
    valid.replacingOccurrences(of: "\"/tmp/agents\"", with: "null"),
  ] {
    #expect(throws: (any Error).self, "\(text)") {
      try RuntimeConfiguration.decode(Data(text.utf8))
    }
  }
  let config = try RuntimeConfiguration.decode(Data(valid.utf8))
  #expect(config.runtimeDirectory == "/tmp/runtime")
  #expect(config.launchAgentsDirectory == "/tmp/agents")
}

@Test func manifestRejectsChangedPlistAndTraversal() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let agentPlist = "Contents/Library/LaunchAgents/io.github.bernalli.monopods.agent.plist"
  // The bundle carries no launch agent plist: the app writes the agent itself.
  #expect(
    BundleManifest.required == [
      "Contents/MacOS/MonoPods", "Contents/Info.plist", "Contents/Resources/AppIcon.icns",
      "Contents/Resources/MenuBarIcon.png", "Contents/Resources/MenuBarIcon@2x.png",
      "Contents/Resources/GitHubMark.pdf",
      "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
      "Contents/Resources/Sparkle-LICENSE.txt",
    ])
  #expect(
    !BundleManifest.required.contains("Contents/Resources/" + RuntimeLocation.harnessFileName))
  var hashes: [String: String] = [:]
  for relative in BundleManifest.required.union([agentPlist]) {
    let path = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("artifact".utf8).write(to: path)
    hashes[relative] = ArtifactHash.data(Data("artifact".utf8))
  }
  let listed = BundleManifest(
    build: ArtifactHash.data(Data("artifact".utf8)),
    sourceCommit: "0123456789abcdef0123456789abcdef01234567", files: hashes)
  #expect(throws: (any Error).self) { try listed.verify(bundle: root) }
  hashes.removeValue(forKey: agentPlist)
  let manifest = BundleManifest(
    build: ArtifactHash.data(Data("artifact".utf8)),
    sourceCommit: "0123456789abcdef0123456789abcdef01234567", files: hashes)
  try manifest.verify(bundle: root)
  let plist = root.appendingPathComponent("Contents/Info.plist")
  try Data("changed plist".utf8).write(to: plist)
  #expect(throws: (any Error).self) { try manifest.verify(bundle: root) }
  let hostile = BundleManifest(
    build: testBuild, sourceCommit: "0123456789abcdef0123456789abcdef01234567",
    files: ["../escape": testBuild])
  #expect(throws: (any Error).self) { try hostile.verify(bundle: root) }
}

@MainActor @Test func failedCrashPresentationKeepsDurableNoticePending() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try AtomicRuntimeFiles(directory: root)
  let owner = try InstanceLock(files: files, name: "owner.lock")
  var record = JournalRecord(run: 1, build: testBuild)
  record.lifecycle.closedCleanly = false
  try files.persist(record: record)
  var presented: [Notice] = []
  let now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:00Z"))
  let fifo = EngineFIFO(
    engine: Engine(
      build: testBuild, run: 2, boot: "00000000-0000-4000-8000-000000000001"),
    clock: { now },
    execute: { action, reply in
      if case .persist(let request) = action {
        do {
          try files.persist(record: request.record)
          reply(.persistenceAcknowledged(run: 2, id: request.id, success: true))
        } catch { reply(.persistenceAcknowledged(run: 2, id: request.id, success: false)) }
      } else {
        if case .showNotice(let notice) = action {
          presented.append(notice)
          reply(.noticePresented(notice, success: false))
        }
      }
    })
  fifo.enqueue(.journalLoaded(files.load()))
  fifo.flush()
  #expect(presented == [.previousCrash])
  guard case .record(let saved) = files.load() else {
    Issue.record("missing journal")
    return
  }
  #expect(saved.lifecycle.noticePending)
  withExtendedLifetime(owner) {}
}

@Test func executableHashExcludesEmbeddedSignatureButDetectsCodeChanges() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let binary = root.appendingPathComponent("binary")
  // Mach-O 64-bit header, one LC_CODE_SIGNATURE, 16 code bytes and 4 signature bytes.
  let magic: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe] + [UInt8](repeating: 0, count: 12)
  let commandCount: [UInt8] = [1, 0, 0, 0, 16, 0, 0, 0] + [UInt8](repeating: 0, count: 8)
  let signatureCommand: [UInt8] = [0x1d, 0, 0, 0, 16, 0, 0, 0, 64, 0, 0, 0, 4, 0, 0, 0]
  let payload: [UInt8] = [UInt8](repeating: 7, count: 16) + [UInt8](repeating: 1, count: 4)
  var bytes = Data(magic + commandCount + signatureCommand + payload)
  try bytes.write(to: binary)
  let original = try ArtifactHash.file(binary)
  bytes[67] = 2
  try bytes.write(to: binary)
  #expect(try ArtifactHash.file(binary) == original)
  bytes[50] = 9
  try bytes.write(to: binary)
  #expect(try ArtifactHash.file(binary) != original)
}

func rejectsAsUnsafePath(_ body: () throws -> Void) -> Bool {
  do {
    try body()
    return false
  } catch RuntimeError.unsafePath { return true } catch { return false }
}
@Test func manifestRejectsSymlinkedFilesAndDirectories() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundle = root.appendingPathComponent("MonoPods.app")
  var hashes: [String: String] = [:]
  for relative in BundleManifest.required {
    let path = bundle.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("artifact".utf8).write(to: path)
    hashes[relative] = ArtifactHash.data(Data("artifact".utf8))
  }
  let manifest = BundleManifest(
    build: ArtifactHash.data(Data("artifact".utf8)),
    sourceCommit: "0123456789abcdef0123456789abcdef01234567", files: hashes)
  try manifest.verify(bundle: bundle)
  // Same bytes behind the link: only the link itself can cause the rejection.
  let outside = root.appendingPathComponent("outside")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
  let icon = bundle.appendingPathComponent("Contents/Resources/MenuBarIcon.png")
  let target = outside.appendingPathComponent("MenuBarIcon.png")
  try FileManager.default.moveItem(at: icon, to: target)
  try FileManager.default.createSymbolicLink(at: icon, withDestinationURL: target)
  #expect(rejectsAsUnsafePath { try manifest.verify(bundle: bundle) })
  try FileManager.default.removeItem(at: icon)
  try FileManager.default.moveItem(at: target, to: icon)
  try manifest.verify(bundle: bundle)
  let resources = bundle.appendingPathComponent("Contents/Resources")
  let moved = outside.appendingPathComponent("Resources")
  try FileManager.default.moveItem(at: resources, to: moved)
  try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: moved)
  #expect(rejectsAsUnsafePath { try manifest.verify(bundle: bundle) })
}
