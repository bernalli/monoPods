import CoreAudio
import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private final class SelfCheckHardware: AudioHardware, @unchecked Sendable {
  var reading = AudioHardwareReading(status: 0, rawValue: 7, byteCount: 4)
  var preference = SystemMono.off
  var property = AudioPropertyCheck(status: 0, value: true)
  var settable = AudioPropertyCheck(status: 0, value: true)
  private let lock = NSLock()
  private var calls: [String] = []
  var operations: [String] { lock.withLock { calls } }
  private func note(_ name: String) { lock.withLock { calls.append(name) } }
  func hasMode() -> AudioPropertyCheck {
    note("has")
    return property
  }
  func modeIsSettable() -> AudioPropertyCheck {
    note("settable")
    return settable
  }
  func readMode() -> AudioHardwareReading {
    note("read")
    return reading
  }
  func readSystemMono() -> SystemMono {
    note("preference")
    return preference
  }
  func setMode(_ value: UInt32) -> Int32 {
    note("set")
    return -1
  }
  func addListener(_ listener: AudioHardwareListener) -> Int32 {
    note("add")
    return -1
  }
  func removeListener(_ listener: AudioHardwareListener) -> Int32 {
    note("remove")
    return -1
  }
}

private struct SelfCheckFixture {
  let root: URL
  let bundle: Bundle
  let files: AtomicRuntimeFiles
  let hardware = SelfCheckHardware()
  let date = Date(timeIntervalSince1970: 0)

  var environment: RuntimeEnvironment {
    RuntimeEnvironment(home: root.path + "/home", temporaryRoots: [root.path])
  }

  init() throws {
    root = try temporaryRuntime()
    let support = root.appendingPathComponent("home/Library/Application Support")
    try FileManager.default.createDirectory(
      at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let runtime = support.appendingPathComponent("io.github.bernalli.monopods")
    try FileManager.default.createDirectory(
      at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    files = try AtomicRuntimeFiles(directory: runtime)
    let app = root.appendingPathComponent("MonoPods.app")
    var contents = Dictionary(
      uniqueKeysWithValues: BundleManifest.required.map { ($0, Data("artifact".utf8)) })
    contents["Contents/Info.plist"] = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "io.github.bernalli.monopods", "CFBundleName": "MonoPods",
        "CFBundleExecutable": "MonoPods", "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0)
    for (relative, data) in contents {
      let url = app.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
    let manifest = BundleManifest(
      build: ArtifactHash.data(contents["Contents/MacOS/MonoPods"]!),
      sourceCommit: String(repeating: "b", count: 40), files: contents.mapValues(ArtifactHash.data))
    try JSONEncoder().encode(manifest).write(
      to: app.appendingPathComponent("Contents/Resources/Manifest.json"))
    bundle = try #require(Bundle(url: app))
  }

  @MainActor func run(mediaAvailable: Bool = true) async -> SelfCheckResult {
    await BundleSelfCheck.run(
      bundle: bundle, hardware: hardware, now: date, mediaAvailable: mediaAvailable,
      environment: environment)
  }
}

@MainActor @Test func selfCheckReportsCurrentReadingAndDurableStateWithoutWriting() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var record = JournalRecord(run: 19, build: testBuild)
  record.audio.phase = .completed
  record.audio.restoreRequired = true
  record.audio.nextId = 3
  record.audio.lastCompleted = CommandReceipt(id: 2, target: .mono, exitCode: -50)
  try fixture.files.persist(record: record)
  let before = try fixture.files.read("restore.json")
  let report = await fixture.run()
  #expect(report.succeeded)
  for line in [
    "Timestamp: 1970-01-01T00:00:00Z", "Audio OSStatus: 0", "Audio Raw: 7",
    "Audio Mode: mono", "System Mono Audio: off", "Journal: valid", "Run: 19",
    "Build: \(testBuild)", "Phase: completed", "Restore Required: true",
    "Last Target: mono", "Last Outcome: -50", "Bundle Path: \(fixture.bundle.bundleURL.path)",
    "Runtime Directory: \(fixture.files.directory.path)",
  ] {
    #expect(report.output.contains(line + "\n"))
  }
  #expect(report.output.contains("Bundle Build: \(ArtifactHash.data(Data("artifact".utf8)))\n"))
  #expect(try fixture.files.read("restore.json") == before)
  #expect(fixture.hardware.operations == ["has", "settable", "read", "preference"])
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: fixture.files.directory.path) == [
      "restore.json"
    ])
}

