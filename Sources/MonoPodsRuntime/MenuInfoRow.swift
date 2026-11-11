import AppKit

/// The layout of standard menu items, so that information rows drawn by a view line up with them.
///
/// AppKit has no API for the position of an item's title. Row height and the widths of the state
/// and image columns are measured from `NSMenu.size`. On macOS 27 an image does not widen a menu
/// measured off screen, so the image column then falls back to the value seen on screen. The inset
/// of a plain title from the menu's edge cannot be measured this way and is the macOS 27 value.
public struct MenuMetrics: Equatable, Sendable {
  /// The height of one standard item.
  public var rowHeight: CGFloat
  /// From the menu's left edge to the title of an item without state or image.
  public var titleInset: CGFloat
  /// Added before titles when the menu shows a state column.
  public var stateColumn: CGFloat
  /// Added before titles when an item of the group shows an image.
  public var imageColumn: CGFloat
  /// After the title, up to the menu's right edge.
  public var trailingInset: CGFloat

  public init(
    rowHeight: CGFloat, titleInset: CGFloat, stateColumn: CGFloat, imageColumn: CGFloat,
    trailingInset: CGFloat
  ) {
    self.rowHeight = rowHeight
    self.titleInset = titleInset
    self.stateColumn = stateColumn
    self.imageColumn = imageColumn
    self.trailingInset = trailingInset
  }

  /// Values seen on macOS 27; also used when a measurement is implausible.
  public static let fallback = MenuMetrics(
    rowHeight: 24, titleInset: 17, stateColumn: 14, imageColumn: 22.5, trailingInset: 16)

  /// Measured once, from menus that are never shown.
  @MainActor public static let system = measure()

  @MainActor static func measure() -> MenuMetrics {
    let title = "MonoPods"
    func size(items: Int = 1, state: NSControl.StateValue = .off, image: Bool = false) -> NSSize {
      let menu = NSMenu()
      for _ in 0..<items {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.state = state
        if image {
          item.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        }
      }
      return menu.size
    }
    let fallback = MenuMetrics.fallback
    let plain = size()
    let width = NSAttributedString(
      string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)]
    ).size().width
    func plausible(_ value: CGFloat, in range: ClosedRange<CGFloat>, else other: CGFloat)
      -> CGFloat
    {
      range.contains(value) ? value : other
    }
    return MenuMetrics(
      rowHeight: plausible(
        size(items: 2).height - plain.height, in: 16...40, else: fallback.rowHeight),
      titleInset: fallback.titleInset,
      stateColumn: plausible(
        size(state: .on).width - plain.width, in: 0...40, else: fallback.stateColumn),
      imageColumn: plausible(
        size(image: true).width - plain.width, in: 8...48, else: fallback.imageColumn),
      trailingInset: plausible(
        plain.width - fallback.titleInset - width, in: 4...60, else: fallback.trailingInset))
  }
}

/// Where an information row draws its symbol and its text, measured from the menu's left edge.
struct InfoRowLayout: Equatable {
  var symbolInset: CGFloat
  var textInset: CGFloat
}

/// The content of an information row: text and an optional symbol in the secondary label color.
///
/// A menu item with a view does not draw its title, state or highlight; the view draws everything.
/// The item stays disabled, so it cannot be chosen, is skipped by keyboard navigation and is not
/// highlighted. The text is a static label, which VoiceOver reads as static text.
final class InfoRowView: NSView {
  let label = NSTextField(labelWithString: "")
  let symbolView = NSImageView()
  private(set) var symbol: String?
  private var rowLayout = InfoRowLayout(symbolInset: 0, textInset: 0)
  private var trailingInset: CGFloat = 0

  init(height: CGFloat) {
    super.init(frame: NSRect(x: 0, y: 0, width: 1, height: height))
    autoresizingMask = [.width]
    label.font = NSFont.menuFont(ofSize: 0)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    // Stated explicitly: VoiceOver reads the row as static text, not as a control.
    label.setAccessibilityRole(.staticText)
    symbolView.contentTintColor = .secondaryLabelColor
    symbolView.imageScaling = .scaleProportionallyDown
    // The symbol repeats the text's meaning; VoiceOver reads only the text.
    symbolView.setAccessibilityElement(false)
    symbolView.isHidden = true
    addSubview(symbolView)
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("InfoRowView is created in code")
  }

  /// Changes the text in place. The width follows the text only while the menu is closed: AppKit
  /// does not support resizing a menu item view during menu tracking.
  func update(text: String, symbol: String?, layout: InfoRowLayout, trailingInset: CGFloat) {
    if label.stringValue != text { label.stringValue = text }
    if self.symbol != symbol {
      self.symbol = symbol
      symbolView.image = symbol.flatMap {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
          .withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular))
      }
      symbolView.isHidden = symbolView.image == nil
    }
    rowLayout = layout
    self.trailingInset = trailingInset
    if window == nil {
      // The cell draws the text inside a padding on each side; on macOS 27 the label's intrinsic
      // width leaves that padding out, and a label of that width truncates its text.
      let textWidth = label.cell?.cellSize.width ?? label.intrinsicContentSize.width
      let width = ceil(layout.textInset + textWidth + trailingInset)
      if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
    }
    needsLayout = true
  }

  /// The insets count from the menu's edge; the view itself may start further in.
  override func layout() {
    super.layout()
    let offset = window == nil ? 0 : max(0, convert(NSPoint.zero, to: nil).x)
    let textX = max(0, rowLayout.textInset - offset)
    let textHeight = label.intrinsicContentSize.height
    label.frame = NSRect(
      x: textX, y: ((bounds.height - textHeight) / 2).rounded(),
      width: max(0, bounds.width - textX - trailingInset), height: textHeight)
    if let image = symbolView.image {
      let size = image.size
      symbolView.frame = NSRect(
        x: max(0, rowLayout.symbolInset - offset), y: ((bounds.height - size.height) / 2).rounded(),
        width: size.width, height: size.height)
    }
  }
}
