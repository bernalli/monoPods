import Foundation

/// Web pages the About window links to. The repository keeps its `monoPods` name.
public enum ProjectLinks {
  public static let repository = URL(string: "https://github.com/bernalli/monoPods")!
  public static let sponsors = URL(string: "https://github.com/sponsors/bernalli")!
  /// A blank issue form; the user writes and submits it, the app sends nothing.
  public static let newIssue = URL(string: "https://github.com/bernalli/monoPods/issues/new")!
}
