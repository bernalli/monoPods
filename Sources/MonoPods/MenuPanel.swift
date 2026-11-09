import AppKit
import MonoPodsRuntime
import SwiftUI

/// Native menu items keep the macOS selection, keyboard navigation and submenu behavior.
struct MenuPanel: View {
  @ObservedObject var host: RuntimeHost
  @ObservedObject var updates: UpdateController
  private let information = AppInformation(infoDictionary: Bundle.main.infoDictionary)
  /// One About window for the app's lifetime; the menu view itself is recreated freely.
  @MainActor private static let about = AboutWindowController(
    information: AppInformation(infoDictionary: Bundle.main.infoDictionary),
    icon: NSImage(named: "AppIcon"),
    gitHubMark: AboutArtwork.templateImage(
      contentsOf: Bundle.main.url(forResource: "GitHubMark", withExtension: "pdf")),
    open: { _ = NSWorkspace.shared.open($0) },
    activate: { NSApplication.shared.activate(ignoringOtherApps: true) })

  private var presentation: MenuPresentation {
    MenuPresentation(
      snapshot: host.snapshot, automation: host.automation, routeName: host.routeName,
      routeModel: host.routeModel, status: host.status, loginCaption: host.loginCaption)
  }

  var body: some View {
    let menu = presentation
    Section("MonoPods") {
      Label(menu.summary, systemImage: menu.symbol)
      ForEach(Array(menu.warnings.enumerated()), id: \.offset) { _, warning in
        info(warning, symbol: "exclamationmark.triangle")
      }
      Toggle(
        isOn: Binding(get: { host.automation }, set: { host.setAutomation($0) })
      ) {
        Label("Automatic Mono/Stereo", systemImage: "waveform")
      }
    }
    Menu {
      ForEach(Array(menu.details.enumerated()), id: \.offset) { _, detail in
        info(detail)
      }
    } label: {
      Label("Details", systemImage: "info.circle")
    }
    Menu {
      Toggle(
        isOn: Binding(get: { host.launchAtLogin }, set: { host.setLaunchAtLogin($0) })
      ) {
        Label("Launch at Login", systemImage: "power")
      }
      info(host.loginCaption)
      Divider()
      Toggle(
        isOn: Binding(get: { !host.menuVisible }, set: { host.setMenuVisible(!$0) })
      ) {
        Label("Hide Menu Bar Icon", systemImage: "menubar.rectangle")
      }
      info("Open MonoPods again to bring it back.")
    } label: {
      Label("Options", systemImage: "gearshape")
    }
    Divider()
    info(information.versionLabel)
    Button("About MonoPods", action: showAbout)
    if updates.state.showsItems {
      Button(UpdateText.check) { updates.checkForUpdates() }
        .disabled(!updates.state.checkEnabled)
    }
    if host.waitingForUpdate {
      Button(UpdateText.resume, action: confirmResume)
    }
    Divider()
    Button("Quit MonoPods") { host.quit() }.keyboardShortcut("q")
  }

  /// Wrap free text without truncating notices or widening the native menu indefinitely.
  @ViewBuilder private func info(_ text: String, symbol: String? = nil) -> some View {
    ForEach(Array(MenuText.lines(text).enumerated()), id: \.offset) { index, line in
      if index == 0, let symbol {
        Label(line, systemImage: symbol)
      } else {
        Text(line)
      }
    }
  }

  private func showAbout() {
    Self.about.show()
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
