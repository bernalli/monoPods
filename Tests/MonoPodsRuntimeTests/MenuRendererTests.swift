import AppKit
import Testing

@testable import MonoPodsRuntime

private func row(_ id: String, _ title: String, _ kind: MenuRow.Kind, symbol: String? = nil)
  -> MenuRow
{
  MenuRow(id: id, title: title, symbol: symbol, kind: kind)
}

/// Metrics with distinct values, so each inset in a layout shows where it comes from.
private let testMetrics = MenuMetrics(
  rowHeight: 24, titleInset: 17, stateColumn: 13, imageColumn: 22.5, trailingInset: 20)

@MainActor private func infoView(of item: NSMenuItem) -> InfoRowView? {
  item.view as? InfoRowView
}

/// The constants of `MenuMetrics.fallback` are those of an open macOS 27 menu, and the renderer
/// draws information rows with its own view only where they hold.
private let runsOnMacOS27OrLater = InfoRowStyle.system == .secondaryView

@MainActor @Test func headerRowBecomesTheNativeSectionHeader() throws {
  let menu = NSMenu()
  MenuRenderer { _ in }.apply([row("monopods", "MonoPods", .header)], to: menu)
  let item = try #require(menu.items.first)
  #expect(item.isSectionHeader)
  #expect(item.title == "MonoPods")
}

@MainActor @Test func informationRowsAreUnselectableViewsWithSecondaryLabelText() throws {
  let menu = NSMenu()
  MenuRenderer(metrics: testMetrics, infoStyle: .secondaryView) { _ in }.apply(
    [row("summary.0", "One AirPod in Use", .info, symbol: "airpodspro")], to: menu)
  #expect(!menu.autoenablesItems)
  let item = try #require(menu.items.first)
  #expect(!item.isEnabled)
  #expect(item.action == nil)
  #expect(item.title == "One AirPod in Use")
  #expect(item.image == nil)
  let view = try #require(infoView(of: item))
  #expect(view.frame.height == testMetrics.rowHeight)
  #expect(view.autoresizingMask.contains(.width))
  #expect(view.label.stringValue == "One AirPod in Use")
  #expect(view.label.textColor == NSColor.secondaryLabelColor)
  #expect(view.label.font == NSFont.menuFont(ofSize: 0))
  #expect(!view.label.isEditable && !view.label.isSelectable)
  #expect(view.label.accessibilityRole() == .staticText)
  #expect(view.symbolView.image != nil)
  #expect(!view.symbolView.isHidden)
  #expect(view.symbolView.contentTintColor == NSColor.secondaryLabelColor)
  #expect(!view.symbolView.isAccessibilityElement())
}

@MainActor @Test func informationRowsWithoutSymbolShowOnlyText() throws {
  let menu = NSMenu()
  MenuRenderer(metrics: testMetrics, infoStyle: .secondaryView) { _ in }.apply(
    [row("version.0", "Version 1.0.1 (11)", .info)], to: menu)
  let item = try #require(menu.items.first)
  let view = try #require(infoView(of: item))
  #expect(view.symbolView.isHidden)
  #expect(view.label.stringValue == "Version 1.0.1 (11)")
}

@MainActor @Test func informationTextStartsInTheColumnOfStandardTitles() {
  let renderer = MenuRenderer(metrics: testMetrics) { _ in }
  let rows = [
    row("monopods", "MonoPods", .header),
    row("summary.0", "One AirPod in Use", .info, symbol: "airpodspro"),
    row("warning.0.1", "login.", .info),
    row(
      "login", "Launch at Login", .toggle(.launchAtLogin, isOn: true), symbol: "power"),
    row("separator", "", .separator),
    row("version.0", "Version 1.0.1 (11)", .info),
  ]
  let layouts = renderer.infoLayouts(for: rows)
  // A checked item adds the state column to the whole menu; a symbol adds the image column to
  // its group only.
  #expect(layouts[1] == InfoRowLayout(symbolInset: 30, textInset: 52.5))
  #expect(layouts[2] == InfoRowLayout(symbolInset: 30, textInset: 52.5))
  #expect(layouts[5] == InfoRowLayout(symbolInset: 30, textInset: 30))
  var unchecked = rows
  unchecked[3] = row("login", "Launch at Login", .toggle(.launchAtLogin, isOn: false))
  unchecked[1] = row("summary.0", "One AirPod in Use", .info)
  #expect(renderer.infoLayouts(for: unchecked)[1] == InfoRowLayout(symbolInset: 17, textInset: 17))
}

