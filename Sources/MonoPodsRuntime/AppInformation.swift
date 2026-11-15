import Foundation

/// Bundle metadata of the About window.
public struct AppInformation: Equatable, Sendable {
  public let name: String
  public let version: String?
  public let copyright: String?

  public init(infoDictionary: [String: Any]?) {
    func text(_ key: String) -> String? {
      guard let value = infoDictionary?[key] as? String else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    name = text("CFBundleName") ?? "MonoPods"
    version = text("CFBundleShortVersionString")
    copyright = text("NSHumanReadableCopyright")
  }

  /// The version line of the About window, in English in every language.
  public var englishVersionLabel: String {
    guard let version else { return "Version Unavailable" }
    return "Version \(version)"
  }
}
