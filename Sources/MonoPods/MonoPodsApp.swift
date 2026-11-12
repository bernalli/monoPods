import AppKit
import MonoPodsCore
import MonoPodsRuntime

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  let host: RuntimeHost
  init(host: RuntimeHost) {
    self.host = host
  }
  /// The app has no windows to reopen: the host handles the event and AppKit adds nothing.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    ApplicationReopen.handle { host.reopen() }
  }
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // The source build waiting for its replacement refuses Sparkle's Quit, not the session's.
    if host.waitingForUpdate {
      let reason = NSAppleEventManager.shared().currentAppleEvent?
        .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
      return WaitingTermination.reply(quitReason: reason) == .now ? .terminateNow : .terminateCancel
    }
    host.requestQuit(reason: .logout)
    return .terminateLater
  }
}

/// The objects that live as long as the app. `NSApplication.delegate` is weak, and the status
/// menu keeps the updater alive.
@MainActor private enum Application {
  static var delegate: AppDelegate?
  static var statusMenu: StatusMenuController?
}

// The app is AppKit only: the status item is the UI, and there is no SwiftUI scene.
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
    let host = RuntimeHost()
    let updates = UpdateController(host: host)
    host.onUpdatesAllowed = { updates.start() }
    host.start()
    Application.statusMenu = StatusMenuController(host: host, updates: updates)
    let delegate = AppDelegate(host: host)
    Application.delegate = delegate
    let application = NSApplication.shared
    application.delegate = delegate
    application.mainMenu = ApplicationMenu.make { host.quit() }
    application.run()
  }
}
