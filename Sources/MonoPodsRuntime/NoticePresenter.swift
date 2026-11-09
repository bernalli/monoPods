import AppKit
import MonoPodsCore

@MainActor public final class NoticePresenter: NSObject {
  private var panels: [NSPanel] = []
  public override init() { super.init() }
  nonisolated public static func message(_ notice: Notice) -> String {
    switch notice {
    case .previousCrash: return "MonoPods restarted after an error or an incomplete quit."
    case .detectionDisabled:
      return "Automatic Ear Detection is off. Turn it on in Bluetooth Settings to use MonoPods."
    case .detectionQuitReminder:
      return "If you stop using MonoPods, turn Automatic Ear Detection off in Bluetooth Settings."
    case .persistenceFailed: return "Runtime evidence could not be saved. Automation is blocked."
    case .recoveryBlocked:
      return "Command order cannot be established. Automation and recovery are blocked."
    case .stereoNotRestored:
      return
        "MonoPods did not confirm the return to Stereo. Mono may stay on. Reopen MonoPods to try again."
    case .commandFailed:
      return
        "An audio command failed repeatedly. Automatic attempts for this target are blocked. If switching does not resume, quit and reopen MonoPods."
    }
  }
  public func present(_ notice: Notice) -> Bool {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 410, height: 150),
      styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "MonoPods"
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    let text = NSTextField(wrappingLabelWithString: Self.message(notice))
    text.frame = NSRect(x: 20, y: 55, width: 370, height: 72)
    panel.contentView?.addSubview(text)
    if notice == .detectionDisabled || notice == .detectionQuitReminder {
      let button = NSButton(
        title: "Open Bluetooth Settings", target: self, action: #selector(openBluetooth))
      button.frame = NSRect(x: 20, y: 15, width: 240, height: 30)
      panel.contentView?.addSubview(button)
    }
    panel.center()
    panel.orderFrontRegardless()
    panels.append(panel)
    panels.removeAll { !$0.isVisible }
    return panel.isVisible
  }
  @objc private func openBluetooth() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Bluetooth") {
      NSWorkspace.shared.open(url)
    }
  }
}
