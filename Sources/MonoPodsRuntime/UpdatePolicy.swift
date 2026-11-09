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
  /// The updater started, both automatic settings are off and Sparkle accepts a check now.
  public var canCheck: Bool
  public init(available: Bool, canCheck: Bool) {
    self.available = available
    self.canCheck = canCheck
  }
  public var showsItems: Bool { available }
  public var checkEnabled: Bool { available && canCheck }
}

/// The updater as the update logic sees it; the app target adapts Sparkle to it.
@MainActor public protocol UpdaterPort: AnyObject {
  var automaticChecks: Bool { get }
  var automaticDownloads: Bool { get }
  var canCheckForUpdates: Bool { get }
  /// Values in the app's persistent domain, without Sparkle's filtering or defaults.
  var rawAutomaticChecks: Any? { get }
  var rawAutomaticDownloads: Any? { get }
  /// Writes raw preferences first, then Sparkle setters; downloads before checks in each pair.
  func switchOffAutomatic()
  /// Flushes the app's preferences and reports whether persistence succeeded.
  func synchronizeAutomaticPreferences() -> Bool
  func startUpdater() -> Bool
  func checkForUpdates()
}

/// Manual checks only: Sparkle's automatic settings stay off, and only the menu command
/// authorizes a check. No check happens without that command.
@MainActor public final class UpdateCoordinator {
  public private(set) var state = UpdateMenuState(available: false, canCheck: false)
  public var onChange: (@MainActor () -> Void)?
  private let port: any UpdaterPort
  private var started = false
  private var updaterStarted = false
  private var changingPreferences = false
  private var preferencesSynchronized = false
  private var gateOpen = false
  private var manualPending = false

  public init(port: any UpdaterPort) {
    self.port = port
  }

  /// Switches both automatic settings off, also those an older build left on, then starts
  /// the updater. Nothing is asked.
  public func start() {
    guard !started else { return }
    started = true
    state.available = true
    switchOff()
    updaterStarted = port.startUpdater()
    canCheckChanged()
  }

  /// Key-value observation of either setting, also from outside the app: on is switched off.
  public func settingsChanged() {
    guard started, !changingPreferences else { return }
    if preferencesSynchronized && settingsOff {
      gateOpen = true
    } else {
      switchOff()
    }
    canCheckChanged()
  }

  public func canCheckChanged() {
    state.canCheck =
      updaterStarted && gateOpen && !changingPreferences && settingsOff && port.canCheckForUpdates
    publish()
  }

  /// The menu command. It alone authorizes a check.
  public func checkForUpdates() {
    guard state.checkEnabled, gateOpen, settingsOff else { return }
    manualPending = true
    port.checkForUpdates()
  }

  /// Sparkle asks before every check. A scheduled check is always refused; a user check
  /// passes once per menu command, with both automatic settings off.
  public func mayPerformCheck(userInitiated: Bool) -> Bool {
    guard userInitiated, updaterStarted, gateOpen, !changingPreferences, settingsOff,
      manualPending
    else { return false }
    manualPending = false
    return true
  }

  private var settingsOff: Bool {
    let rawChecks = port.rawAutomaticChecks
    let rawDownloads = port.rawAutomaticDownloads
    return Self.isBooleanFalse(rawChecks) && Self.isBooleanFalse(rawDownloads)
      && !port.automaticChecks && !port.automaticDownloads
  }

  /// `as? Bool` also accepts NSNumber(0/1). Only a property-list boolean is evidence.
  private static func isBooleanFalse(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFBooleanGetTypeID()
    else { return false }
    return !number.boolValue
  }

  /// The only path that writes the two settings. A failed write leaves the gate closed.
  private func switchOff() {
    guard !changingPreferences else { return }
    changingPreferences = true
    gateOpen = false
    preferencesSynchronized = false
    canCheckChanged()
    port.switchOffAutomatic()
    preferencesSynchronized = port.synchronizeAutomaticPreferences()
    // Read the raw values after synchronization, even when the effective getters say off.
    let settingsAreOff = settingsOff
    gateOpen = preferencesSynchronized && settingsAreOff
    changingPreferences = false
  }

  private func publish() { onChange?() }
}

/// Fixed texts of the update command and of the update states.
public enum UpdateText {
  public static let check = "Check for Updates\u{2026}"
  public static let installing =
    "An update is being installed. MonoPods restarts when the new version is in place."
  public static let resume = "Resume Without Updating\u{2026}"
  public static let resumeTitle = "Resume Without Updating?"
  public static let resumeText =
    "Use this only if the update did not complete. MonoPods restarts the installed version; then choose Check for Updates\u{2026} again or reinstall MonoPods from the disk image."
  public static let resumeConfirm = "Resume"
  public static let cancel = "Cancel"
}
