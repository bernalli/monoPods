import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private func layoutSnapshot(count: Int? = 1) -> EngineSnapshot {
  var snapshot = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  snapshot.operational = true
  snapshot.healthy = true
  snapshot.detection = .on
  snapshot.count = count
  snapshot.lastCompleted = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  return snapshot
}

private func layoutState(
  snapshot: EngineSnapshot? = layoutSnapshot(), route: String = "AirPods Pro",
  status: String = "Observing", launchAtLogin: Bool = true, launchAtLoginEnabled: Bool = true,
  login: String = LoginText.nextLogin,
  updates: UpdateMenuState = UpdateMenuState(available: true, canCheck: true),
  waiting: Bool = false
) -> MenuState {
  MenuState(
    presentation: MenuPresentation(
      snapshot: snapshot, routeName: route, routeModel: AirPodsModel.model(productID: 0x2014),
      status: status, waitingForUpdate: waiting),
    launchAtLogin: launchAtLogin, launchAtLoginEnabled: launchAtLoginEnabled,
    loginCaption: login, updates: updates, waitingForUpdate: waiting)
}

private func submenu(_ rows: [MenuRow], titled title: String) -> [MenuRow]? {
  for row in rows {
    if row.title == title, case .submenu(let children) = row.kind { return children }
  }
  return nil
}

private func index(of command: MenuCommand, in rows: [MenuRow]) -> Int? {
  rows.firstIndex { row in
    switch row.kind {
    case .action(let candidate, _, _), .toggle(let candidate, _, _): return candidate == command
    default: return false
    }
  }
}

@Test func reportAnIssueOpensExactlyTheNewIssuePage() {
  #expect(ProjectLinks.newIssue.absoluteString == "https://github.com/bernalli/monoPods/issues/new")
  #expect(MenuCommand.reportIssue.link == ProjectLinks.newIssue)
  for command in MenuCommand.allCases where command != .reportIssue {
    #expect(command.link == nil)
  }
}

@Test func aboutCheckAndReportComeInTheApprovedOrder() throws {
  let rows = MenuLayout.rows(for: layoutState())
  let about = try #require(index(of: .about, in: rows))
  #expect(index(of: .checkForUpdates, in: rows) == about + 1)
  #expect(index(of: .reportIssue, in: rows) == about + 2)
  #expect(rows[about + 2].title == "Report an Issue\u{2026}")
  #expect(rows[about + 2].kind == .action(.reportIssue, enabled: true, key: ""))
  let without = MenuLayout.rows(
    for: layoutState(updates: UpdateMenuState(available: false, canCheck: false)))
  let aboutOnly = try #require(index(of: .about, in: without))
  #expect(index(of: .reportIssue, in: without) == aboutOnly + 1)
}

@Test func menuOpensWithTheNativeSectionHeaderAndEndsWithQuit() throws {
  let rows = MenuLayout.rows(for: layoutState())
  #expect(rows.first == MenuRow(id: "monopods", title: "MonoPods", symbol: nil, kind: .header))
  let last = try #require(rows.last)
  #expect(last.title == "Quit MonoPods")
  #expect(last.kind == .action(.quit, enabled: true, key: "q"))
}

@Test func summaryAndDetailsAreInformationRowsAndNoVersionRow() throws {
  let state = layoutState()
  let rows = MenuLayout.rows(for: state)
  let summary = try #require(rows.first { $0.title == state.presentation.summary })
  #expect(summary.kind == .info)
  #expect(summary.symbol == state.presentation.symbol)
  #expect(!rows.contains { $0.id.hasPrefix("version") || $0.title.hasPrefix("Version") })
  let details = try #require(submenu(rows, titled: "Details"))
  #expect(!details.isEmpty)
  #expect(details.allSatisfy { $0.kind == .info })
  #expect(details.map(\.title) == state.presentation.details.flatMap { MenuText.lines($0) })
}

