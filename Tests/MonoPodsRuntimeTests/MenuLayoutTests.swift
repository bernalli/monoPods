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
  status: String = "Observing", automation: Bool = true, launchAtLogin: Bool = true,
  login: String = LoginText.nextLogin, menuVisible: Bool = true,
  updates: UpdateMenuState = UpdateMenuState(available: true, canCheck: true),
  waiting: Bool = false
) -> MenuState {
  MenuState(
    presentation: MenuPresentation(
      snapshot: snapshot, automation: automation, routeName: route,
      routeModel: AirPodsModel.model(productID: 0x2014), status: status, loginCaption: login),
    automation: automation, launchAtLogin: launchAtLogin, loginCaption: login,
    menuVisible: menuVisible, versionLabel: "Version 1.0.1 (11)", updates: updates,
    waitingForUpdate: waiting)
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
    case .action(let candidate, _, _), .toggle(let candidate, _): return candidate == command
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

@Test func reportAnIssueIsASelectableItemNextToAbout() throws {
  let rows = MenuLayout.rows(for: layoutState())
  let about = try #require(index(of: .about, in: rows))
  let report = try #require(index(of: .reportIssue, in: rows))
  #expect(report == about + 1)
  #expect(rows[report].title == "Report an Issue\u{2026}")
  #expect(rows[report].kind == .action(.reportIssue, enabled: true, key: ""))
}

@Test func menuOpensWithTheNativeSectionHeaderAndEndsWithQuit() throws {
  let rows = MenuLayout.rows(for: layoutState())
  #expect(rows.first == MenuRow(id: "monopods", title: "MonoPods", symbol: nil, kind: .header))
  let last = try #require(rows.last)
  #expect(last.title == "Quit MonoPods")
  #expect(last.kind == .action(.quit, enabled: true, key: "q"))
}

@Test func summaryVersionAndDetailsAreInformationRows() throws {
  let state = layoutState()
  let rows = MenuLayout.rows(for: state)
  let summary = try #require(rows.first { $0.title == state.presentation.summary })
  #expect(summary.kind == .info)
  #expect(summary.symbol == state.presentation.symbol)
  #expect(rows.contains { $0.title == "Version 1.0.1 (11)" && $0.kind == .info })
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

@Test func detailsNameTheAccessibilitySettingForSystemMonoAudio() throws {
  var snapshot = layoutSnapshot()
  snapshot.audio = AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)
  let details = try #require(
    submenu(MenuLayout.rows(for: layoutState(snapshot: snapshot)), titled: "Details"))
  #expect(details.first?.title == "Accessibility Mono Audio: Off")
  #expect(!details.contains { $0.title.hasPrefix("System Mono Audio") })
}

@Test func longWarningsWrapIntoInformationRowsWithOneSymbol() {
  let rows = MenuLayout.rows(for: layoutState(login: LoginText.unsupervised))
  let warning = rows.filter { $0.id.hasPrefix("warning.") }
  #expect(warning.count >= 2)
  #expect(warning.allSatisfy { $0.kind == .info })
  #expect(warning.first?.symbol == "exclamationmark.triangle")
  #expect(warning.dropFirst().allSatisfy { $0.symbol == nil })
  #expect(warning.map(\.title).joined(separator: " ") == LoginText.unsupervised)
}

@Test func togglesShowTheCurrentSettings() throws {
  let rows = MenuLayout.rows(
    for: layoutState(automation: false, launchAtLogin: false, menuVisible: true))
  #expect(rows.contains { $0.kind == .toggle(.automation, isOn: false) })
  let options = try #require(submenu(rows, titled: "Options"))
  #expect(options.contains { $0.kind == .toggle(.launchAtLogin, isOn: false) })
  #expect(options.contains { $0.kind == .toggle(.hideMenuBarIcon, isOn: false) })
  #expect(options.contains { $0.title == LoginText.nextLogin && $0.kind == .info })
  let hidden = try #require(submenu(MenuLayout.rows(for: layoutState()), titled: "Options"))
  #expect(hidden.contains { $0.kind == .toggle(.launchAtLogin, isOn: true) })
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
}

@Test func rowIdentitiesAreUniqueAtEveryLevel() {
  func check(_ rows: [MenuRow]) {
    #expect(Set(rows.map(\.id)).count == rows.count)
    for row in rows {
      if case .submenu(let children) = row.kind { check(children) }
    }
  }
  check(MenuLayout.rows(for: layoutState(login: LoginText.unsupervised, waiting: true)))
}

extension [MenuRow] {
  fileprivate func contains(_ title: String) -> Bool { contains { $0.title == title } }
}
