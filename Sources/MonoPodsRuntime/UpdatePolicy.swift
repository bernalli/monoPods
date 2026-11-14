import CoreFoundation
import Foundation

/// Decides whether this process may create an updater at all. It is pure: no framework is loaded.
public enum UpdatePolicy {
  public static let productionFeedURL =
    "https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml"
  private static let publicKeyBytes = 32

  /// Only the product, as lock owner, with the production channel embedded at bundle time.
  public static func allows(identifier: String?, role: RuntimeRole, info: [String: Any]?) -> Bool {
    guard identifier == RuntimeLocation.productIdentifier, role == .product, let info,
      info["SUEnableAutomaticChecks"] == nil,
      let feed = info["SUFeedURL"] as? String, feed == productionFeedURL,
      let key = info["SUPublicEDKey"] as? String
    else { return false }
    return validPublicKey(key)
  }
  /// Standard base64, canonical padding, 32 decoded bytes.
  public static func validPublicKey(_ key: String) -> Bool {
    guard let data = Data(base64Encoded: key), data.count == publicKeyBytes else { return false }
    return data.base64EncodedString() == key
  }
}

public struct UpdateGate: Sendable {
  private var signalled = false
  public init() {}
  /// True exactly once, the first time the owner is acquired with updates allowed.
  public mutating func ownerAcquired(allowed: Bool) -> Bool {
    guard allowed, !signalled else { return false }
    signalled = true
    return true
  }
}

public struct UpdateMenuState: Equatable, Sendable {
  /// The build has a channel and an updater exists.
  public var available: Bool
  /// The updater started, automatic downloads are off and Sparkle accepts a check now.
  public var canCheck: Bool
  /// Sparkle's scheduled checks are on: the user's choice.
  public var automaticChecks: Bool
  public init(available: Bool, canCheck: Bool, automaticChecks: Bool = false) {
    self.available = available
    self.canCheck = canCheck
    self.automaticChecks = automaticChecks
  }
  public var showsItems: Bool { available }
  public var checkEnabled: Bool { available && canCheck }
}

/// The answer to the question about automatic checks at first launch.
public enum AutomaticUpdateAnswer: Sendable {
  case enable, decline, dismissed

  /// The first button enables, the second declines; anything else dismisses.
  public init(buttonIndex: Int?) {
    switch buttonIndex {
    case 0: self = .enable
    case 1: self = .decline
    default: self = .dismissed
    }
  }
}

/// The updater as the update logic sees it; the app target adapts Sparkle to it.
@MainActor public protocol UpdaterPort: AnyObject {
  var automaticChecks: Bool { get }
  var automaticDownloads: Bool { get }
  var canCheckForUpdates: Bool { get }
  /// Value in the app's persistent domain, without Sparkle's filtering or defaults.
  var rawAutomaticDownloads: Any? { get }
  /// True once the question about automatic checks has been asked.
  var automaticUpdateQuestionAsked: Bool { get }
  /// Writes the raw download preference first, then the Sparkle setter.
  func switchOffAutomaticDownloads()
  /// Sets Sparkle's scheduled checks; nothing else writes them.
  func setAutomaticChecks(_ enabled: Bool)
  /// Records, in the app's preferences, that the question has been asked.
  func markAutomaticUpdateQuestionAsked()
  /// Flushes the app's preferences and reports whether persistence succeeded.
  func synchronizeAutomaticPreferences() -> Bool
  func startUpdater() -> Bool
  func checkForUpdates()
}

/// Automatic downloads stay off. Scheduled checks are the user's choice, asked once at first
/// launch; a user check passes once per menu command. Every installation still needs the
/// user's Install.
@MainActor public final class UpdateCoordinator {
  public private(set) var state = UpdateMenuState(available: false, canCheck: false)
  public var onChange: (@MainActor () -> Void)?
  /// Shows the question about automatic checks; the reply may come later, or never.
  public var ask: (@MainActor (@escaping @MainActor (AutomaticUpdateAnswer) -> Void) -> Void)?
  private let port: any UpdaterPort
  private var started = false
  private var updaterStarted = false
  private var changingPreferences = false
  private var preferencesSynchronized = false
  private var gateOpen = false
  private var manualPending = false
  private var questionPending = false

