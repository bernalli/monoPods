import AppKit
import Testing

@testable import MonoPodsRuntime

/// The app starts without a SwiftUI scene: this menu is its whole main menu.
@MainActor @Test func mainMenuHoldsOnlyQuitWithCommandQAndRunsTheGivenAction() throws {
  var quits = 0

  let menu = ApplicationMenu.make { quits += 1 }

  #expect(menu.items.count == 1)
  let applicationMenu = try #require(menu.items.first?.submenu)
  #expect(applicationMenu.items.count == 1)
  let quit = try #require(applicationMenu.items.first)
  #expect(quit.title == "Quit MonoPods")
  #expect(quit.keyEquivalent == "q")
  #expect(quit.keyEquivalentModifierMask == .command)
  #expect(quit.isEnabled)
  let settings = NSSelectorFromString("showSettingsWindow:")
  for item in menu.items + applicationMenu.items {
    #expect(item.action != settings)
    #expect(!item.title.localizedCaseInsensitiveContains("Settings"))
  }
  // Items hold their target weakly: the item must keep its own action alive.
  let target = try #require(quit.target as? NSObject)
  let action = try #require(quit.action)
  _ = target.perform(action, with: quit)
  #expect(quits == 1)
}
