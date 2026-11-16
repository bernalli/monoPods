import AppKit
import Foundation
import Sparkle

/// A Sparkle user driver that shows each update phase as a compact system-style alert.
///
/// The alert's window is shown without a modal session, so Sparkle's run loop keeps running and
/// `dismissUpdateInstallation()` can close it. Texts come from the `AppleStyleUpdateDriver`
/// table of the bundle passed in; a missing table shows English.
@MainActor public final class AppleStyleUpdateDriver: NSObject, SPUUserDriver {
  public static let stringsTable = "AppleStyleUpdateDriver"

  private let appName: String
  private let currentVersion: String
  private let strings: Bundle
  private let present: @MainActor (NSWindow, Bool) -> Void
  private let openURL: @MainActor (URL) -> Void

  /// The alert on screen, if any; at most one at a time.
  private(set) var alert: NSAlert?
  /// One action per button of `alert`, in order; nil for a button that does nothing.
  private var actions: [(() -> Void)?] = []
  private var downloadBar: NSProgressIndicator?
  private var extractionBar: NSProgressIndicator?
  private var expectedLength: UInt64 = 0
  private var receivedLength: UInt64 = 0
  /// Install and Relaunch was clicked on the alert of the update now in progress. Sparkle asks
  /// again once the update is prepared; that question is answered with this choice.
  private var installChosen = false

  public init(
    appName: String, currentVersion: String, strings: Bundle,
    present: @escaping @MainActor (NSWindow, Bool) -> Void = AppleStyleUpdateDriver.present,
    openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
  ) {
    self.appName = appName
    self.currentVersion = currentVersion
    self.strings = strings
    self.present = present
    self.openURL = openURL
    super.init()
  }

  /// Name from CFBundleDisplayName, then CFBundleName; version from CFBundleShortVersionString;
  /// strings from the same bundle.
  public convenience init(hostBundle: Bundle) {
    let name =
      hostBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? hostBundle.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? hostBundle.bundleURL.deletingPathExtension().lastPathComponent
    let version =
      hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    self.init(appName: name, currentVersion: version, strings: hostBundle)
  }

  /// Activates the app and makes the window key when `activate` is true; otherwise orders it
  /// front without activation.
  public static func present(_ window: NSWindow, activate: Bool) {
    if !window.isVisible { window.center() }
    if activate {
      NSApplication.shared.activate()
      window.makeKeyAndOrderFront(nil)
    } else {
      window.orderFrontRegardless()
    }
  }

  // MARK: - SPUUserDriver

