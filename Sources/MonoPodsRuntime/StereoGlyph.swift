import CoreGraphics
import MonoPodsCore

/// Ring geometry of the MenuBarIcon asset, in points of an 18 x 18 pt canvas. Measured from
/// Assets/MenuBarIcon@2x.png (36 x 36 px) by fitting two stroked rings plus their filled overlap
/// to the alpha channel: centres at 13.5 and 22.5 px, y 18 px, stroke centre radius 9.5 px,
/// stroke width about 2.2 px; halved to points.
public enum RingGeometry {
  public static let canvas = CGSize(width: 18, height: 18)
  public static let leftCentre = CGPoint(x: 6.75, y: 9)
  public static let rightCentre = CGPoint(x: 11.25, y: 9)
  public static let radius: CGFloat = 4.75
  public static let lineWidth: CGFloat = 1.1
  /// The outer edge of a ring's stroke, which is also the radius of a filled disc.
  public static var outerRadius: CGFloat { radius + lineWidth / 2 }
}

/// Draws one frame of the Stereo icon: the expanding ring of `StereoRipple`, when the frame has one,
/// under the still icon. Coordinates are points with the origin at the bottom left; the caller sets
/// the scale. The colour is black with alpha, for a template image.
public enum StereoGlyph {
  static let ringLineWidth: CGFloat = 0.9
  /// How far the ring's centre line moves at the ends and above and below at full growth. The free
  /// space differs, so the pill around the discs ends as a circle centred on the canvas.
  private static let ringGrowthX: CGFloat = 0.95
  private static let ringGrowthY: CGFloat = 3.2
  /// The alpha of the discs outside the lens where they overlap.
  private static let discFillAlpha: CGFloat = 0.5

  /// The bounds of the ring's centre line at `growth`. At growth 0 they are the bounds of the pair of
  /// discs.
  static func ringRect(growth: Double) -> CGRect {
    let halfWidth =
      (RingGeometry.rightCentre.x - RingGeometry.leftCentre.x) / 2 + RingGeometry.outerRadius
      + ringGrowthX * growth
    let halfHeight = RingGeometry.outerRadius + ringGrowthY * growth
    return CGRect(
      x: (RingGeometry.leftCentre.x + RingGeometry.rightCentre.x) / 2 - halfWidth,
      y: RingGeometry.leftCentre.y - halfHeight, width: 2 * halfWidth, height: 2 * halfHeight)
  }

  public static func draw(frame: Int, in context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }
    if let ring = StereoRipple.ring(frame: frame) { drawRing(ring, in: context) }
    drawStillIcon(in: context)
  }

  private static func drawRing(_ ring: StereoRipple.Ring, in context: CGContext) {
    let rect = ringRect(growth: ring.growth)
    // Half circles at the ends while the ring is a pill; the same corner gives a circle once the
    // height has caught up with the width.
    let corner = min(rect.width, rect.height) / 2
    context.saveGState()
    context.setStrokeColor(black(alpha: ring.opacity))
    context.setLineWidth(ringLineWidth)
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.strokePath()
    context.restoreGState()
  }

  private static func drawStillIcon(in context: CGContext) {
    let discs = [RingGeometry.leftCentre, RingGeometry.rightCentre].map {
      circle(centre: $0, radius: RingGeometry.outerRadius)
    }
    // The union is filled once, with one path and the nonzero rule, so the overlap does not
    // composite twice.
    context.setFillColor(black(alpha: discFillAlpha))
    for disc in discs { context.addEllipse(in: disc) }
    context.fillPath(using: .winding)
    // The lens.
    context.saveGState()
    context.addEllipse(in: discs[0])
    context.clip()
    context.setFillColor(black(alpha: 1))
    context.fillEllipse(in: discs[1])
    context.restoreGState()
    // The strokes go last, so the outline stays crisp over the fill.
    context.setStrokeColor(black(alpha: 1))
    context.setLineWidth(RingGeometry.lineWidth)
    for centre in [RingGeometry.leftCentre, RingGeometry.rightCentre] {
      context.strokeEllipse(in: circle(centre: centre, radius: RingGeometry.radius))
    }
  }

  private static func circle(centre: CGPoint, radius: CGFloat) -> CGRect {
    CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
  }

  private static func black(alpha: CGFloat) -> CGColor {
    CGColor(gray: 0, alpha: alpha)
  }
}