  public init(port: any UpdaterPort) {
    self.port = port
  }

  /// Switches automatic downloads off, also when an older build left them on. On the first
  /// launch it turns checks off and writes the flag before it asks, so the question comes once.
  public func start() {
    guard !started else { return }
    started = true
    state.available = true
    switchOff()
    if !port.automaticUpdateQuestionAsked {
      port.setAutomaticChecks(false)
      port.markAutomaticUpdateQuestionAsked()
      questionPending = true
    }
    updaterStarted = port.startUpdater()
    canCheckChanged()
    if questionPending {
      ask? { [weak self] answer in self?.answer(answer) }
    }
  }

  /// The switch in the menu. It also settles a question still waiting for its answer.
  public func setAutomaticChecks(_ enabled: Bool) {
    guard started else { return }
    questionPending = false
    port.setAutomaticChecks(enabled)
    canCheckChanged()
  }

  /// Key-value observation of either setting, also from outside the app: downloads on are
  /// switched off; a change of the checks is accepted.
  public func settingsChanged() {
    guard started, !changingPreferences else { return }
    if preferencesSynchronized && downloadsOff {
      gateOpen = true
    } else {
      switchOff()
    }
    canCheckChanged()
  }

  public func canCheckChanged() {
    state.canCheck =
      updaterStarted && gateOpen && !changingPreferences && downloadsOff && port.canCheckForUpdates
    state.automaticChecks = port.automaticChecks
    publish()
  }

  /// The menu command. It alone authorizes a user check.
  public func checkForUpdates() {
    guard state.checkEnabled, gateOpen, downloadsOff else { return }
    manualPending = true
    port.checkForUpdates()
  }

  /// Sparkle asks before every check. A user check passes once per menu command; a scheduled
  /// check passes only with automatic checks on and the question answered. Both need
  /// automatic downloads off.
  public func mayPerformCheck(userInitiated: Bool) -> Bool {
    guard updaterStarted, gateOpen, !changingPreferences, downloadsOff else { return false }
    guard userInitiated else { return port.automaticChecks && !questionPending }
    guard manualPending else { return false }
    manualPending = false
    return true
  }

  /// Only the first answer to a pending question counts.
  private func answer(_ answer: AutomaticUpdateAnswer) {
    guard questionPending else { return }
    questionPending = false
    port.setAutomaticChecks(answer == .enable)
    canCheckChanged()
  }

  private var downloadsOff: Bool {
    Self.isBooleanFalse(port.rawAutomaticDownloads) && !port.automaticDownloads
  }

  /// `as? Bool` also accepts NSNumber(0/1). Only a property-list boolean is evidence.
  private static func isBooleanFalse(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return false }
    return !number.boolValue
  }

  /// The only path that writes automatic downloads. A failed write leaves the gate closed.
  private func switchOff() {
    guard !changingPreferences else { return }
    changingPreferences = true
    gateOpen = false
    preferencesSynchronized = false
    canCheckChanged()
    port.switchOffAutomaticDownloads()
    preferencesSynchronized = port.synchronizeAutomaticPreferences()
    // Read the raw value after synchronization, even when the effective getter says off.
    let downloadsAreOff = downloadsOff
    gateOpen = preferencesSynchronized && downloadsAreOff
    changingPreferences = false
  }

  private func publish() { onChange?() }
}

/// Fixed texts of the update command and of the update states.
public enum UpdateText {
  public static var check: String { Localized.text("Check for Updates\u{2026}") }
  /// Also the runtime status while installing, so it stays English; it is translated where shown.
  public static let installing =
    "An update is being installed. MonoPods restarts when the new version is in place."
  public static var resume: String { Localized.text("Resume Without Updating\u{2026}") }
  public static var resumeTitle: String { Localized.text("Resume Without Updating?") }
  public static var resumeText: String {
    Localized.text(
      "Use this only if the update did not complete. MonoPods restarts the installed version; then choose Check for Updates… again or reinstall MonoPods from the disk image."
    )
  }
  public static var resumeConfirm: String { Localized.text("Resume") }
  public static var cancel: String { Localized.text("Cancel") }
}
