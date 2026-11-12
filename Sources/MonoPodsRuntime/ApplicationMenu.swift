import AppKit

/// The main menu of the accessory app. The application menu holds one item, Quit MonoPods with
/// Command-Q; the app has no SwiftUI scene, so nothing adds Settings, window or file commands.
/// AppKit sends Command-Q to this menu only while the app is active, for example with the About
/// window in front.
public enum ApplicationMenu {
  @MainActor public static func make(quit: @escaping @MainActor () -> Void) -> NSMenu {
    let applicationMenu = NSMenu(title: "MonoPods")
    applicationMenu.addItem(
      ActionMenuItem(title: "Quit MonoPods", keyEquivalent: "q", perform: quit))
    let applicationItem = NSMenuItem(title: "MonoPods", action: nil, keyEquivalent: "")
    applicationItem.submenu = applicationMenu
    let mainMenu = NSMenu(title: "Main Menu")
    mainMenu.addItem(applicationItem)
    return mainMenu
  }
}

/// A menu item that runs its closure. A menu item holds its target weakly, so the item is its own
/// target: the menu that retains the item also keeps the action alive.
private final class ActionMenuItem: NSMenuItem {
  private let perform: @MainActor () -> Void

  init(title: String, keyEquivalent: String, perform: @escaping @MainActor () -> Void) {
    self.perform = perform
    super.init(title: title, action: #selector(run(_:)), keyEquivalent: keyEquivalent)
    target = self
  }

  required init(coder: NSCoder) {
    fatalError("ActionMenuItem is created in code")
  }

  // AppKit sends menu actions on the main thread.
  @MainActor @objc private func run(_ sender: NSMenuItem) { perform() }
}