@MainActor
@Test(.enabled(if: runsOnMacOS27OrLater, "Earlier versions lay out menus differently"))
func informationRowsUseTheTitlePositionsOfAnOpenMacOS27Menu() {
  // In an open macOS 27 menu the title field of a standard item starts 14 pt from the menu's
  // edge, 28 pt with a state column, and 20 pt further in a group with images. The label of an
  // information row draws its text with the same cell padding, so its field starts there too.
  let metrics = MenuMetrics.system
  #expect(metrics.titleInset == 14)
  #expect(metrics.stateColumn == 14)
  #expect(metrics.imageColumn == 20)
  let renderer = MenuRenderer(metrics: metrics) { _ in }
  let main = [
    row("monopods", "MonoPods", .header),
    row("summary.0", "No AirPods Audio Output", .info, symbol: "airpodspro"),
    row("warning.0.1", "login.", .info),
    row("details", "Details", .submenu([]), symbol: "info.circle"),
    row("separator", "", .separator),
    row("version.0", "Version 1.0.1 (11)", .info),
    row("about", "About MonoPods", .action(.about, enabled: true, key: "")),
  ]
  let layouts = renderer.infoLayouts(for: main)
  #expect(layouts[1] == InfoRowLayout(symbolInset: 14, textInset: 34))
  #expect(layouts[2] == InfoRowLayout(symbolInset: 14, textInset: 34))
  #expect(layouts[5] == InfoRowLayout(symbolInset: 14, textInset: 14))
  let options = [
    row("login", "Launch at Login", .toggle(.launchAtLogin, isOn: true), symbol: "power"),
    row("login.caption.0", "Applies from the next login.", .info),
  ]
  #expect(renderer.infoLayouts(for: options)[1] == InfoRowLayout(symbolInset: 28, textInset: 48))
}

@MainActor @Test func informationViewIsWideEnoughForItsTextWhileTheMenuIsClosed() throws {
  let menu = NSMenu()
  let renderer = MenuRenderer(metrics: testMetrics, infoStyle: .secondaryView) { _ in }
  renderer.apply([row("detail.0.0", "Status: Observing", .info)], to: menu)
  let item = try #require(menu.items.first)
  let view = try #require(infoView(of: item))
  let narrow = view.frame.width
  #expect(narrow >= 17 + view.label.intrinsicContentSize.width + 20 - 1)
  renderer.apply(
    [row("detail.0.0", "Status: Waiting for verified stream transport", .info)], to: menu)
  #expect(view.frame.width > narrow)
  #expect(view.frame.height == testMetrics.rowHeight)
}

@MainActor @Test func informationTextIsNotTruncatedInAnOpenMenu() throws {
  // Details lines that macOS 27 cut off with an ellipsis.
  for text in ["Current Audio: Stereo (OSStatus 0)", "Automatic Ear Detection: Unknown"] {
    let menu = NSMenu()
    MenuRenderer(metrics: testMetrics, infoStyle: .secondaryView) { _ in }.apply(
      [row("detail.0.0", text, .info)], to: menu)
    let item = try #require(menu.items.first)
    let view = try #require(infoView(of: item))
    // An open menu places the view of its widest row at its left edge, at the view's own width.
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless],
      backing: .buffered, defer: true)
    window.contentView?.addSubview(view)
    view.setFrameOrigin(.zero)
    view.layoutSubtreeIfNeeded()
    let cell = try #require(view.label.cell)
    #expect(view.label.frame.width >= cell.cellSize.width, "\(text)")
    #expect(
      cell.expansionFrame(withFrame: view.label.bounds, in: view.label) == .zero, "\(text)")
  }
}

@MainActor @Test func measuredMetricsArePlausible() {
  let metrics = MenuMetrics.measure()
  #expect((16...40).contains(metrics.rowHeight))
  #expect((0...40).contains(metrics.stateColumn))
  #expect((4...60).contains(metrics.trailingInset))
  #expect(metrics.titleInset == MenuMetrics.fallback.titleInset)
  #expect(metrics.imageColumn == MenuMetrics.fallback.imageColumn)
}

