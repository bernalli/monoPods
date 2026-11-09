import Foundation

/// Bundle metadata shared by the version menu item and the About window.
public struct AppInformation: Equatable, Sendable {
  public let name: String
  public let version: String?
  public let build: String?
  public let copyright: String?

  public init(infoDictionary: [String: Any]?) {
    func text(_ key: String) -> String? {
      guard let value = infoDictionary?[key] as? String else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    name = text("CFBundleName") ?? "MonoPods"
    version = text("CFBundleShortVersionString")
    build = text("CFBundleVersion")
    copyright = text("NSHumanReadableCopyright")
  }

  public var versionLabel: String {
    switch (version, build) {
    case (.some(let version), .some(let build)): return "Version \(version) (\(build))"
    case (.some(let version), .none): return "Version \(version)"
    case (.none, .some(let build)): return "Version Unavailable (Build \(build))"
    case (.none, .none): return "Version Unavailable"
    }
  }
}
