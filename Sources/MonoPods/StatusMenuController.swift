import AppKit
import Combine
import MonoPodsRuntime

/// The menu bar item and its native menu.
///
/// The menu is an AppKit `NSMenu` so that information rows can use the secondary label color on
/// macOS 27 (see `InfoRowStyle`) and the open menu can change as the runtime changes. Every change
/// of the host or of the updater schedules one refresh in the common run loop modes, which include
/// menu tracking, so the values in an open menu and in an open Details submenu follow the state.
@MainActor final class StatusMenuController: NSObject, NSMenuDelegate {
  private let host: RuntimeHost
  private let updates: UpdateController
  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private var renderer: MenuRenderer?
  private let information = AppInformation(infoDictionary: Bundle.main.infoDictionary)
  private let about = AboutWindowController(
    information: AppInformation(infoDictionary: Bundle.main.infoDictionary),
    icon: NSImage(named: "AppIcon"),
    gitHubMark: AboutArtwork.templateImage(
      contentsOf: Bundle.main.url(forResource: "GitHubMark", withExtension: "pdf")),
    open: { _ = NSWorkspace.shared.open($0) },
    activate: { NSApplication.shared.activate(ignoringOtherApps: true) })
  private var subscriptions: Set<AnyCancellable> = []
  private var visibility: NSKeyValueObservation?
  private var refreshScheduled = false

  init(host: RuntimeHost, updates: UpdateController) {
    self.host = host
    self.updates = updates
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    renderer = MenuRenderer { [weak self] command in self?.perform(command) }
    // The user may Command-drag the item out of the menu bar, as with the SwiftUI menu bar extra.
    statusItem.behavior = .removalAllowed
    statusItem.button?.setAccessibilityTitle(MenuTitle.header)
    menu.delegate = self
    statusItem.menu = menu
    refresh()
    // A removal by the user is written back like the Hide Menu Bar Icon setting.
    visibility = statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, change in
      guard let visible = change.newValue else { return }
      MainActor.assumeIsolated {
        guard let self, visible != self.host.menuVisible else { return }
        self.host.requestMenuVisible(visible)
      }
    }
    // Both objects publish on the main actor.
    host.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleRefresh() }
    }.store(in: &subscriptions)
    updates.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleRefresh() }
    }.store(in: &subscriptions)
  }

  /// `objectWillChange` fires before the new value is stored, so the refresh runs on the next
  /// turn of the run loop. Several changes in one turn give one refresh.
  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated { self?.refresh() }
    }
    // A scheduled block does not wake a sleeping run loop by itself.
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }

  private func refresh() {
    refreshScheduled = false
    renderer?.apply(MenuLayout.rows(for: state), to: menu)
    let image = MenuBarIcons.image(for: host.glyph, waveFrame: host.waveFrame)
    if statusItem.button?.image !== image { statusItem.button?.image = image }
    if statusItem.isVisible != host.menuVisible { statusItem.isVisible = host.menuVisible }
  }

  private var state: MenuState {
    MenuState(
      presentation: MenuPresentation(
        snapshot: host.snapshot, routeName: host.routeName, routeModel: host.routeModel,
        status: host.status, loginCaption: host.loginCaption),
      launchAtLogin: host.launchAtLogin, loginCaption: host.loginCaption,
      menuVisible: host.menuVisible,
      versionLabel: information.versionLabel, updates: updates.state,
      waitingForUpdate: host.waitingForUpdate)
  }

  /// The handoff flag is not published; opening the menu reads it again.
  func menuNeedsUpdate(_ menu: NSMenu) {
    refresh()
  }

  private func perform(_ command: MenuCommand) {
    if let link = command.link {
      NSWorkspace.shared.open(link)
      return
    }
    switch command {
    case .launchAtLogin: host.setLaunchAtLogin(!host.launchAtLogin)
    case .hideMenuBarIcon: host.setMenuVisible(!host.menuVisible)
    case .checkForUpdates: updates.checkForUpdates()
    case .about: about.show()
    case .resume: confirmResume()
    case .quit: host.quit()
    case .reportIssue: break
    }
  }

  /// An explicit confirmation is the only way out of a handoff without a new build.
  private func confirmResume() {
    let alert = NSAlert()
    alert.messageText = UpdateText.resumeTitle
    alert.informativeText = UpdateText.resumeText
    alert.addButton(withTitle: UpdateText.resumeConfirm)
    alert.addButton(withTitle: UpdateText.cancel)
    NSApplication.shared.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if !host.resumeWithoutUpdate() { NSSound.beep() }
  }
}
