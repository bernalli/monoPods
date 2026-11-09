import AppKit
import CryptoKit
import MonoPodsCore

/// Control notifications carry no audio command or device identity.
@MainActor public final class OwnerChannel: NSObject {
  private let scope: String
  public var command: ((String) -> Void)?
  public var confirmation: ((UInt64, String, Bool) -> Void)?
  public init(directory: String) {
    scope = "io.github.bernalli.monopods." + ArtifactHash.data(Data(directory.utf8))
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(receive(_:)), name: Notification.Name(scope), object: nil)
  }
  public func send(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(scope), object: nil,
      userInfo: ["command": command], deliverImmediately: true)
  }
  public func confirm(run: UInt64, build: String, healthy: Bool) {
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(scope), object: nil,
      userInfo: ["run": String(run), "build": build, "healthy": healthy], deliverImmediately: true)
  }
  @objc private func receive(_ notification: Notification) {
    if let value = notification.userInfo?["command"] as? String { command?(value) }
    if let raw = notification.userInfo?["run"] as? String, let run = UInt64(raw), run > 0,
      let build = notification.userInfo?["build"] as? String, ContractValidation.hash(build),
      let healthy = notification.userInfo?["healthy"] as? Bool
    {
      confirmation?(run, build, healthy)
    }
  }
  public func stop() { DistributedNotificationCenter.default().removeObserver(self) }
}
