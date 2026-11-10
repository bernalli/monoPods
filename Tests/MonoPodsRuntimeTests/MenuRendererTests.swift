import AppKit
import Testing

@testable import MonoPodsRuntime

private func row(_ id: String, _ title: String, _ kind: MenuRow.Kind, symbol: String? = nil)
  -> MenuRow
{
  MenuRow(id: id, title: title, symbol: symbol, kind: kind)
}

private func foreground(of item: NSMenuItem) -> NSColor? {
  guard let title = item.attributedTitle, title.length > 0 else { return nil }
  return title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
}

@MainActor @Test func headerRowBecomesTheNativeSectionHeader() throws {
  let menu = NSMenu()
  MenuRenderer { _ in }.apply([row("monopods", "MonoPods", .header)], to: menu)
  let item = try #require(menu.items.first)
  #expect(item.isSectionHeader)
  #expect(item.title == "MonoPods")
}

@MainActor @Test func informationRowsAreUnselectableTextInTheSecondaryLabelColor() throws {
  let menu = NSMenu()
  MenuRenderer { _ in }.apply(
    [row("summary.0", "One AirPod in Use", .info, symbol: "airpodspro")], to: menu)
  #expect(!menu.autoenablesItems)
  let item = try #require(menu.items.first)
  #expect(!item.isEnabled)
  #expect(item.action == nil)
  #expect(item.title == "One AirPod in Use")
  #expect(item.attributedTitle?.string == "One AirPod in Use")
  #expect(foreground(of: item) == NSColor.secondaryLabelColor)
  #expect(item.image != nil)
}

@MainActor @Test func selectableRowsKeepTheStandardLookAndRunTheirCommand() throws {
  var performed: [MenuCommand] = []
  let renderer = MenuRenderer { performed.append($0) }
  let menu = NSMenu()
  renderer.apply(
    [
      row(
        "automation", "Automatic Mono/Stereo", .toggle(.automation, isOn: true), symbol: "waveform"),
      row("check", "Check for Updates\u{2026}", .action(.checkForUpdates, enabled: false, key: "")),
      row("report", "Report an Issue\u{2026}", .action(.reportIssue, enabled: true, key: "")),
      row("quit", "Quit MonoPods", .action(.quit, enabled: true, key: "q")),
    ], to: menu)
  let toggle = menu.items[0]
  #expect(toggle.isEnabled)
  #expect(toggle.state == .on)
  #expect(toggle.attributedTitle == nil)
  #expect(!menu.items[1].isEnabled)
  #expect(menu.items[2].isEnabled)
  #expect(menu.items[3].keyEquivalent == "q")
  #expect(menu.items[3].keyEquivalentModifierMask == .command)
  menu.performActionForItem(at: 0)
  menu.performActionForItem(at: 2)
  menu.performActionForItem(at: 3)
  #expect(performed == [.automation, .reportIssue, .quit])
}

@MainActor @Test func newStateUpdatesTheItemsOfAnOpenMenuInPlace() throws {
  let renderer = MenuRenderer { _ in }
  let menu = NSMenu()
  func rows(count: Int, output: String, warning: Bool) -> [MenuRow] {
    var rows = [row("monopods", "MonoPods", .header)]
    if warning { rows.append(row("warning.0.0", "Waiting for ear detection.", .info)) }
    rows.append(row("automation", "Automatic Mono/Stereo", .toggle(.automation, isOn: count > 0)))
    rows.append(
      row(
        "details", "Details",
        .submenu([
          row("detail.0.0", "Audio Output: \(output)", .info),
          row("detail.1.0", "AirPods in Use: \(count)", .info),
        ])))
    return rows
  }
  renderer.apply(rows(count: 1, output: "AirPods Pro", warning: false), to: menu)
  let details = try #require(menu.items.first { $0.title == "Details" })
  let submenu = try #require(details.submenu)
  let output = submenu.items[0]
  let toggle = menu.items[1]

  renderer.apply(rows(count: 0, output: "Speakers", warning: true), to: menu)

  #expect(
    menu.items.map(\.title) == [
      "MonoPods", "Waiting for ear detection.", "Automatic Mono/Stereo", "Details",
    ])
  #expect(menu.items[3] === details)
  #expect(details.submenu === submenu)
  #expect(submenu.items[0] === output)
  #expect(output.title == "Audio Output: Speakers")
  #expect(output.attributedTitle?.string == "Audio Output: Speakers")
  #expect(submenu.items[1].title == "AirPods in Use: 0")
  #expect(menu.items[2] === toggle)
  #expect(toggle.state == .off)

  renderer.apply(rows(count: 2, output: "AirPods Pro", warning: false), to: menu)
  #expect(menu.items.map(\.title) == ["MonoPods", "Automatic Mono/Stereo", "Details"])
  #expect(menu.items[2] === details)
}

@MainActor @Test func aRowThatChangesKindGetsANewItem() throws {
  let renderer = MenuRenderer { _ in }
  let menu = NSMenu()
  renderer.apply([row("x", "Resume", .action(.resume, enabled: true, key: ""))], to: menu)
  let action = try #require(menu.items.first)
  renderer.apply([row("x", "Resume", .info)], to: menu)
  let info = try #require(menu.items.first)
  #expect(info !== action)
  #expect(!info.isEnabled)
  #expect(menu.items.count == 1)
}

@MainActor @Test func separatorRowsBecomeNativeSeparators() {
  let menu = NSMenu()
  MenuRenderer { _ in }.apply(
    [
      row("a", "About MonoPods", .action(.about, enabled: true, key: "")), row("s", "", .separator),
    ],
    to: menu)
  #expect(menu.items.count == 2)
  #expect(menu.items[1].isSeparatorItem)
}
