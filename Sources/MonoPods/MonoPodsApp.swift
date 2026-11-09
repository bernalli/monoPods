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
  @StateObject private var host = RuntimeHost()
  @StateObject private var updates: UpdateController
  init() {
    let model = RuntimeHost()
    let updates = UpdateController(host: model)
    model.onUpdatesAllowed = { updates.start() }
    model.start()
    _host = StateObject(wrappedValue: model)
    _updates = StateObject(wrappedValue: updates)
  }
  private static let menuBarIcon: NSImage? = {
    let image = NSImage(named: "MenuBarIcon")
    image?.isTemplate = true
    return image
  }()
  private static let monoLeftIcon = ringsIcon(leftFilled: true, rightFilled: false)
  private static let monoRightIcon = ringsIcon(leftFilled: false, rightFilled: true)
  /// One template image per ripple frame; the last one is the still Stereo icon.
  private static let stereoFrames = (0..<StereoRipple.frameCount).map { frame in
    stereoIcon(frame: frame)
  }
  /// Keep the warning in the same template image as the rings.
  private static let attentionIcon: NSImage = {
    let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
      NSColor.black.set()
      let rings = [RingGeometry.leftCentre, RingGeometry.rightCentre].map { centre in
        NSBezierPath(
          ovalIn: NSRect(
            x: centre.x - RingGeometry.radius, y: centre.y - RingGeometry.radius,
            width: 2 * RingGeometry.radius, height: 2 * RingGeometry.radius))
      }
      for ring in rings {
        ring.lineWidth = RingGeometry.lineWidth
        ring.stroke()
      }
      NSGraphicsContext.saveGraphicsState()
      rings[0].addClip()
      rings[1].fill()
      NSGraphicsContext.restoreGraphicsState()
      NSBezierPath(rect: NSRect(x: 19, y: 7, width: 1.5, height: 6.5)).fill()
      NSBezierPath(ovalIn: NSRect(x: 19, y: 4.5, width: 1.5, height: 1.5)).fill()
      return true
    }
    image.isTemplate = true
    return image
  }()
  /// A template image with the asset's two rings; a filled ring is a solid disc of the ring's outer
  /// radius. The overlap is always solid, as in the asset: it lies inside each filled disc.
  private static func ringsIcon(leftFilled: Bool, rightFilled: Bool) -> NSImage {
    let image = NSImage(size: RingGeometry.canvas, flipped: false) { _ in
      NSColor.black.set()
      let outer = RingGeometry.outerRadius
      for (centre, filled) in [
        (RingGeometry.leftCentre, leftFilled), (RingGeometry.rightCentre, rightFilled),
      ] {
        if filled {
          NSBezierPath(
            ovalIn: NSRect(
              x: centre.x - outer, y: centre.y - outer, width: 2 * outer, height: 2 * outer)
          ).fill()
        } else {
          let ring = NSBezierPath(
            ovalIn: NSRect(
              x: centre.x - RingGeometry.radius, y: centre.y - RingGeometry.radius,
              width: 2 * RingGeometry.radius, height: 2 * RingGeometry.radius))
          ring.lineWidth = RingGeometry.lineWidth
          ring.stroke()
        }
      }
      return true
    }
    image.isTemplate = true
    return image
  }
  /// SwiftUI may write isInserted back while it updates the scene. Publishing there re-invalidates
  /// the scene, so an equal value is ignored and a new one is applied on the next main actor turn.
  private var menuInserted: Binding<Bool> {
    let host = host
    return Binding(
      get: { host.menuVisible },
      set: { visible in
        host.requestMenuVisible(visible)
      })
  }
  /// One frame of the Stereo icon, drawn at the scale of the context that displays it.
  private static func stereoIcon(frame: Int) -> NSImage {
    let image = NSImage(size: RingGeometry.canvas, flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      StereoGlyph.draw(frame: frame, in: context)
      return true
    }
    image.isTemplate = true
    return image
  }
  @ViewBuilder private var assetIcon: some View {
    if let image = Self.menuBarIcon {
      Image(nsImage: image)
    } else {
      Image(systemName: "circle.lefthalf.filled")
    }
  }
  var body: some Scene {
    MenuBarExtra(isInserted: menuInserted) {
      MenuPanel(host: host, updates: updates)
        .labelStyle(.titleAndIcon)
    } label: {
      switch host.glyph {
      case .mono(.left): Image(nsImage: Self.monoLeftIcon)
      case .mono(.right): Image(nsImage: Self.monoRightIcon)
      case .stereo:
        Image(nsImage: Self.stereoFrames[min(max(host.waveFrame, 0), StereoRipple.restingFrame)])
      case .idle: assetIcon
      case .attention: Image(nsImage: Self.attentionIcon)
      }
    }
    .menuBarExtraStyle(.menu)
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
    // The host starts before any ordinary window exists; MenuBarExtra alone does not have an app onAppear.
    if delegate.host == nil {
      delegate.host = host
    }
    return self
  }
}
