import AppKit
import MonoPodsRuntime

/// The question about automatic update checks at first launch.
///
/// Like the update driver, the alert's window is shown without a modal session, so the run loop
/// keeps running. The question keeps itself alive until the first click or window close; later
/// clicks do nothing.
@MainActor final class AutomaticUpdateQuestion: NSObject {
  let alert = NSAlert()
  private let present: @MainActor (NSWindow, Bool) -> Void
  private var reply: (@MainActor (AutomaticUpdateAnswer) -> Void)?
  private var closeObserver: NSObjectProtocol?
  /// Holds the question while it waits for its answer.
  private var retained: AutomaticUpdateQuestion?

  init(
    appName: String, strings: Bundle = .main,
    present: @escaping @MainActor (NSWindow, Bool) -> Void = AppleStyleUpdateDriver.present,
    reply: @escaping @MainActor (AutomaticUpdateAnswer) -> Void
  ) {
    self.present = present
    self.reply = reply
    super.init()
    alert.messageText = Localized.text("Check for Updates Automatically?", bundle: strings)
    alert.informativeText = Localized.format(
      "%@ can check for new versions once a day. You can change this at any time in Options.",
      appName, bundle: strings)
    let enable = alert.addButton(
      withTitle: Localized.text("Check Automatically", bundle: strings))
    let decline = alert.addButton(withTitle: Localized.text("Don't Check", bundle: strings))
    decline.keyEquivalent = "\u{1b}"
    for button in [enable, decline] {
      button.target = self
      button.action = #selector(choose(_:))
    }
    alert.layout()
  }

  /// Shows the alert and activates the app.
  func show() {
    guard reply != nil else { return }
    retained = self
    if closeObserver == nil {
      closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: alert.window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.finish(.dismissed) }
      }
    }
    present(alert.window, true)
  }

  /// Only the first click answers; it closes the alert and releases the question.
  @objc private func choose(_ sender: NSButton) {
    guard let index = alert.buttons.firstIndex(where: { $0 === sender }) else {
      return
    }
    finish(AutomaticUpdateAnswer(buttonIndex: index))
  }

  private func finish(_ answer: AutomaticUpdateAnswer) {
    guard let reply else { return }
    self.reply = nil
    if let closeObserver {
      NotificationCenter.default.removeObserver(closeObserver)
      self.closeObserver = nil
    }
    alert.window.orderOut(nil)
    reply(answer)
    retained = nil
  }
}