@MainActor @Test func selfCheckMissingJournalRemainsMissingAndUnknown() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  fixture.hardware.reading = AudioHardwareReading(status: 0, rawValue: 0, byteCount: 4)
  fixture.hardware.preference = .unreadable
  let report = await fixture.run()
  #expect(report.succeeded)
  for line in [
    "Journal: missing", "Run: unknown", "Build: unknown", "Phase: unknown",
    "Restore Required: unknown", "Last Target: unknown", "Last Outcome: unknown",
    "Audio Raw: 0", "Audio Mode: stereo", "System Mono Audio: unreadable (treated as off)",
  ] {
    #expect(report.output.contains(line + "\n"))
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.files.directory.path).isEmpty)
}

@MainActor @Test func selfCheckRejectsMalformedDuplicateTruncatedAndSymlinkJournals() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let valid = try JSONEncoder().encode(JournalRecord(run: 1, build: testBuild))
  let text = try #require(String(data: valid, encoding: .utf8))
  let duplicate = Data(("{\"v\":1," + text.dropFirst()).utf8)
  for data in [Data("not json".utf8), duplicate, Data(valid.dropLast())] {
    try fixture.files.write(data, name: "restore.json")
    let report = await fixture.run()
    #expect(!report.succeeded)
    #expect(report.output.contains("Journal: unknown\n"))
    #expect(report.output.contains("Restore Required: unknown\n"))
    #expect(try fixture.files.read("restore.json") == data)
    #expect(!report.output.contains("not json"))
  }
  let journal = fixture.files.directory.appendingPathComponent("restore.json")
  try FileManager.default.removeItem(at: journal)
  let target = fixture.root.appendingPathComponent("target")
  try valid.write(to: target)
  try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: target)
  let report = await fixture.run()
  #expect(!report.succeeded)
  #expect(report.output.contains("Journal: unknown\n"))
  #expect(try Data(contentsOf: target) == valid)
  // A URL may answer from its cached resource values, so ask the file system directly.
  let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
  #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
  #expect(!fixture.hardware.operations.contains("set"))
}

@MainActor @Test func selfCheckReadErrorsHaveNonzeroStatusAndUnknownValue() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  for (status, size, expected) in [
    (Int32.min, UInt32(4), Int32.min), (0, 3, kAudioHardwareBadPropertySizeError),
    (Int32.max, 4, Int32.max),
  ] {
    fixture.hardware.reading = AudioHardwareReading(status: status, rawValue: 99, byteCount: size)
    let report = await fixture.run()
    #expect(!report.succeeded)
    #expect(report.output.contains("Audio OSStatus: \(expected)\n"))
    #expect(report.output.contains("Audio Raw: unknown\n"))
    #expect(report.output.contains("Audio Mode: unknown\n"))
  }
  #expect(!fixture.hardware.operations.contains("set"))
}

@MainActor @Test func selfCheckUnavailablePropertyAndNonsettableHardwareFailReadOnly() async throws
{
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  for property in [
    AudioPropertyCheck(status: -50, value: true), AudioPropertyCheck(status: 0, value: false),
  ] {
    fixture.hardware.property = property
    let report = await fixture.run()
    #expect(!report.succeeded)
    #expect(report.output.contains("Audio Mode: unknown\n"))
    #expect(!report.output.contains("Audio OSStatus: 0\n"))
  }
  fixture.hardware.property = AudioPropertyCheck(status: 0, value: true)
  fixture.hardware.settable = AudioPropertyCheck(status: 0, value: false)
  let report = await fixture.run()
  #expect(!report.succeeded)
  #expect(!fixture.hardware.operations.contains("set"))
}

@MainActor @Test func selfCheckInvalidBundleAndPreferencesFailWithoutLeakingContents() async throws
{
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.files.write(Data("PRIVATE CONTENT".utf8), name: "preferences.json")
  let badPreferences = await fixture.run()
  #expect(!badPreferences.succeeded)
  #expect(!badPreferences.output.contains("PRIVATE CONTENT"))
  let plist = fixture.bundle.bundleURL.appendingPathComponent("Contents/Info.plist")
  try Data("PRIVATE CONTENT".utf8).write(to: plist)
  let badBundle = await fixture.run()
  #expect(!badBundle.succeeded)
  #expect(badBundle.output.contains("Runtime Directory: unknown\n"))
  #expect(!badBundle.output.contains("PRIVATE CONTENT"))
  #expect(!fixture.hardware.operations.contains("set"))
}

