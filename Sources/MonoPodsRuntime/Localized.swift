import Foundation

/// Visible text from the app's `Localizable` table. The key is the English text, so a missing
/// table or key shows English.
public enum Localized {
  public static let table = "Localizable"
  public static func text(_ key: String, bundle: Bundle = .main) -> String {
    bundle.localizedString(forKey: key, value: key, table: table)
  }
  public static func format(_ key: String, _ arguments: String..., bundle: Bundle = .main) -> String
  {
    String(format: text(key, bundle: bundle), arguments: arguments.map { $0 as NSString })
  }
}
