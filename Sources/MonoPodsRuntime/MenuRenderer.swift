import AppKit

/// Turns menu rows into native menu items and keeps them current.
///
/// Every update reuses the item that already shows a row with the same `id` and kind and only
/// changes its title, state, symbol or the text of its view. AppKit redraws such changes while the
/// menu is open, and an open submenu stays open because its item and its `NSMenu` are the same
/// objects.
@MainActor public final class MenuRenderer: NSObject {
  private let perform: (MenuCommand) -> Void
  private let metrics: MenuMetrics

  public init(metrics: MenuMetrics = .system, perform: @escaping (MenuCommand) -> Void) {
    self.metrics = metrics
    self.perform = perform
  }

  public func apply(_ rows: [MenuRow], to menu: NSMenu) {
    // Information rows are disabled on purpose; validation must not enable them again.
    menu.autoenablesItems = false
    let wanted = Set(rows.map { Self.key(of: $0) })
    var existing: [String: NSMenuItem] = [:]

    for item in menu.items {
      guard let key = item.identifier?.rawValue, wanted.contains(key) else {
        menu.removeItem(item)
        continue
      }
      existing[key] = item
    }

    let layouts = infoLayouts(for: rows)
    for (index, row) in rows.enumerated() {
      let key = Self.key(of: row)
      let item = existing.removeValue(forKey: key) ?? make(row, key: key)
      configure(item, with: row, layout: layouts[index])
      if index < menu.numberOfItems, menu.item(at: index) === item { continue }
      if item.menu === menu { menu.removeItem(item) }
      menu.insertItem(item, at: index)
    }
    // Every position up to rows.count now holds its row; what follows is no longer shown.
    while menu.numberOfItems > rows.count {
      menu.removeItem(at: rows.count)
    }
  }

  /// Where standard titles start in this menu, as AppKit draws them on macOS 27. The state column
  /// belongs to the whole menu and appears when an item is checked. The image column belongs to
  /// the group of items between two separators. Section headers keep their own position.
  func infoLayouts(for rows: [MenuRow]) -> [InfoRowLayout] {
    let showsState = rows.contains { row in
      if case .toggle(_, let isOn) = row.kind { return isOn }
      return false
    }
    let base = metrics.titleInset + (showsState ? metrics.stateColumn : 0)
    var layouts = Array(
      repeating: InfoRowLayout(symbolInset: base, textInset: base), count: rows.count)
    var start = 0
    for end in rows.indices + [rows.count] where end == rows.count || rows[end].kind == .separator {
      let group = start..<end
      let hasImage = group.contains { rows[$0].kind != .header && rows[$0].symbol != nil }
      if hasImage {
        for index in group {
          layouts[index] = InfoRowLayout(symbolInset: base, textInset: base + metrics.imageColumn)
        }
      }
      start = end + 1
    }
    return layouts
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

  private func configure(_ item: NSMenuItem, with row: MenuRow, layout: InfoRowLayout) {
    switch row.kind {
    case .header:
      setTitle(item, row.title)
    case .separator:
      break
    case .info:
      configureInfo(item, with: row, layout: layout)
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
      setSymbol(item, row.symbol)
      if item.submenu == nil { item.submenu = NSMenu(title: row.title) }
      if let submenu = item.submenu { apply(children, to: submenu) }
    }
  }

  /// AppKit dims the title and image of a disabled item, whatever their color. The row is
  /// therefore drawn by its own view, which AppKit does not dim, and the item stays disabled: it
  /// cannot be chosen and is not highlighted. The view is kept and only its text changes.
  private func configureInfo(_ item: NSMenuItem, with row: MenuRow, layout: InfoRowLayout) {
    if item.isEnabled { item.isEnabled = false }
    // The item's own title still serves type-select; the view draws the visible text.
    setTitle(item, row.title)
    let view: InfoRowView
    if let existing = item.view as? InfoRowView {
      view = existing
    } else {
      view = InfoRowView(height: metrics.rowHeight)
      item.view = view
    }
    view.update(
      text: row.title, symbol: row.symbol, layout: layout, trailingInset: metrics.trailingInset)
  }

  private func configureCommand(
    _ item: NSMenuItem, row: MenuRow, command: MenuCommand, enabled: Bool
  ) {
    setTitle(item, row.title)
    setSymbol(item, row.symbol)
    item.target = self
    item.action = #selector(select(_:))
    item.representedObject = command.rawValue
    if item.isEnabled != enabled { item.isEnabled = enabled }
  }

  private func setTitle(_ item: NSMenuItem, _ title: String) {
    if item.title != title { item.title = title }
  }

  /// The image is replaced only when the symbol changes. Symbols are decorative: the title says it.
  private func setSymbol(_ item: NSMenuItem, _ symbol: String?) {
    guard let item = item as? RowItem, item.symbol != symbol else { return }
    item.symbol = symbol
    item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
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
