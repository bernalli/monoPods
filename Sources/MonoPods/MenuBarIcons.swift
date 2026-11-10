import AppKit
import MonoPodsCore
import MonoPodsRuntime

/// Template images of the menu bar item, drawn once and reused for every glyph change.
@MainActor enum MenuBarIcons {
  /// The image for a glyph; Stereo shows one frame of its ripple.
  static func image(for glyph: MenuBarGlyph, waveFrame: Int) -> NSImage? {
    switch glyph {
    case .mono(.left): monoLeft
    case .mono(.right): monoRight
    case .stereo: stereoFrames[min(max(waveFrame, 0), StereoRipple.restingFrame)]
    case .idle: idle
    case .attention: attention
    }
  }

  /// The bundled asset, or a system symbol when the app runs unbundled.
  private static let idle: NSImage? = {
    if let image = NSImage(named: "MenuBarIcon") {
      image.isTemplate = true
      return image
    }
    return NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
  }()
  private static let monoLeft = ringsIcon(leftFilled: true, rightFilled: false)
  private static let monoRight = ringsIcon(leftFilled: false, rightFilled: true)
  /// One template image per ripple frame; the last one is the still Stereo icon.
  private static let stereoFrames = (0..<StereoRipple.frameCount).map { frame in
    stereoIcon(frame: frame)
  }
  /// Keep the warning in the same template image as the rings.
  private static let attention: NSImage = {
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
}
