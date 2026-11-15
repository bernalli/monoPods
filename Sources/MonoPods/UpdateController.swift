import AppKit
import CoreFoundation
import MonoPodsCore
import MonoPodsRuntime
import Sparkle

/// The Sparkle updater of the product owner. Checks happen on the user's command and, if the
/// user turned them on, on Sparkle's schedule; the network gate and the installation gate are
/// decided by `UpdateCoordinator` and `UpdateInstaller`.
@MainActor final class UpdateController: NSObject, ObservableObject {
  @Published private(set) var state = UpdateMenuState(available: false, canCheck: false)
  private let host: RuntimeHost
  private var updater: SPUUpdater?
  private var updateDriver: AppleStyleUpdateDriver?
  private var gatedDriver: GatedUserDriver?
  private var coordinator: UpdateCoordinator?
  private var installer: UpdateInstaller?
  private var observations: [NSKeyValueObservation] = []
  private var port: SparklePort?

  init(host: RuntimeHost) {
    self.host = host
  }

  /// Creates the updater once; the coordinator switches automatic downloads off and starts it.
  func start() {
    guard updater == nil, let store = host.handoffStore, let version = host.bundleVersion else {
      return
    }
    let bundle = Bundle.main
    let driver = AppleStyleUpdateDriver(hostBundle: bundle)
    let gated = GatedUserDriver(inner: driver, controller: self)
    let updater = SPUUpdater(
      hostBundle: bundle, applicationBundle: bundle, userDriver: gated, delegate: self)
    self.updater = updater
    updateDriver = driver
    gatedDriver = gated
    let installer = UpdateInstaller(
      sourceBuild: version, sourceManifest: host.manifestBuild, audio: host, store: store,
      clock: { SystemClock.now().continuousNanos },
      schedule: UpdatePreparationDeadline.background,
      warn: { [host] in
        let warning = host.stereoRestoreWarning()
        return { warning.warn() }
      })
    installer.requestBackgroundCheck = { [weak self] in self?.resumeAfterPreparation() }
    self.installer = installer
    let port = SparklePort(updater: updater, preferencesDomain: bundle.bundleIdentifier)
    self.port = port
    let coordinator = UpdateCoordinator(port: port)
    coordinator.onChange = { [weak self, weak coordinator] in
      guard let self, let coordinator else { return }
      if state != coordinator.state { state = coordinator.state }
    }
    coordinator.ask = { reply in AutomaticUpdateQuestion(appName: "MonoPods", reply: reply).show() }
    self.coordinator = coordinator
    observations = [
      updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.coordinator?.canCheckChanged() }
      },
      updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.coordinator?.settingsChanged() }
      },
      updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.coordinator?.settingsChanged() }
      },
    ]
    coordinator.start()
  }

  func checkForUpdates() { coordinator?.checkForUpdates() }

  /// True while the installer may run for the current transition.
  var installsNow: Bool { installer?.installsNow ?? false }

  /// The manual path: the user's Install waits for Stereo and the persisted handoff.
  func authorizeInstall(item: SUAppcastItem, reply: @escaping @MainActor (Bool) -> Void) {
    guard let installer, let build = Self.build(of: item) else {
      reply(false)
      return
    }
    installer.propose(destinationBuild: build, completion: reply)
  }

  /// The second automatic check, after the vetoed one, once Stereo is safe and persisted.
  private func resumeAfterPreparation() {
    guard let updater, !updater.sessionInProgress else { return }
    updater.checkForUpdatesInBackground()
  }

  private static func build(of item: SUAppcastItem) -> Int? {
    let text = item.versionString
    guard let number = Int(text), String(number) == text, number > 0,
      number <= UpdateTransition.maximumBuild
    else { return nil }
    return number
  }

}

private enum UpdateRefusal: Error { case notAllowed, preparing }

/// The only object that writes Sparkle's two automatic settings: downloads only to off,
/// checks only as the user chose.
@MainActor private final class SparklePort: UpdaterPort {
  private weak var updater: SPUUpdater?
  private let preferencesDomain: String?
  private let downloadsKey = "SUAutomaticallyUpdate" as CFString
  private let questionKey = "automaticUpdateQuestionAsked" as CFString