@MainActor @Test func selectableRowsKeepTheStandardLookAndRunTheirCommand() throws {
  var performed: [MenuCommand] = []
  let renderer = MenuRenderer { performed.append($0) }
  let menu = NSMenu()
  renderer.apply(
    [
      row(
        "login", "Launch at Login", .toggle(.launchAtLogin, isOn: true), symbol: "power"),
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
  // Items hold their target weakly; the renderer must outlive the actions it receives.
  withExtendedLifetime(renderer) {
    menu.performActionForItem(at: 0)
    menu.performActionForItem(at: 2)
    menu.performActionForItem(at: 3)
  }
  #expect(performed == [.launchAtLogin, .reportIssue, .quit])
}

@MainActor @Test func newStateUpdatesTheItemsOfAnOpenMenuInPlace() throws {
  let renderer = MenuRenderer(infoStyle: .secondaryView) { _ in }
  let menu = NSMenu()
  func rows(count: Int, output: String, warning: Bool) -> [MenuRow] {
    var rows = [row("monopods", "MonoPods", .header)]
    if warning { rows.append(row("warning.0.0", "Waiting for ear detection.", .info)) }
    rows.append(row("login", "Launch at Login", .toggle(.launchAtLogin, isOn: count > 0)))
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
  let outputView = try #require(infoView(of: output))
  let toggle = menu.items[1]

  renderer.apply(rows(count: 0, output: "Speakers", warning: true), to: menu)

  #expect(
    menu.items.map(\.title) == [
      "MonoPods", "Waiting for ear detection.", "Launch at Login", "Details",
    ])
  #expect(menu.items[3] === details)
  #expect(details.submenu === submenu)
  #expect(submenu.items[0] === output)
  #expect(output.title == "Audio Output: Speakers")
  #expect(output.view === outputView)
  #expect(outputView.label.stringValue == "Audio Output: Speakers")
  #expect(infoView(of: submenu.items[1])?.label.stringValue == "AirPods in Use: 0")
  #expect(submenu.items[1].title == "AirPods in Use: 0")
  #expect(menu.items[2] === toggle)
  #expect(toggle.state == .off)

  renderer.apply(rows(count: 2, output: "AirPods Pro", warning: false), to: menu)
  #expect(menu.items.map(\.title) == ["MonoPods", "Launch at Login", "Details"])
  #expect(menu.items[2] === details)
}

@MainActor @Test(arguments: InfoRowStyle.allCases)
func aRowThatChangesKindGetsANewItem(style: InfoRowStyle) throws {
  var performed: [MenuCommand] = []
  let renderer = MenuRenderer(infoStyle: style) { performed.append($0) }
  let menu = NSMenu()
  renderer.apply([row("x", "Resume", .action(.resume, enabled: true, key: ""))], to: menu)
  let action = try #require(menu.items.first)
  renderer.apply([row("x", "Resume", .info)], to: menu)
  let info = try #require(menu.items.first)
  #expect(info !== action)
  #expect(!info.isEnabled)
  #expect(info.action == nil)
  #expect((info.view is InfoRowView) == (style == .secondaryView))
  #expect(menu.items.count == 1)

  renderer.apply([row("x", "Resume", .action(.resume, enabled: true, key: ""))], to: menu)
  let again = try #require(menu.items.first)
  #expect(again !== info)
  #expect(again.isEnabled)
  #expect(again.view == nil)
  withExtendedLifetime(renderer) { menu.performActionForItem(at: 0) }
  #expect(performed == [.resume])
}

@Test func informationRowStyleFollowsTheSystemVersion() {
  let macOS27 = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
  #expect(InfoRowStyle.system == (macOS27 ? .secondaryView : .disabledItem))
}

@MainActor @Test func informationRowsBeforeMacOS27AreDisabledNativeItems() throws {
  let menu = NSMenu()
  MenuRenderer(metrics: testMetrics, infoStyle: .disabledItem) { _ in }.apply(
    [
      row("summary.0", "One AirPod in Use", .info, symbol: "airpodspro"),
      row("version.0", "Version 1.0.1 (11)", .info),
    ], to: menu)
  #expect(!menu.autoenablesItems)
  let summary = menu.items[0]
  #expect(!summary.isEnabled)
  #expect(summary.action == nil)
  #expect(summary.view == nil)
  #expect(summary.title == "One AirPod in Use")
  #expect(summary.attributedTitle == nil)
  #expect(summary.image != nil)
  let version = menu.items[1]
  #expect(!version.isEnabled)
  #expect(version.view == nil)
  #expect(version.title == "Version 1.0.1 (11)")
  #expect(version.image == nil)
}

@MainActor @Test func nativeInformationRowsUpdateInPlaceInAnOpenMenu() throws {
  let renderer = MenuRenderer(infoStyle: .disabledItem) { _ in }
  let menu = NSMenu()
  func rows(summary: String, symbol: String?, output: String) -> [MenuRow] {
    [
      row("monopods", "MonoPods", .header),
      row("summary.0", summary, .info, symbol: symbol),
      row("details", "Details", .submenu([row("detail.0.0", "Audio Output: \(output)", .info)])),
    ]
  }
  let onePod = rows(summary: "One AirPod in Use", symbol: "airpodspro", output: "AirPods")
  renderer.apply(onePod, to: menu)
  let summary = menu.items[1]
  #expect(summary.image != nil)
  let submenu = try #require(menu.items[2].submenu)
  let output = submenu.items[0]

  renderer.apply(rows(summary: "Two AirPods in Use", symbol: nil, output: "Speakers"), to: menu)

  #expect(menu.items[1] === summary)
  #expect(summary.title == "Two AirPods in Use")
  #expect(summary.image == nil)
  #expect(!summary.isEnabled)
  #expect(summary.view == nil)
  #expect(menu.items[2].submenu === submenu)
  #expect(submenu.items[0] === output)
  #expect(output.title == "Audio Output: Speakers")
  #expect(!output.isEnabled)

  renderer.apply(onePod, to: menu)
  #expect(menu.items[1] === summary)
  #expect(summary.image != nil)
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

private final class RemovalRecordingMenu: NSMenu {
  var removedItems: [NSMenuItem] = []

  override func removeItem(_ item: NSMenuItem) {
    removedItems.append(item)
    super.removeItem(item)
  }

  override func removeItem(at index: Int) {
    if let item = item(at: index) { removedItems.append(item) }
    super.removeItem(at: index)
  }
}

@MainActor @Test(arguments: InfoRowStyle.allCases)
func stableRowsAreNeverDetachedWhenOtherRowsComeAndGo(style: InfoRowStyle) {
  let renderer = MenuRenderer(metrics: .fallback, infoStyle: style) { _ in }
  let candidates = [
    row("warning.0", "Warning A", .info),
    row("warning.1", "Warning B", .info),
    row("details", "Details", .submenu([])),
    row("options", "Options", .submenu([])),
  ]
  func rows(_ mask: Int) -> [MenuRow] {
    [row("monopods", "MonoPods", .header)]
      + candidates.indices.compactMap { index in
        mask & (1 << index) == 0 ? nil : candidates[index]
      }
  }

  for before in 0..<16 {
    for after in 0..<16 {
      let menu = RemovalRecordingMenu()
      renderer.apply(rows(before), to: menu)
      let next = rows(after)
      let titles = Set(next.map(\.title))
      let retained = menu.items.filter { titles.contains($0.title) }
      menu.removedItems.removeAll()

      renderer.apply(next, to: menu)

      #expect(menu.items.map(\.title) == next.map(\.title))
      #expect(
        retained.allSatisfy { item in
          menu.items.contains { $0 === item }
        })
      #expect(
        menu.removedItems.allSatisfy { removed in
          !retained.contains { $0 === removed }
        })
    }
  }
}

@Test func metricFallbacksRejectOutOfRangeAndNonFiniteMeasurements() {
  let cases: [(ClosedRange<CGFloat>, CGFloat)] = [
    (16...40, MenuMetrics.fallback.rowHeight),
    (0...40, MenuMetrics.fallback.stateColumn),
    (4...60, MenuMetrics.fallback.trailingInset),
  ]
  for (range, fallback) in cases {
    for value in [
      range.lowerBound - 1, range.upperBound + 1,
      CGFloat.nan, CGFloat.infinity, -CGFloat.infinity,
    ] {
      #expect(MenuMetrics.plausible(value, in: range, else: fallback) == fallback)
    }
    for value in [
      range.lowerBound,
      (range.lowerBound + range.upperBound) / 2,
      range.upperBound,
    ] {
      #expect(MenuMetrics.plausible(value, in: range, else: fallback) == value)
    }
  }
}
