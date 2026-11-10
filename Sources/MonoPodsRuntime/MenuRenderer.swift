import AppKit

/// Turns menu rows into native menu items and keeps them current.
///
/// Every update reuses the item that already shows a row with the same `id` and kind and only
/// changes its title, state or symbol. AppKit redraws such changes while the menu is open, and an
/// open submenu stays open because its item and its `NSMenu` are the same objects.
@MainActor public final class MenuRenderer: NSObject {
  private let perform: (MenuCommand) -> Void

  public init(perform: @escaping (MenuCommand) -> Void) {
    self.perform = perform
  }

  public func apply(_ rows: [MenuRow], to menu: NSMenu) {
    // Information rows are disabled on purpose; validation must not enable them again.
    menu.autoenablesItems = false
    var existing: [String: NSMenuItem] = [:]
    for item in menu.items {
      if let key = item.identifier?.rawValue { existing[key] = item }
    }
    for (index, row) in rows.enumerated() {
      let key = Self.key(of: row)
      let item = existing.removeValue(forKey: key) ?? make(row, key: key)
      configure(item, with: row)
      if index < menu.numberOfItems, menu.item(at: index) === item { continue }
      if item.menu === menu { menu.removeItem(item) }
      menu.insertItem(item, at: index)
    }
    // Every position up to rows.count now holds its row; what follows is no longer shown.
    while menu.numberOfItems > rows.count {
      menu.removeItem(at: rows.count)
    }
  }

  /// Kind and id together: a row that changes kind needs a new item, a header in particular.
  private static func key(of row: MenuRow) -> String {
    let kind: String
    switch row.kind {
    case .header: kind = "header"
    case .info: kind = "info"
    case .toggle: kind = "toggle"
    case .action: kind = "action"
    case .submenu: kind = "submenu"
    case .separator: kind = "separator"
    }
    return "\(kind):\(row.id)"
  }

  private func make(_ row: MenuRow, key: String) -> NSMenuItem {
    let item: NSMenuItem
    switch row.kind {
    case .header: item = NSMenuItem.sectionHeader(title: row.title)
    case .separator: item = NSMenuItem.separator()
    case .submenu:
      item = RowItem(title: row.title, action: nil, keyEquivalent: "")
      item.submenu = NSMenu(title: row.title)
    case .info, .toggle, .action:
      item = RowItem(title: row.title, action: nil, keyEquivalent: "")
    }
    item.identifier = NSUserInterfaceItemIdentifier(key)
    return item
  }

  private func configure(_ item: NSMenuItem, with row: MenuRow) {
    switch row.kind {
    case .header:
      setTitle(item, row.title)
    case .separator:
      break
    case .info:
      configureInfo(item, with: row)
    case .toggle(let command, let isOn):
      configureCommand(item, row: row, command: command, enabled: true)
      let state: NSControl.StateValue = isOn ? .on : .off
      if item.state != state { item.state = state }
    case .action(let command, let enabled, let key):
      configureCommand(item, row: row, command: command, enabled: enabled)
      if item.keyEquivalent != key {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
      }
    case .submenu(let children):
      setTitle(item, row.title)
      setSymbol(item, row.symbol, informational: false)
      if item.submenu == nil { item.submenu = NSMenu(title: row.title) }
      if let submenu = item.submenu { apply(children, to: submenu) }
    }
  }

  /// A disabled item does not highlight under the pointer and cannot be chosen. Its attributed
  /// title keeps the secondary label color instead of the much lighter disabled text color.
  private func configureInfo(_ item: NSMenuItem, with row: MenuRow) {
    if item.isEnabled { item.isEnabled = false }
    if item.title != row.title || item.attributedTitle?.string != row.title {
      item.title = row.title
      item.attributedTitle = NSAttributedString(
        string: row.title,
        attributes: [
          .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0),
        ])
    }
    setSymbol(item, row.symbol, informational: true)
  }

  private func configureCommand(
    _ item: NSMenuItem, row: MenuRow, command: MenuCommand, enabled: Bool
  ) {
    setTitle(item, row.title)
    setSymbol(item, row.symbol, informational: false)
    item.target = self
    item.action = #selector(select(_:))
    item.representedObject = command.rawValue
    if item.isEnabled != enabled { item.isEnabled = enabled }
  }

  private func setTitle(_ item: NSMenuItem, _ title: String) {
    if item.title != title { item.title = title }
  }

  /// The image is replaced only when the symbol changes. Symbols are decorative: the title says it.
  private func setSymbol(_ item: NSMenuItem, _ symbol: String?, informational: Bool) {
    guard let item = item as? RowItem, item.symbol != symbol else { return }
    item.symbol = symbol
    var image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    if informational {
      image = image?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(hierarchicalColor: .secondaryLabelColor))
    }
    item.image = image
  }

  @objc private func select(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let command = MenuCommand(rawValue: raw)
    else { return }
    perform(command)
  }
}

/// A menu item that remembers which symbol its image shows.
private final class RowItem: NSMenuItem {
  var symbol: String?
}