  init(updater: SPUUpdater, preferencesDomain: String?) {
    self.updater = updater
    self.preferencesDomain = preferencesDomain
  }
  /// A missing updater reads as no scheduled checks and downloads on, so the gate stays closed.
  var automaticChecks: Bool { updater?.automaticallyChecksForUpdates ?? false }
  var automaticDownloads: Bool { updater?.automaticallyDownloadsUpdates ?? true }
  var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }
  var rawAutomaticDownloads: Any? { rawPreference(downloadsKey) }
  /// Only a property-list boolean true counts as asked.
  var automaticUpdateQuestionAsked: Bool {
    guard let number = rawPreference(questionKey) as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return false }
    return number.boolValue
  }

  /// Sparkle uses the main app's defaults domain. CopyValue avoids registered/global
  /// defaults and Info.plist fallbacks: missing or malformed values must close the gate.
  private func rawPreference(_ key: CFString) -> Any? {
    guard let preferencesDomain else { return nil }
    return CFPreferencesCopyValue(
      key, preferencesDomain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
  }

  /// The raw write cannot be masked by Sparkle's allowsAutomaticUpdates filter.
  func switchOffAutomaticDownloads() {
    guard let updater, let preferencesDomain else { return }
    let domain = preferencesDomain as CFString
    CFPreferencesSetAppValue(downloadsKey, kCFBooleanFalse, domain)
    updater.automaticallyDownloadsUpdates = false
  }
  /// Sparkle's setter writes its own preference.
  func setAutomaticChecks(_ enabled: Bool) {
    updater?.automaticallyChecksForUpdates = enabled
  }
  func markAutomaticUpdateQuestionAsked() {
    guard let preferencesDomain else { return }
    let domain = preferencesDomain as CFString
    CFPreferencesSetAppValue(questionKey, kCFBooleanTrue, domain)
    _ = CFPreferencesAppSynchronize(domain)
  }
  func synchronizeAutomaticPreferences() -> Bool {
    guard let preferencesDomain else { return false }
    let domain = preferencesDomain as CFString
    return CFPreferencesAppSynchronize(domain)
  }
  func startUpdater() -> Bool {
    guard let updater else { return false }
    do {
      try updater.start()
      return true
    } catch { return false }
  }
  func checkForUpdates() { updater?.checkForUpdates() }
}

extension UpdateController {
  /// The Check for Updates Automatically switch in the menu.
  func setAutomaticChecks(_ enabled: Bool) { coordinator?.setAutomaticChecks(enabled) }
}

extension UpdateController: SPUUpdaterDelegate {
  func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    let allowed =
      updateCheck != .updateInformation
      && coordinator?.mayPerformCheck(userInitiated: updateCheck == .updates) == true
    if !allowed { throw UpdateRefusal.notAllowed }
  }

  /// Automatic downloads go through a two-phase veto: the first proposal prepares Stereo.
  func updater(
    _ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
    updateCheck: SPUUpdateCheck
  ) throws {
    guard updateCheck == .updatesInBackground, updater.automaticallyDownloadsUpdates else {
      return
    }
    guard let installer, let build = Self.build(of: item),
      installer.shouldProceed(destinationBuild: build)
    else { throw UpdateRefusal.preparing }
  }

  func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
    installer?.installerWillStart()
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    installer?.cycleFinished()
  }

  /// Installs at once when the gate is armed; Sparkle then quits the app and replaces it.
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    if installsNow {
      DispatchQueue.main.async { immediateInstallHandler() }
    }
    return true
  }
}

/// Forwards everything to the inner driver and holds only the replies that would arm the
/// installer, until the installation gate is armed.
@MainActor final class GatedUserDriver: NSObject, SPUUserDriver {
  private let inner: AppleStyleUpdateDriver
  private weak var controller: UpdateController?

  init(inner: AppleStyleUpdateDriver, controller: UpdateController) {
    self.inner = inner
    self.controller = controller
  }

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    inner.show(request, reply: reply)
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    inner.showUserInitiatedUpdateCheck(cancellation: cancellation)
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    inner.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
      guard choice == .install, state.stage != .installing, let controller = self?.controller
      else {
        reply(choice)
        return
      }
      controller.authorizeInstall(item: appcastItem) { authorized in
        reply(authorized ? .install : .dismiss)
      }
    }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    inner.showUpdateReleaseNotes(with: downloadData)
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
    inner.showUpdateReleaseNotesFailedToDownloadWithError(error)
  }

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    inner.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    inner.showUpdaterError(error, acknowledgement: acknowledgement)
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    inner.showDownloadInitiated(cancellation: cancellation)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    inner.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    inner.showDownloadDidReceiveData(ofLength: length)
  }

  func showDownloadDidStartExtractingUpdate() {
    inner.showDownloadDidStartExtractingUpdate()
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    inner.showExtractionReceivedProgress(progress)
  }

  /// After the gate is armed the app installs without a second click.
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    if controller?.installsNow == true {
      reply(.install)
    } else {
      inner.showReady(toInstallAndRelaunch: reply)
    }
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    inner.showInstallingUpdate(
      withApplicationTerminated: applicationTerminated,
      retryTerminatingApplication: retryTerminatingApplication)
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    inner.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
  }

  func showUpdateInFocus() {
    inner.showUpdateInFocus()
  }

  func dismissUpdateInstallation() {
    inner.dismissUpdateInstallation()
  }
}
