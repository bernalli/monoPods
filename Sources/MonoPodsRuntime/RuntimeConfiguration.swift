import CryptoKit
import Foundation
import MonoPodsCore

public struct RuntimeConfiguration: Codable, Sendable {
  public let v: Int
  public let runtimeDirectory: String
  public let launchAgentsDirectory: String
  public static func decode(_ data: Data) throws -> Self {
    let value = try ContractValidation.decode(Self.self, data: data)
    guard value.v == 1, safe(value.runtimeDirectory), safe(value.launchAgentsDirectory) else {
      throw RuntimeError.invalid
    }
    return value
  }
  private static func safe(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/").contains("..")
  }
  /// Real audio hardware belongs only to the exact product identity; every other copy stays inert.
  public static func mayUseRealAudio(identifier: String?) -> Bool {
    identifier == "io.github.bernalli.monopods"
  }
}
public enum ArtifactHash {
  public static func data(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  public static func file(_ url: URL) throws -> String {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    return data(try unsignedExecutable(bytes))
  }
  /// Hash Mach-O code and load commands, excluding only the embedded signature payload
  /// and its offset/size. This avoids a manifest/resource-signature circular dependency.
  private static func unsignedExecutable(_ bytes: Data) throws -> Data {
    guard bytes.count >= 32, Array(bytes.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] else {
      return bytes
    }
    func word(_ offset: Int) throws -> Int {
      guard offset >= 0, offset + 4 <= bytes.count else { throw RuntimeError.invalid }
      return (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }
    let commands = try word(16)
    guard commands <= 65536 else { throw RuntimeError.invalid }
    var cursor = 32
    for _ in 0..<commands {
      let kind = try word(cursor)
      let size = try word(cursor + 4)
      guard size >= 8, cursor + size <= bytes.count else { throw RuntimeError.invalid }
      if kind == 0x1d {
        guard size == 16 else { throw RuntimeError.invalid }
        let start = try word(cursor + 8)
        let length = try word(cursor + 12)
        guard start >= cursor + size, start + length == bytes.count else {
          throw RuntimeError.invalid
        }
        var result = Data(bytes.prefix(start))
        result.replaceSubrange(
          (cursor + 8)..<(cursor + 16), with: repeatElement(UInt8(0), count: 8))
        return result
      }
      cursor += size
    }
    return bytes
  }
}
public struct BundleManifest: Codable, Sendable {
  public let v: Int
  public let build: String
  public let sourceCommit: String
  public let files: [String: String]
  public init(build: String, sourceCommit: String, files: [String: String]) {
    self.v = 1
    self.build = build
    self.sourceCommit = sourceCommit
    self.files = files
  }
  public static let required: Set<String> = [
    "Contents/MacOS/MonoPods", "Contents/Info.plist", "Contents/Resources/AppIcon.icns",
    "Contents/Resources/MenuBarIcon.png", "Contents/Resources/MenuBarIcon@2x.png",
    "Contents/Resources/GitHubMark.pdf", "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
    "Contents/Resources/Sparkle-LICENSE.txt",
    "Contents/Resources/PlusJakartaSans-SemiBold.ttf",
    "Contents/Resources/PlusJakartaSans-OFL.txt",
  ]
  public func verify(bundle: URL) throws {
    guard v == 1, ContractValidation.hash(build),
      sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
      Set(files.keys) == Self.required,
      files["Contents/MacOS/MonoPods"] == build
    else { throw RuntimeError.invalid }
    for (relative, expected) in files {
      guard ContractValidation.hash(expected), !relative.hasPrefix("/"),
        !relative.split(separator: "/").contains("..")
      else { throw RuntimeError.invalid }
      var url = bundle
      for component in relative.split(separator: "/") {
        url.appendPathComponent(String(component))
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
          throw RuntimeError.unsafePath
        }
      }
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
        try ArtifactHash.file(url) == expected
      else { throw RuntimeError.invalid }
    }
  }
}
