/// Line layout for informational menu items.
///
/// A native menu item is a single line and the menu grows to its widest item. Status and notice
/// texts can exceed 100 characters, so free text is split into several disabled items of at most
/// `width` characters instead of one item that would stretch the menu across the screen. Nothing
/// is truncated: joining the lines with spaces gives back the original words.
public enum MenuText {
  /// About the width of the menu's fixed labels, so wrapped text does not widen the menu.
  public static let width = 44

  /// Spaces that join two words: a line never breaks there.
  static let noBreakSpaces: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2007}"]

  /// Splits `text` at spaces into lines of at most `width` characters. A word longer than `width`
  /// is split inside the word. Empty or blank text gives no lines, so its menu item is omitted.
  /// A no-break space stays inside its line, as it is.
  public static func lines(_ text: String, width: Int = MenuText.width) -> [String] {
    guard !text.allSatisfy(\.isWhitespace) else { return [] }
    let limit = max(1, width)
    var lines: [String] = []
    var current = ""
    for word in text.split(whereSeparator: { $0.isWhitespace && !noBreakSpaces.contains($0) }) {
      var word = Substring(word)
      while word.count > limit {
        if !current.isEmpty {
          lines.append(current)
          current = ""
        }
        lines.append(String(word.prefix(limit)))
        word = word.dropFirst(limit)
      }
      if word.isEmpty { continue }
      if current.isEmpty {
        current = String(word)
      } else if current.count + 1 + word.count <= limit {
        current += " " + word
      } else {
        lines.append(current)
        current = String(word)
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }
}