@Test func detailsFollowTheStateWithTheSameRowIdentities() throws {
  let before = try #require(submenu(MenuLayout.rows(for: layoutState()), titled: "Details"))
  let after = try #require(
    submenu(
      MenuLayout.rows(for: layoutState(snapshot: layoutSnapshot(count: 2), route: "Speakers")),
      titled: "Details"))
  #expect(before.map(\.id) == after.map(\.id))
  #expect(before.contains("AirPods in Use: 1"))
  #expect(after.contains("AirPods in Use: 2"))
  #expect(before.contains("Audio Output: AirPods Pro"))
  #expect(after.contains("Audio Output: Speakers"))
}

@Test func detailsNameMonoAudioOnce() throws {
  var snapshot = layoutSnapshot()
  snapshot.audio = AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)
  let details = try #require(
    submenu(MenuLayout.rows(for: layoutState(snapshot: snapshot)), titled: "Details"))
  #expect(details.first?.title == "Audio Output: AirPods Pro")
  #expect(details.contains("Mono Audio: Off"))
  #expect(!details.contains { $0.title.hasPrefix("Accessibility Mono Audio") })
  #expect(!details.contains { $0.title.hasPrefix("System Mono Audio") })
}

@Test func aLongReasonWrapsWithoutASymbol() {
  var snapshot = layoutSnapshot()
  snapshot.blocked = true
  let rows = MenuLayout.rows(for: layoutState(snapshot: snapshot))
  let reason = rows.filter { $0.id.hasPrefix("reason.") }
  #expect(reason.count >= 2)
  #expect(reason.allSatisfy { $0.kind == .info })
  #expect(reason.allSatisfy { $0.symbol == nil })
  #expect(reason.map(\.title).joined(separator: " ") == MenuSituation.blocked.reason)
}

@Test func automaticSwitchingHasNoMenuItemToTurnItOff() {
  // Automatic switching runs while the app runs; Quit is the way to stop it.
  let rows = MenuLayout.rows(for: layoutState())
  #expect(!rows.contains { $0.title == "Automatic Mono/Stereo" })
  #expect(!rows.contains { $0.id == "automation" })
  let hasToggle = rows.contains { row in
    if case .toggle = row.kind { return true }
    return false
  }
  #expect(!hasToggle)
  #expect(MenuCommand(rawValue: "automation") == nil)
  #expect(rows.last?.kind == .action(.quit, enabled: true, key: "q"))
}

@Test func togglesShowTheCurrentSettings() throws {
  let rows = MenuLayout.rows(for: layoutState(launchAtLogin: false))
  let options = try #require(submenu(rows, titled: "Options"))
  #expect(options.contains { $0.kind == .toggle(.launchAtLogin, isOn: false, enabled: true) })
  #expect(options.contains { $0.kind == .action(.hideMenuBarIcon, enabled: true, key: "") })
  #expect(!options.contains { $0.title == LoginText.nextLogin })
  #expect(!options.contains { $0.id.hasPrefix("login.caption.") })
  let checked = try #require(submenu(MenuLayout.rows(for: layoutState()), titled: "Options"))
  #expect(checked.contains { $0.kind == .toggle(.launchAtLogin, isOn: true, enabled: true) })
}

@Test func launchAtLoginIsDimmedWhenThisProcessCannotApplyIt() throws {
  for isOn in [false, true] {
    let options = try #require(
      submenu(
        MenuLayout.rows(for: layoutState(launchAtLogin: isOn, launchAtLoginEnabled: false)),
        titled: "Options"))
    let login = try #require(options.first { $0.id == "login" })
    #expect(login.kind == .toggle(.launchAtLogin, isOn: isOn, enabled: false))
  }
}

@Test func loginProblemsStayInOptions() throws {
  for caption in [LoginText.failed, LoginText.notInstalled, LoginText.unsupervised] {
    let rows = MenuLayout.rows(for: layoutState(login: caption))
    #expect(!rows.contains { $0.id.hasPrefix("login") }, "\(caption)")
    #expect(!rows.contains { $0.id.hasPrefix("reason.") }, "\(caption)")
    let options = try #require(submenu(rows, titled: "Options"))
    let lines = options.filter { $0.id.hasPrefix("login.caption.") }
    #expect(lines.map(\.title).joined(separator: " ") == caption)
    #expect(lines.allSatisfy { $0.kind == .info && $0.symbol == nil })
  }
}

