import Foundation

/// What a selectable menu item does. The app target maps each command to the runtime.
public enum MenuCommand: String, CaseIterable, Sendable {
  case automation
  case launchAtLogin
  case hideMenuBarIcon
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
    case toggle(MenuCommand, isOn: Bool)
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
  public var automation: Bool
  public var launchAtLogin: Bool
  public var loginCaption: String
  public var menuVisible: Bool
  public var versionLabel: String
  public var updates: UpdateMenuState
  public var waitingForUpdate: Bool

  public init(
    presentation: MenuPresentation, automation: Bool, launchAtLogin: Bool, loginCaption: String,
    menuVisible: Bool, versionLabel: String, updates: UpdateMenuState, waitingForUpdate: Bool
  ) {
    self.presentation = presentation
    self.automation = automation
    self.launchAtLogin = launchAtLogin
    self.loginCaption = loginCaption
    self.menuVisible = menuVisible
    self.versionLabel = versionLabel
    self.updates = updates
    self.waitingForUpdate = waitingForUpdate
  }
}

/// Fixed titles of the menu items.
public enum MenuTitle {
  public static let header = "MonoPods"
  public static let automation = "Automatic Mono/Stereo"
  public static let details = "Details"
  public static let options = "Options"
  public static let launchAtLogin = "Launch at Login"
  public static let hideIcon = "Hide Menu Bar Icon"
  public static let hideIconCaption = "Open MonoPods again to bring it back."
  public static let about = "About MonoPods"
  public static let reportIssue = "Report an Issue\u{2026}"
  public static let quit = "Quit MonoPods"
}

/// The menu as a list of rows, without AppKit, so its content can be tested.
public enum MenuLayout {
  private static let warningSymbol = "exclamationmark.triangle"

  public static func rows(for state: MenuState) -> [MenuRow] {
    let menu = state.presentation
    var rows: [MenuRow] = [
      MenuRow(id: "monopods", title: MenuTitle.header, symbol: nil, kind: .header)
    ]
    rows += info(menu.summary, id: "summary", symbol: menu.symbol)
    for (index, warning) in menu.warnings.enumerated() {
      rows += info(warning, id: "warning.\(index)", symbol: warningSymbol)
    }
    rows.append(
      MenuRow(
        id: "automation", title: MenuTitle.automation, symbol: "waveform",
        kind: .toggle(.automation, isOn: state.automation)))
    let details = menu.details.enumerated().flatMap { index, detail in
      info(detail, id: "detail.\(index)")
    }
    rows.append(
      MenuRow(
        id: "details", title: MenuTitle.details, symbol: "info.circle", kind: .submenu(details)))
    var options: [MenuRow] = []
    options.append(
      MenuRow(
        id: "login", title: MenuTitle.launchAtLogin, symbol: "power",
        kind: .toggle(.launchAtLogin, isOn: state.launchAtLogin)))
    options += info(state.loginCaption, id: "login.caption")
    options.append(MenuRow(id: "options.separator", title: "", symbol: nil, kind: .separator))
    options.append(
      MenuRow(
        id: "hide", title: MenuTitle.hideIcon, symbol: "menubar.rectangle",
        kind: .toggle(.hideMenuBarIcon, isOn: !state.menuVisible)))
    options += info(MenuTitle.hideIconCaption, id: "hide.caption")
    rows.append(
      MenuRow(id: "options", title: MenuTitle.options, symbol: "gearshape", kind: .submenu(options))
    )
    rows.append(MenuRow(id: "separator.app", title: "", symbol: nil, kind: .separator))
    rows += info(state.versionLabel, id: "version")
    if state.updates.showsItems {
      rows.append(
        MenuRow(
          id: "check", title: UpdateText.check, symbol: nil,
          kind: .action(.checkForUpdates, enabled: state.updates.checkEnabled, key: "")))
    }
    rows.append(
      MenuRow(
        id: "about", title: MenuTitle.about, symbol: nil,
        kind: .action(.about, enabled: true, key: "")))
    rows.append(
      MenuRow(
        id: "report", title: MenuTitle.reportIssue, symbol: nil,
        kind: .action(.reportIssue, enabled: true, key: "")))
    if state.waitingForUpdate {
      rows.append(
        MenuRow(
          id: "resume", title: UpdateText.resume, symbol: nil,
          kind: .action(.resume, enabled: true, key: "")))
    }
    rows.append(MenuRow(id: "separator.quit", title: "", symbol: nil, kind: .separator))
    rows.append(
      MenuRow(
        id: "quit", title: MenuTitle.quit, symbol: nil,
        kind: .action(.quit, enabled: true, key: "q")))
    return rows
  }

  /// Free text as information rows of at most `MenuText.width` characters; only the first line
  /// carries the symbol. Blank text gives no rows.
  private static func info(_ text: String, id: String, symbol: String? = nil) -> [MenuRow] {
    MenuText.lines(text).enumerated().map { line, title in
      MenuRow(id: "\(id).\(line)", title: title, symbol: line == 0 ? symbol : nil, kind: .info)
    }
  }
}
