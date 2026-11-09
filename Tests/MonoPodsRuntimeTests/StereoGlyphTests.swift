import CoreGraphics
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

/// The alpha channel of one Stereo frame drawn at 2x: 36 x 36 pixels for the 18 x 18 pt canvas.
private struct GlyphBitmap {
  static let side = 36
  let alpha: [UInt8]

  init(frame: Int) throws {
    let context = try #require(
      CGContext(
        data: nil, width: Self.side, height: Self.side, bitsPerComponent: 8,
        bytesPerRow: Self.side, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue))
    context.scaleBy(x: 2, y: 2)
    StereoGlyph.draw(frame: frame, in: context)
    let data = try #require(context.data)
    #expect(context.bytesPerRow == Self.side)
    alpha = Array(
      UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self), count: Self.side * Self.side))
  }

  /// The pixel that holds a point, origin bottom left. Memory row 0 is the top row of the canvas.
  func alpha(x: Double, y: Double) -> UInt8 {
    let column = Int((x * 2).rounded(.down))
    let row = Self.side - 1 - Int((y * 2).rounded(.down))
    return alpha[row * Self.side + column]
  }
}

@Test func restingFrameHasAFullLens() throws {
  #expect(try GlyphBitmap(frame: StereoRipple.restingFrame).alpha(x: 9, y: 9) == 255)
}

/// On the line y = 9 the left circle's stroke spans x 1.45...2.55 and the lens starts at 5.95, so
/// x 3.4 lies on the left disc alone; x 14.6 is its mirror image on the right disc.
@Test(arguments: [3.4, 14.6]) func restingFrameFillsEachDiscAtHalfAlpha(x: Double) throws {
  let alpha = try GlyphBitmap(frame: StereoRipple.restingFrame).alpha(x: x, y: 9)
  #expect((127...129).contains(alpha))
}

@Test func restingFrameStrokesTheCirclesAtFullAlpha() throws {
  #expect(try GlyphBitmap(frame: StereoRipple.restingFrame).alpha(x: 2, y: 9) == 255)
}

/// At x = 9 the discs end at y 13.8, and the resting frame has no ring to reach y 16.5.
@Test func restingFrameLeavesTheCornersAndTheTopEmpty() throws {
  let bitmap = try GlyphBitmap(frame: StereoRipple.restingFrame)
  #expect(bitmap.alpha(x: 0.1, y: 0.1) == 0)
  #expect(bitmap.alpha(x: 17.9, y: 17.9) == 0)
  #expect(bitmap.alpha(x: 9, y: 16.5) == 0)
}

/// Frame 4 has a half height of about 6.93 pt and a half width of about 8.03 pt, so at x = 9 the
/// top of the ring is straight and its 0.9 pt stroke spans y 15.48...16.38. The pixel that holds
/// y 15.93 spans 15.5...16 pt, wholly inside the stroke, so its alpha is the ring's opacity.
@Test func ringFrameDrawsTheRingAboveTheDiscsAtItsOpacity() throws {
  let ring = try #require(StereoRipple.ring(frame: 4))
  let top = 9 + 5.3 + 3.2 * ring.growth
  let alpha = try GlyphBitmap(frame: 4).alpha(x: 9, y: top)
  #expect(alpha > 0)
  #expect(abs(Double(alpha) - ring.opacity * 255) <= 2)
}

/// The pixel that holds y 14.8 spans 14.5...15 pt: above the discs (13.8) and below the stroke.
@Test func ringFrameLeavesTheGapBetweenTheDiscsAndTheRingEmpty() throws {
  #expect(try GlyphBitmap(frame: 4).alpha(x: 9, y: 14.8) == 0)
}

@Test func ringFrameKeepsTheStillIconUnderneath() throws {
  let bitmap = try GlyphBitmap(frame: 4)
  #expect(bitmap.alpha(x: 9, y: 9) == 255)
  #expect((127...129).contains(bitmap.alpha(x: 3.4, y: 9)))
  #expect(bitmap.alpha(x: 2, y: 9) == 255)
}

@Test func theFrameAfterTheRingFadesEqualsTheRestingFrameByteForByte() throws {
  let resting = try GlyphBitmap(frame: StereoRipple.restingFrame).alpha
  #expect(try GlyphBitmap(frame: 16).alpha == resting)
}

@Test func theRingsOwnBoundsFollowTheApprovedGeometry() throws {
  let ring = try #require(StereoRipple.ring(frame: 4))
  let rect = StereoGlyph.ringRect(growth: ring.growth)
  #expect(abs(rect.width / 2 - (7.55 + 0.95 * ring.growth)) < 1e-9)
  #expect(abs(rect.height / 2 - (5.3 + 3.2 * ring.growth)) < 1e-9)
  #expect(abs(rect.midX - 9) < 1e-9 && abs(rect.midY - 9) < 1e-9)
}

@Test func everyRingFitsTheCanvas() throws {
  let canvas = CGRect(origin: .zero, size: RingGeometry.canvas)
  let strokeMargin = -StereoGlyph.ringLineWidth / 2
  for frame in 0...15 {
    let ring = try #require(StereoRipple.ring(frame: frame))
    let outer = StereoGlyph.ringRect(growth: ring.growth).insetBy(
      dx: strokeMargin, dy: strokeMargin)
    #expect(canvas.contains(outer))
    #expect(5.3 + 3.2 * ring.growth + 0.9 / 2 <= 9)
  }
}