@MainActor @Test func selfCheckReportsSystemOverrideAndFullRawValueWithoutSetting() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  fixture.hardware.preference = .on
  fixture.hardware.reading = AudioHardwareReading(status: 0, rawValue: UInt32.max, byteCount: 4)
  let report = await fixture.run()
  #expect(report.succeeded)
  #expect(report.output.contains("Audio Raw: 4294967295\n"))
  #expect(report.output.contains("Audio Mode: mono\n"))
  #expect(report.output.contains("System Mono Audio: on\n"))
  #expect(fixture.hardware.operations == ["has", "settable", "read", "preference"])
}

@MainActor @Test func selfCheckReportsAPresentRuntimeDirectory() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.files.write(JSONEncoder().encode(ControlPreferences()), name: "preferences.json")
  let report = await fixture.run()
  #expect(report.succeeded)
  let runtime = fixture.files.directory.path
  #expect(runtime.hasSuffix("/home/Library/Application Support/io.github.bernalli.monopods"))
  #expect(report.output.contains("Runtime Directory: \(runtime)\nRuntime State: present\n"))
  #expect(report.output.contains("Journal: missing\n"))
  #expect(report.output.contains("Preferences: valid\n"))
}

@MainActor @Test func selfCheckMissingRuntimeIsReportedAndNotCreated() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try FileManager.default.removeItem(at: fixture.files.directory)
  let report = await fixture.run()
  #expect(report.succeeded)
  for line in [
    "Runtime State: missing", "Journal: missing", "Preferences: missing", "Phase: unknown",
  ] {
    #expect(report.output.contains(line + "\n"))
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.files.directory.path))
}

@MainActor @Test func selfCheckRuntimeWithAnotherModeFails() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  #expect(chmod(fixture.files.directory.path, 0o755) == 0)
  let report = await fixture.run()
  #expect(!report.succeeded)
  #expect(report.output.contains("Runtime State: unknown\n"))
  #expect(report.output.contains("Journal: unknown\n"))
  let attributes = try FileManager.default.attributesOfItem(atPath: fixture.files.directory.path)
  #expect(attributes[.posixPermissions] as? Int == 0o755)
}

@MainActor @Test func selfCheckUnavailableMediaFailsAndIsReported() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let report = await fixture.run(mediaAvailable: false)
  #expect(!report.succeeded)
  #expect(report.output.contains("MediaRemote: unavailable\n"))
}

@MainActor @Test func selfCheckAcceptsValidPreferencesWithoutRewritingThem() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let data = try JSONEncoder().encode(ControlPreferences())
  try fixture.files.write(data, name: "preferences.json")
  let report = await fixture.run()
  #expect(report.succeeded)
  #expect(report.output.contains("Preferences: valid\n"))
  #expect(try fixture.files.read("preferences.json") == data)
}

@MainActor @Test func selfCheckRefusesJournalPastTheReadLimitAndUnsafeFileKinds() async throws {
  let fixture = try SelfCheckFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let journal = fixture.files.directory.appendingPathComponent("restore.json")
  let valid = try JSONEncoder().encode(JournalRecord(run: 1, build: testBuild))
  func install(_ data: Data, mode: Int = 0o600) throws {
    try? FileManager.default.removeItem(at: journal)
    try data.write(to: journal)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: journal.path)
  }
  // Only the length separates these two: JSON whitespace keeps the record valid.
  let padded = valid + Data(repeating: 32, count: 65536 - valid.count)
  try install(padded)
  #expect(try fixture.files.read("restore.json")?.count == 65536)
  #expect((await fixture.run()).output.contains("Journal: valid\n"))
  try install(padded + Data([32]))
  #expect(throws: (any Error).self) { try fixture.files.read("restore.json") }
  let oversized = await fixture.run()
  #expect(!oversized.succeeded)
  #expect(oversized.output.contains("Journal: unknown\n"))
  // A wrong mode, a second hard link and a directory are refused before any content is used.
  try install(valid, mode: 0o644)
  #expect(!(await fixture.run()).succeeded)
  try install(valid)
  let link = fixture.root.appendingPathComponent("hardlink")
  try FileManager.default.linkItem(at: journal, to: link)
  #expect(!(await fixture.run()).succeeded)
  try FileManager.default.removeItem(at: link)
  try FileManager.default.removeItem(at: journal)
  try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
  #expect(!(await fixture.run()).succeeded)
  #expect(!fixture.hardware.operations.contains("set"))
}
