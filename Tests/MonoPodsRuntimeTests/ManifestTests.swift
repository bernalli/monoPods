import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

@Test func releaseManifestRequiresSourceCommitInRuntime() throws {
  let root = try temporaryRuntime()
  defer { try? FileManager.default.removeItem(at: root) }
  var hashes: [String: String] = [:]
  for relative in BundleManifest.required {
    let path = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("artifact".utf8).write(to: path)
    hashes[relative] = ArtifactHash.data(Data("artifact".utf8))
  }
  let document: [String: Any] = [
    "v": 1, "build": ArtifactHash.data(Data("artifact".utf8)), "files": hashes,
    "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
  ]
  func verify(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    let manifest = try ContractValidation.decode(BundleManifest.self, data: data)
    try manifest.verify(bundle: root)
  }
  try verify(document)
  for invalid in [
    "", String(repeating: "a", count: 39), String(repeating: "A", count: 40),
    String(repeating: "g", count: 40), String(repeating: "a", count: 41),
    String(repeating: "a", count: 40) + "\n",
  ] {
    var changed = document
    changed["sourceCommit"] = invalid
    #expect(throws: (any Error).self) { try verify(changed) }
  }
  var missing = document
  missing.removeValue(forKey: "sourceCommit")
  #expect(throws: (any Error).self) { try verify(missing) }
  var extra = document
  extra["extra"] = 1
  #expect(throws: (any Error).self) { try verify(extra) }
}
