import Foundation

/// What a selectable menu item does. The app target maps each command to the runtime.
public enum MenuCommand: String, CaseIterable, Sendable {
  case launchAtLogin
  case hideMenuBarIcon
  case automaticUpdates
  case checkForUpdates
  case about
  case reportIssue
  case resume
  case quit

  /// The web page a command opens; only Report an Issue opens one. Nothing is sent with it.
  public var link: URL? {
    self == .reportIssue ? ProjectLinks.newIssue : nil
  }
}

/// One native menu item. `id` is stable while the state changes, so an open menu keeps the same
/// item and only its title or state is updated.
public struct MenuRow: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// The native section title that names the group below it.
    case header
    /// Read-only text: not selectable and not highlighted under the pointer.
    case info
    case toggle(MenuCommand, isOn: Bool, enabled: Bool)
    case action(MenuCommand, enabled: Bool, key: String)
    case submenu([MenuRow])
    case separator
  }

  public let id: String
  public let title: String
  public let symbol: String?
  public let kind: Kind

  public init(id: String, title: String, symbol: String?, kind: Kind) {
    self.id = id
    self.title = title
    self.symbol = symbol
    self.kind = kind
  }
}

/// Everything the menu shows, read from the runtime at one moment.
public struct MenuState: Equatable, Sendable {
  public var presentation: MenuPresentation
  public var launchAtLogin: Bool
  /// False while this process cannot apply the choice; the item is then dimmed.
  public var launchAtLoginEnabled: Bool
  public var loginCaption: String
  public var updates: UpdateMenuState
  public var waitingForUpdate: Bool

  public init(
    presentation: MenuPresentation, launchAtLogin: Bool, launchAtLoginEnabled: Bool,
    loginCaption: String, updates: UpdateMenuState, waitingForUpdate: Bool
  ) {
    self.presentation = presentation
    self.launchAtLogin = launchAtLogin
    self.launchAtLoginEnabled = launchAtLoginEnabled
    self.loginCaption = loginCaption
    self.updates = updates
    self.waitingForUpdate = waitingForUpdate
  }
}

/// Fixed titles of the menu items.
public enum MenuTitle {
  public static let header = "MonoPods"
  public static var details: String { Localized.text("Details") }
  public static var options: String { Localized.text("Options") }
  public static var launchAtLogin: String { Localized.text("Launch at Login") }
  public static var automaticUpdates: String { Localized.text("Automatic Updates") }
  public static var hideIcon: String { Localized.text("Hide Menu Bar Icon") }
  public static var hideIconCaption: String {
    Localized.format("Open %@ again to bring it back.", "MonoPods")
  }
  public static var about: String { Localized.format("About %@", "MonoPods") }
  public static var reportIssue: String { Localized.text("Report an Issue\u{2026}") }
  public static var quit: String { Localized.format("Quit %@", "MonoPods") }
}

/// The menu as a list of rows, without AppKit, so its content can be tested.
public enum MenuLayout {
  public static func rows(for state: MenuState) -> [MenuRow] {
    let menu = state.presentation
    var rows: [MenuRow] = [
      MenuRow(id: "monopods", title: MenuTitle.header, symbol: nil, kind: .header)
    ]
    rows += info(menu.summary, id: "summary", symbol: menu.symbol)
    if let reason = menu.reason { rows += info(reason, id: "reason") }
    if state.waitingForUpdate {
      rows.append(
        MenuRow(
          id: "resume", title: UpdateText.resume, symbol: nil,
          kind: .action(.resume, enabled: true, key: "")))
    }
    let details = menu.details.enumerated().flatMap { index, detail in
      info(detail, id: "detail.\(index)")
    }
    rows.append(
      MenuRow(
        id: "details", title: MenuTitle.details, symbol: "info.circle", kind: .submenu(details)))
    rows.append(MenuRow(id: "separator.options", title: "", symbol: nil, kind: .separator))
    rows.append(
      MenuRow(
        id: "options", title: MenuTitle.options, symbol: "gearshape",
        kind: .submenu(options(for: state))))
    rows.append(MenuRow(id: "separator.app", title: "", symbol: nil, kind: .separator))
    rows.append(
      MenuRow(
        id: "about", title: MenuTitle.about, symbol: nil,
        kind: .action(.about, enabled: true, key: "")))
    if state.updates.showsItems {
      rows.append(
        MenuRow(
          id: "check", title: UpdateText.check, symbol: nil,
          kind: .action(.checkForUpdates, enabled: state.updates.checkEnabled, key: "")))
    }
    rows.append(
      MenuRow(
        id: "report", title: MenuTitle.reportIssue, symbol: nil,
        kind: .action(.reportIssue, enabled: true, key: "")))
    rows.append(MenuRow(id: "separator.quit", title: "", symbol: nil, kind: .separator))
    rows.append(
      MenuRow(
        id: "quit", title: MenuTitle.quit, symbol: nil,
        kind: .action(.quit, enabled: true, key: "q")))
    return rows
  }

  /// Launch at Login with its caption only on a problem, the update checks switch, the icon.
  private static func options(for state: MenuState) -> [MenuRow] {
    let login = MenuRow(
      id: "login", title: MenuTitle.launchAtLogin, symbol: "power",
      kind: .toggle(
        .launchAtLogin, isOn: state.launchAtLogin, enabled: state.launchAtLoginEnabled))
    var options = [login]
    if state.loginCaption != LoginText.nextLogin {
      options += info(Localized.text(state.loginCaption), id: "login.caption")
    }
    if state.updates.showsItems {
      options.append(
        MenuRow(
          id: "automatic", title: MenuTitle.automaticUpdates,
          symbol: "arrow.triangle.2.circlepath",
          kind: .toggle(.automaticUpdates, isOn: state.updates.automaticChecks, enabled: true)))
    }
    options.append(MenuRow(id: "options.separator", title: "", symbol: nil, kind: .separator))
    options.append(
      MenuRow(
        id: "hide", title: MenuTitle.hideIcon, symbol: "menubar.rectangle",
        kind: .action(.hideMenuBarIcon, enabled: true, key: "")))
    options += info(MenuTitle.hideIconCaption, id: "hide.caption")
    return options
  }

  /// Free text as information rows of at most `MenuText.width` characters; only the first line
  /// carries the symbol. Blank text gives no rows.
  private static func info(_ text: String, id: String, symbol: String? = nil) -> [MenuRow] {
    MenuText.lines(text).enumerated().map { line, title in
      MenuRow(id: "\(id).\(line)", title: title, symbol: line == 0 ? symbol : nil, kind: .info)
    }
  }
}