  /// The app sets automatic checks before it starts the updater, so Sparkle does not ask.
  public func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    installChosen = false
    show(
      localized("Checking for Updates\u{2026}"), bar: Self.makeBar(),
      buttons: [Button(localized("Cancel"), cancels: true) { cancellation() }], activate: true)
  }

  public func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    presentUpdate(
      version: appcastItem.displayVersionString,
      informationOnly: appcastItem.isInformationOnlyUpdate, infoURL: appcastItem.infoURL,
      userInitiated: state.userInitiated, reply: reply)
  }

  public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

  public func showUpdateNotFoundWithError(
    _ error: any Error, acknowledgement: @escaping () -> Void
  ) {
    let error = error as NSError
    let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
    presentNotFound(
      reason: reason, description: error.localizedDescription, acknowledgement: acknowledgement)
  }

  public func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    show(
      localized("The update could not be completed."), information: error.localizedDescription,
      buttons: [Button(localized("OK")) { acknowledgement() }], activate: true)
  }

  public func showDownloadInitiated(cancellation: @escaping () -> Void) {
    expectedLength = 0
    receivedLength = 0
    let bar = Self.makeBar()
    show(
      localized("Downloading Update\u{2026}"), bar: bar,
      buttons: [Button(localized("Cancel"), cancels: true) { cancellation() }], activate: false)
    downloadBar = bar
  }

  /// The length can arrive more than once; the bytes already received stay counted.
  public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expectedLength = expectedContentLength
    updateDownloadBar()
  }

  public func showDownloadDidReceiveData(ofLength length: UInt64) {
    let (sum, overflow) = receivedLength.addingReportingOverflow(length)
    receivedLength = overflow ? .max : sum
    updateDownloadBar()
  }

  /// From here the download can no longer be cancelled.
  public func showDownloadDidStartExtractingUpdate() {
    let bar = Self.makeBar()
    show(
      localized("Preparing Update\u{2026}"), bar: bar,
      buttons: [Button(localized("Cancel"), cancels: true, enabled: false, action: nil)],
      activate: false)
    extractionBar = bar
  }

  public func showExtractionReceivedProgress(_ progress: Double) {
    guard let extractionBar else { return }
    Self.set(extractionBar, to: progress.isFinite ? min(max(progress, 0), 1) : nil)
  }

  /// Asks only when the user has not already chosen Install and Relaunch for this update.
  public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    if installChosen {
      installChosen = false
      reply(.install)
      return
    }
    show(
      format(localized("%@ is ready to install."), appName),
      buttons: [
        Button(localized("Install and Relaunch")) { reply(.install) },
        Button(localized("Later"), cancels: true) { reply(.dismiss) },
      ], activate: true)
  }

  /// While the app still runs, Install and Relaunch asks it to quit again; it may be clicked
  /// any number of times.
  public func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    let retry =
      applicationTerminated
      ? Button(localized("Install and Relaunch"), enabled: false, action: nil)
      : Button(localized("Install and Relaunch"), closes: false) { retryTerminatingApplication() }
    show(
      localized("Installing Update\u{2026}"), bar: Self.makeBar(), buttons: [retry], activate: false
    )
  }

  public func showUpdateInstalledAndRelaunched(
    _ relaunched: Bool, acknowledgement: @escaping () -> Void
  ) {
    installChosen = false
    close()
    acknowledgement()
  }

  public func showUpdateInFocus() {
    guard let alert else { return }
    present(alert.window, true)
  }

  /// Like Sparkle's standard driver: closes everything and drops the callbacks uncalled.
  public func dismissUpdateInstallation() {
    installChosen = false
    close()
  }

  // MARK: - Plain-value entry points

  /// An available update. An information-only update can never reply `.install`; no choice
  /// replies `.skip`.
  func presentUpdate(
    version: String, informationOnly: Bool, infoURL: URL?, userInitiated: Bool,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    installChosen = false
    let message = format(
      localized("%1$@ %2$@ is available (you have %3$@)."), appName, version, currentVersion)
    let first =
      informationOnly
      ? Button(localized("More Info\u{2026}")) { [openURL] in
        if let infoURL { openURL(infoURL) }
        reply(.dismiss)
      }
      : Button(localized("Install and Relaunch")) { [weak self] in
        self?.installChosen = true
        reply(.install)
      }
    show(
      message, buttons: [first, Button(localized("Later"), cancels: true) { reply(.dismiss) }],
      activate: userInitiated)
  }

  /// Sparkle's reasons that mean the app is up to date; every other reason is shown as an error.
  private static let upToDateReasons = Set(
    [SPUNoUpdateFoundReason.unknown, .onLatestVersion, .onNewerThanLatestVersion].map {
      Int($0.rawValue)
    })

  /// No update: reasons 0, 1 and 2 (or none) mean up to date; any other shows the error.
  func presentNotFound(reason: Int?, description: String, acknowledgement: @escaping () -> Void) {
    let upToDate = reason.map { Self.upToDateReasons.contains($0) } ?? true
    let message = upToDate ? format(localized("%@ is up to date."), appName) : description
    show(message, buttons: [Button(localized("OK")) { acknowledgement() }], activate: true)
  }

  // MARK: - Alerts

  /// A button of an alert. A closing button closes the alert before its action runs.
  private struct Button {
    let title: String
    let cancels: Bool
    let enabled: Bool
    let closes: Bool
    let action: (() -> Void)?

    init(
      _ title: String, cancels: Bool = false, enabled: Bool = true, closes: Bool = true,
      action: (() -> Void)?
    ) {
      self.title = title
      self.cancels = cancels
      self.enabled = enabled
      self.closes = closes
      self.action = action
    }
  }

  /// Replaces the current alert. The first button is the default; a cancelling one gets Escape.
  private func show(
    _ message: String, information: String = "", bar: NSProgressIndicator? = nil,
    buttons: [Button], activate: Bool
  ) {
    close()
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = information
    alert.accessoryView = bar
    for choice in buttons {
      let button = alert.addButton(withTitle: choice.title)
      if choice.cancels { button.keyEquivalent = "\u{1b}" }
      button.isEnabled = choice.enabled
      button.target = self
      button.action = #selector(choose(_:))
    }
    alert.layout()
    self.alert = alert
    actions = buttons.map { choice in
      guard let action = choice.action else { return nil }
      guard choice.closes else { return action }
      return { [weak self] in
        self?.close()
        action()
      }
    }
    present(alert.window, activate)
  }

  /// Finds the button among the current alert's buttons; a button of a closed alert does nothing.
  @objc private func choose(_ sender: NSButton) {
    guard sender.isEnabled, let alert,
      let index = alert.buttons.firstIndex(where: { $0 === sender }), index < actions.count,
      let action = actions[index]
    else { return }
    action()
  }

  /// Orders the window out and releases the alert's callbacks without calling them.
  private func close() {
    alert?.window.orderOut(nil)
    alert = nil
    actions = []
    downloadBar = nil
    extractionBar = nil
  }

  private func updateDownloadBar() {
    guard let downloadBar else { return }
    Self.set(
      downloadBar,
      to: expectedLength > 0 ? min(Double(receivedLength) / Double(expectedLength), 1) : nil)
  }

  private static func makeBar() -> NSProgressIndicator {
    let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 280, height: 20))
    bar.style = .bar
    bar.minValue = 0
    bar.maxValue = 1
    set(bar, to: nil)
    return bar
  }

  /// A value in [0, 1], or nil for an indeterminate bar.
  private static func set(_ bar: NSProgressIndicator, to value: Double?) {
    if let value {
      bar.isIndeterminate = false
      bar.doubleValue = value
    } else {
      bar.isIndeterminate = true
      bar.startAnimation(nil)
    }
  }

  // MARK: - Texts

  private func localized(_ key: String) -> String {
    strings.localizedString(forKey: key, value: key, table: Self.stringsTable)
  }

  private func format(_ template: String, _ arguments: String...) -> String {
    String(format: template, arguments: arguments.map { $0 as NSString })
  }
}
