import Foundation

/// The ring that leaves the Stereo discs once when the glyph turns Stereo, then the icon stays still.
///
/// The icon has `frameCount` precomputed frames. They run from 0 to `restingFrame` once, one step
/// every `frameIntervalNanos` (12 frames per second), and the last frame stays drawn while Stereo
/// lasts. The ring fades out before the run ends, and nothing animates after that.
public enum StereoRipple {
  public static let frameCount = 19
  public static let restingFrame = frameCount - 1
  public static let frameIntervalNanos: UInt64 = 83_333_333

  /// The ring of one frame.
  public struct Ring: Equatable {
    /// How far the ring has moved from the discs to its final size: 0 at the start, near 1 at the end.
    public let growth: Double
    /// The alpha of the ring's stroke.
    public let opacity: Double
  }

  private static let ringLifeSeconds = 1.3
  private static let nanosPerSecond = 1e9
  /// The ring starts fast and lands softly.
  private static let growthExponent = 2.4
  private static let peakOpacity = 0.9
  /// The share of the ring's life spent fading in, while it leaves the discs.
  private static let fadeInShare = 0.15
  private static let fadeOutExponent = 1.4

  /// The ring in `frame`, or nil when that frame draws none: outside the run, on the resting frame,
  /// and on the frames after the ring's life ends.
  public static func ring(frame: Int) -> Ring? {
    guard frame >= 0, frame < restingFrame else { return nil }
    let elapsedSeconds = Double(frame) * Double(frameIntervalNanos) / nanosPerSecond
    let progress = elapsedSeconds / ringLifeSeconds
    guard progress < 1 else { return nil }
    let fadeIn = min(progress / fadeInShare, 1)
    let rise = fadeIn * fadeIn * (3 - 2 * fadeIn)
    return Ring(
      growth: 1 - pow(1 - progress, growthExponent),
      opacity: peakOpacity * rise * pow(1 - progress, fadeOutExponent))
  }
}