@Test func aSeparatorComesBeforeOptions() throws {
  let rows = MenuLayout.rows(for: layoutState())
  let options = try #require(rows.firstIndex { $0.id == "options" })
  #expect(
    rows[options - 1] == MenuRow(id: "separator.options", title: "", symbol: nil, kind: .separator))
  #expect(rows[options - 2].id == "details")
}

@Test func updateItemsFollowTheUpdaterState() throws {
  let none = MenuLayout.rows(
    for: layoutState(updates: UpdateMenuState(available: false, canCheck: false)))
  #expect(index(of: .checkForUpdates, in: none) == nil)
  #expect(index(of: .resume, in: none) == nil)
  let busy = MenuLayout.rows(
    for: layoutState(updates: UpdateMenuState(available: true, canCheck: false)))
  let check = try #require(index(of: .checkForUpdates, in: busy))
  #expect(busy[check].kind == .action(.checkForUpdates, enabled: false, key: ""))
  #expect(busy[check].title == UpdateText.check)
  let waiting = MenuLayout.rows(for: layoutState(waiting: true))
  let resume = try #require(index(of: .resume, in: waiting))
  #expect(waiting[resume].title == UpdateText.resume)
  let summary = try #require(
    waiting.lastIndex { $0.id.hasPrefix("summary.") || $0.id.hasPrefix("reason.") })
  #expect(resume == summary + 1)
}

@Test func theUpdateChecksSwitchComesAfterLoginAndBeforeTheSeparator() throws {
  for caption in [LoginText.nextLogin, LoginText.failed] {
    for automaticChecks in [false, true] {
      let updates = UpdateMenuState(
        available: true, canCheck: true, automaticChecks: automaticChecks)
      let options = try #require(
        submenu(
          MenuLayout.rows(for: layoutState(login: caption, updates: updates)), titled: "Options"))
      let row = try #require(options.firstIndex { $0.id == "automatic" })
      #expect(
        options[row]
          == MenuRow(
            id: "automatic", title: MenuTitle.automaticUpdates,
            symbol: "arrow.triangle.2.circlepath",
            kind: .toggle(.automaticUpdates, isOn: automaticChecks, enabled: true)))
      let previous = options[row - 1].id
      let lastCaption = options.lastIndex { $0.id.hasPrefix("login.caption.") }
      if let lastCaption {
        #expect(row - 1 == lastCaption)
      } else {
        #expect(previous == "login")
      }
      #expect(options[row + 1].id == "options.separator")
    }
  }
}

@Test func theUpdateChecksSwitchIsNamedLikeTheOtherApp() {
  #expect(MenuTitle.automaticUpdates == "Check for Updates Automatically")
}

@Test func automaticUpdatesIsMissingWithoutTheUpdater() throws {
  let rows = MenuLayout.rows(
    for: layoutState(updates: UpdateMenuState(available: false, canCheck: false)))
  let options = try #require(submenu(rows, titled: "Options"))
  #expect(!options.contains { $0.id == "automatic" })
  #expect(index(of: .automaticUpdates, in: options) == nil)
  #expect(MenuCommand.automaticUpdates.link == nil)
}

@Test func rowIdentitiesAreUniqueAtEveryLevel() {
  func check(_ rows: [MenuRow]) {
    #expect(Set(rows.map(\.id)).count == rows.count)
    for row in rows {
      if case .submenu(let children) = row.kind { check(children) }
    }
  }
  var blocked = layoutSnapshot()
  blocked.blocked = true
  check(
    MenuLayout.rows(
      for: layoutState(snapshot: blocked, login: LoginText.unsupervised, waiting: true)))
}

extension [MenuRow] {
  fileprivate func contains(_ title: String) -> Bool { contains { $0.title == title } }
}
