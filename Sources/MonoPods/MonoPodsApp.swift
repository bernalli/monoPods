import AppKit
import MonoPodsCore
import MonoPodsRuntime
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var host: RuntimeHost?
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    host?.reopen()
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // The source build waiting for its replacement refuses Sparkle's Quit, not the session's.
    if host?.waitingForUpdate == true {
      let reason = NSAppleEventManager.shared().currentAppleEvent?
        .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
      return WaitingTermination.reply(quitReason: reason) == .now ? .terminateNow : .terminateCancel
    }
    host?.requestQuit(reason: .logout)
    return .terminateLater
  }
}

@MainActor struct MonoPodsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  private let host: RuntimeHost
  /// The menu bar item lives as long as the app; it also keeps the updater alive.
  private static var statusMenu: StatusMenuController?
  init() {
    let model = RuntimeHost()
    let updates = UpdateController(host: model)
    model.onUpdatesAllowed = { updates.start() }
    model.start()
    host = model
    if Self.statusMenu == nil {
      Self.statusMenu = StatusMenuController(host: model, updates: updates)
    }
  }
  /// The menu bar item is AppKit (see `StatusMenuController`); SwiftUI keeps only the app
  /// commands. An accessory app never shows the empty Settings scene.
  var body: some Scene {
    Settings { EmptyView() }
      .commands {
        CommandGroup(replacing: .appTermination) {
          Button("Quit MonoPods") { host.quit() }.keyboardShortcut("q")
        }
      }
      .withDelegate(host: host, delegate: delegate)
  }
}

// Install the delegate and start once before entering the SwiftUI scene loop.
@main enum Entry {
  @MainActor static func main() async {
    let args = CommandLine.arguments
    NSApplication.shared.setActivationPolicy(.accessory)
    if args.contains("--self-check") {
      DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(124) }
      let result = await BundleSelfCheck.run(bundle: .main)
      FileHandle.standardOutput.write(
        Data((result.output + (result.succeeded ? "SELF_CHECK_OK\n" : "SELF_CHECK_FAILED\n")).utf8))
      exit(result.succeeded ? 0 : 1)
    }
    if args.count == 3, args[1] == "--notice", let notice = Notice(rawValue: args[2]) {
      let presenter = NoticePresenter()
      guard presenter.present(notice) else { exit(1) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
      withExtendedLifetime(presenter) { NSApplication.shared.run() }
      return
    }
    if args.count == 3, args[1] == "--harness-control",
      let environment = try? RuntimeEnvironment.current(),
      let location = try? RuntimeLocation.resolve(bundle: .main, environment: environment),
      location.role == .isolatedHarness
    {
      let channel = OwnerChannel(directory: location.runtimeDirectory)
      channel.send(args[2])
      exit(0)
    }
    MonoPodsApp.main()
  }
}

extension Scene {
  @MainActor func withDelegate(host: RuntimeHost, delegate: AppDelegate) -> some Scene {
    // The host starts before any ordinary window exists, and the scene has no app onAppear.
    if delegate.host == nil {
      delegate.host = host
    }
    return self
  }
}
