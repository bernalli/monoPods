#!/usr/bin/env swift  // Renders the repository artwork into docs/images: the GitHub social preview, the README banner
// and the "how it works" figure. Run from the repository root:
//   swift scripts/make-artwork.swift docs/images
// The geometry and colours of the icon match scripts/make-icon.swift; the menu bar glyphs match
// MonoPodsApp.ringsIcon. The MonoPods wordmark uses the bundled Plus Jakarta Sans SemiBold,
// registered only for this process. All other text uses the system font (SF Pro).
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RenderFailure: Error { case invalid, output, font }
let wordmarkPostScriptName = "PlusJakartaSans-SemiBold"
// render() requires the repository root as the working directory.
let wordmarkFontURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  .appendingPathComponent("Assets/Fonts/PlusJakartaSans-SemiBold.ttf")

func registerWordmarkFont(at url: URL) throws {
  guard
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
      as? [CTFontDescriptor],
    descriptors.count == 1, let descriptor = descriptors.first,
    CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
      == wordmarkPostScriptName,
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  else { throw RenderFailure.font }
}

func wordmarkFont(size: CGFloat) throws -> NSFont {
  guard let font = NSFont(name: wordmarkPostScriptName, size: size),
    font.fontName == wordmarkPostScriptName,
    let source = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
    source.resolvingSymlinksInPath().path == wordmarkFontURL.resolvingSymlinksInPath().path
  else { throw RenderFailure.font }
  return font
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: colorSpace,
    components: [
      CGFloat((hex >> 16) & 255) / 255,
      CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha,
    ])!
}

enum Palette {
  static let lagoonTop: UInt32 = 0x12586B
  static let lagoonBottom: UInt32 = 0x0B2A3C
  static let left: UInt32 = 0x7FD3FF
  static let right: UInt32 = 0xFF9F7A
  static let mono: UInt32 = 0xFFF4E8
}

/// An opaque, top-left origin context: y grows downwards, as in the icon renderer.
func canvas(width: Int, height: Int) throws -> CGContext {
  guard
    let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw RenderFailure.invalid }
  ctx.translateBy(x: 0, y: CGFloat(height))
  ctx.scaleBy(x: 1, y: -1)
  ctx.setShouldAntialias(true)
  ctx.interpolationQuality = .high
  return ctx
}
func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> CGRect {
  CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
}
func lagoon() -> CGGradient {
  CGGradient(
    colorsSpace: colorSpace,
    colors: [color(Palette.lagoonTop), color(Palette.lagoonBottom)] as CFArray,
    locations: [0, 1])!
}

/// Full-bleed lagoon background with a faint light from the top left, so large areas are not flat.
func background(_ ctx: CGContext, width: CGFloat, height: CGFloat) {
  ctx.drawLinearGradient(
    lagoon(), start: .zero, end: CGPoint(x: 0, y: height), options: [])
  let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(Palette.left, alpha: 0.10), color(Palette.left, alpha: 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: width * 0.22, y: height * 0.12), startRadius: 0,
    endCenter: CGPoint(x: width * 0.22, y: height * 0.12), endRadius: max(width, height) * 0.7,
    options: [])
}

/// The two discs of icon H in the 1024 grid, drawn in any target rectangle of that grid.
func discs(_ ctx: CGContext, center: CGPoint, scale: CGFloat) {
  let left = circle(center.x - 88 * scale, center.y, 214 * scale)
  let right = circle(center.x + 88 * scale, center.y, 214 * scale)
  ctx.saveGState()
  ctx.setFillColor(color(Palette.left, alpha: 0.92))
  ctx.fillEllipse(in: left)
  ctx.setFillColor(color(Palette.right, alpha: 0.92))
  ctx.fillEllipse(in: right)
  ctx.addEllipse(in: left)
  ctx.clip()
  ctx.setFillColor(color(Palette.mono))
  ctx.fillEllipse(in: right)
  ctx.restoreGState()
}

/// The app icon: squircle body of side `side` (824 in the icon grid) with its top-left at `origin`.
func appIcon(_ ctx: CGContext, origin: CGPoint, side: CGFloat) {
  let scale = side / 824
  let body = CGRect(origin: origin, size: CGSize(width: side, height: side))
  let shape = CGPath(
    roundedRect: body, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
  ctx.saveGState()
  ctx.setShadow(
    offset: CGSize(width: 0, height: -side * 0.035), blur: side * 0.12,
    color: color(0x000000, alpha: 0.45))
  ctx.addPath(shape)
  ctx.setFillColor(color(Palette.lagoonBottom))
  ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(shape)
  ctx.clip()
  ctx.drawLinearGradient(
    lagoon(), start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
  discs(ctx, center: CGPoint(x: body.midX, y: body.midY), scale: scale)
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(shape)
  ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.14))
  ctx.setLineWidth(max(1.5, side * 0.004))
  ctx.strokePath()
  ctx.restoreGState()
}

/// The menu bar glyph of MonoPodsApp.ringsIcon, in its 18 pt canvas scaled by `scale`.
func glyph(
  _ ctx: CGContext, origin: CGPoint, scale: CGFloat, leftFilled: Bool, rightFilled: Bool,
  ink: CGColor
) {
  let radius: CGFloat = 4.75
  let lineWidth: CGFloat = 1.1
  ctx.saveGState()
  ctx.translateBy(x: origin.x, y: origin.y)
  ctx.scaleBy(x: scale, y: scale)
  ctx.setFillColor(ink)
  ctx.setStrokeColor(ink)
  for (x, filled) in [(CGFloat(6.75), leftFilled), (CGFloat(11.25), rightFilled)] {
    if filled {
      ctx.fillEllipse(in: circle(x, 9, radius + lineWidth / 2))
    } else {
      ctx.setLineWidth(lineWidth)
      ctx.strokeEllipse(in: circle(x, 9, radius))
    }
  }
  ctx.restoreGState()
}

struct Text {
  let line: CTLine
  let width: CGFloat
  let ascent: CGFloat
  let descent: CGFloat
  let capHeight: CGFloat
  /// The ink of the glyphs relative to the pen position, with y growing upwards from the baseline.
  let glyphBounds: CGRect
  init(
    _ string: String, size: CGFloat, weight: NSFont.Weight, ink: CGColor, kern: CGFloat = 0,
    font: NSFont? = nil
  ) {
    let font = font ?? NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
      .kern: kern,
    ]
    line = CTLineCreateWithAttributedString(
      NSAttributedString(string: string, attributes: attributes))
    var a: CGFloat = 0
    var d: CGFloat = 0
    var l: CGFloat = 0
    let typographic = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
    // The trailing kern is not visible ink; leave it out of the measured width.
    width = typographic - kern
    ascent = a
    descent = d
    capHeight = font.capHeight
    glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
  }
  /// Draws with the baseline at `baseline` and the left edge at `x`.
  func draw(_ ctx: CGContext, x: CGFloat, baseline: CGFloat) {
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}

/// The app icon and the title as one group, centred in the canvas both ways. The title is placed
/// by its ink, and its cap height is centred on the icon.
func iconAndTitle(
  _ ctx: CGContext, width: CGFloat, height: CGFloat, side: CGFloat, gap: CGFloat, title: Text
) {
  let groupWidth = side + gap + title.glyphBounds.width
  let x0 = ((width - groupWidth) / 2).rounded()
  let iconTop = ((height - side) / 2).rounded()
  appIcon(ctx, origin: CGPoint(x: x0, y: iconTop), side: side)
  let baseline = iconTop + side / 2 + title.capHeight / 2
  title.draw(ctx, x: x0 + side + gap - title.glyphBounds.minX, baseline: baseline)
}

func socialPreview() throws -> CGImage {
  let width: CGFloat = 1280
  let height: CGFloat = 640
  let ctx = try canvas(width: Int(width), height: Int(height))
  background(ctx, width: width, height: height)
  let title = Text(
    "MonoPods", size: 128, weight: .semibold, ink: color(Palette.mono), kern: -2.5,
    font: try wordmarkFont(size: 128))
  iconAndTitle(ctx, width: width, height: height, side: 330, gap: 64, title: title)
  guard let image = ctx.makeImage() else { throw RenderFailure.invalid }
  return image
}

func banner() throws -> CGImage {
  let width: CGFloat = 1600
  let height: CGFloat = 480
  let ctx = try canvas(width: Int(width), height: Int(height))
  background(ctx, width: width, height: height)
  // Decoration: the two rings of the glyph, large and faint, leaving the frame on the right.
  ctx.saveGState()
  ctx.setLineWidth(2)
  ctx.setStrokeColor(color(Palette.mono, alpha: 0.07))
  ctx.strokeEllipse(in: circle(width - 70, height / 2, 250))
  ctx.strokeEllipse(in: circle(width + 60, height / 2, 250))
  ctx.restoreGState()
  let title = Text(
    "MonoPods", size: 112, weight: .semibold, ink: color(Palette.mono), kern: -2.2,
    font: try wordmarkFont(size: 112))
  iconAndTitle(ctx, width: width, height: height, side: 250, gap: 60, title: title)
  guard let image = ctx.makeImage() else { throw RenderFailure.invalid }
  return image
}

/// One panel of the figure: heading, illustration, menu bar pill with the glyph, title, caption.
struct Panel {
  let heading: String
  let title: String
  let caption: String
  let leftFilled: Bool
  let rightFilled: Bool
  let art: (CGContext, CGPoint) -> Void
}

/// An earbud seat: a filled disc when the earbud is in, a dashed outline when it is out.
func seat(_ ctx: CGContext, center: CGPoint, radius: CGFloat, fill: UInt32?) {
  ctx.saveGState()
  if let fill {
    ctx.setFillColor(color(fill, alpha: fill == Palette.mono ? 1 : 0.92))
    ctx.fillEllipse(in: circle(center.x, center.y, radius))
  } else {
    ctx.setStrokeColor(color(Palette.mono, alpha: 0.45))
    ctx.setLineWidth(3)
    ctx.setLineDash(phase: 0, lengths: [9, 8])
    ctx.strokeEllipse(in: circle(center.x, center.y, radius - 1.5))
  }
  ctx.restoreGState()
}

func seatLabel(_ ctx: CGContext, _ letter: String, center: CGPoint, dark: Bool) {
  let ink = dark ? color(Palette.lagoonBottom, alpha: 0.85) : color(Palette.mono, alpha: 0.55)
  let text = Text(letter, size: 30, weight: .bold, ink: ink)
  text.draw(ctx, x: center.x - text.width / 2, baseline: center.y + text.capHeight / 2)
}

func howItWorks() throws -> CGImage {
  let width: CGFloat = 1600
  let height: CGFloat = 640
  let ctx = try canvas(width: Int(width), height: Int(height))
  background(ctx, width: width, height: height)
  let radius: CGFloat = 62
  let spread: CGFloat = 74
  let panels = [
    Panel(
      heading: "ONE AIRPOD IN", title: "Mono", caption: "Both channels in the ear you wear",
      leftFilled: true, rightFilled: false,
      art: { ctx, c in
        seat(ctx, center: CGPoint(x: c.x - spread, y: c.y), radius: radius, fill: Palette.mono)
        seat(ctx, center: CGPoint(x: c.x + spread, y: c.y), radius: radius, fill: nil)
        seatLabel(ctx, "L", center: CGPoint(x: c.x - spread, y: c.y), dark: true)
        seatLabel(ctx, "R", center: CGPoint(x: c.x + spread, y: c.y), dark: false)
      }),
    Panel(
      heading: "BOTH AIRPODS IN", title: "Stereo", caption: "Left and right, as recorded",
      leftFilled: true, rightFilled: true,
      art: { ctx, c in
        seat(ctx, center: CGPoint(x: c.x - spread, y: c.y), radius: radius, fill: Palette.left)
        seat(ctx, center: CGPoint(x: c.x + spread, y: c.y), radius: radius, fill: Palette.right)
        seatLabel(ctx, "L", center: CGPoint(x: c.x - spread, y: c.y), dark: true)
        seatLabel(ctx, "R", center: CGPoint(x: c.x + spread, y: c.y), dark: true)
      }),
    Panel(
      heading: "ONE OF TWO TAKEN OUT", title: "Sends Play", caption: "When macOS pauses the video",
      leftFilled: true, rightFilled: false,
      art: { ctx, c in
        // A video frame with a play button and a progress bar.
        let frame = CGRect(x: c.x - 120, y: c.y - 68, width: 240, height: 136)
        let shape = CGPath(roundedRect: frame, cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setFillColor(color(0x000000, alpha: 0.22))
        ctx.fillPath()
        ctx.addPath(shape)
        ctx.setStrokeColor(color(Palette.mono, alpha: 0.55))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.setFillColor(color(Palette.mono))
        ctx.fillEllipse(in: circle(c.x, c.y - 8, 34))
        let play = CGMutablePath()
        play.move(to: CGPoint(x: c.x - 9, y: c.y - 26))
        play.addLine(to: CGPoint(x: c.x + 17, y: c.y - 8))
        play.addLine(to: CGPoint(x: c.x - 9, y: c.y + 10))
        play.closeSubpath()
        ctx.addPath(play)
        ctx.setFillColor(color(Palette.lagoonBottom))
        ctx.fillPath()
        let track = CGRect(
          x: frame.minX + 22, y: frame.maxY - 26, width: frame.width - 44, height: 6)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(color(Palette.mono, alpha: 0.25))
        ctx.fillPath()
        let done = CGRect(x: track.minX, y: track.minY, width: track.width * 0.42, height: 6)
        ctx.addPath(CGPath(roundedRect: done, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(color(Palette.right))
        ctx.fillPath()
        ctx.restoreGState()
      }),
  ]
  let margin: CGFloat = 48
  let gutter: CGFloat = 56
  let panelWidth = ((width - 2 * margin - 2 * gutter) / 3).rounded(.down)
  let panelTop: CGFloat = 48
  let panelHeight = height - 2 * panelTop
  for (index, panel) in panels.enumerated() {
    let x = margin + CGFloat(index) * (panelWidth + gutter)
    let card = CGRect(x: x, y: panelTop, width: panelWidth, height: panelHeight)
    let cardShape = CGPath(roundedRect: card, cornerWidth: 32, cornerHeight: 32, transform: nil)
    ctx.saveGState()
    ctx.addPath(cardShape)
    ctx.setFillColor(color(0xFFFFFF, alpha: 0.055))
    ctx.fillPath()
    ctx.addPath(cardShape)
    ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.12))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
    ctx.restoreGState()
    let cx = card.midX
    // Heading.
    let heading = Text(
      panel.heading, size: 19, weight: .semibold, ink: color(Palette.left), kern: 2.6)
    heading.draw(ctx, x: cx - heading.width / 2, baseline: card.minY + 58)
    // Illustration.
    panel.art(ctx, CGPoint(x: cx, y: card.minY + 190))
    // Menu bar pill with the glyph drawn as the app draws it, three times its point size.
    let glyphScale: CGFloat = 3.5
    let pill = CGRect(x: cx - 72, y: card.minY + 296, width: 144, height: 84)
    let pillShape = CGPath(roundedRect: pill, cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState()
    ctx.addPath(pillShape)
    ctx.setFillColor(color(0x000000, alpha: 0.30))
    ctx.fillPath()
    ctx.addPath(pillShape)
    ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.10))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
    ctx.restoreGState()
    glyph(
      ctx, origin: CGPoint(x: cx - 9 * glyphScale, y: pill.midY - 9 * glyphScale),
      scale: glyphScale, leftFilled: panel.leftFilled, rightFilled: panel.rightFilled,
      ink: color(Palette.mono))
    let title = Text(panel.title, size: 44, weight: .bold, ink: color(Palette.mono), kern: -0.6)
    title.draw(ctx, x: cx - title.width / 2, baseline: card.minY + 448)
    let caption = Text(
      panel.caption, size: 22, weight: .regular, ink: color(Palette.mono, alpha: 0.74))
    caption.draw(ctx, x: cx - caption.width / 2, baseline: card.minY + 490)
    // Chevron to the next panel.
    if index < panels.count - 1 {
      let gx = card.maxX + gutter / 2
      let gy = card.minY + 190
      let chevron = CGMutablePath()
      chevron.move(to: CGPoint(x: gx - 6, y: gy - 13))
      chevron.addLine(to: CGPoint(x: gx + 7, y: gy))
      chevron.addLine(to: CGPoint(x: gx - 6, y: gy + 13))
      ctx.saveGState()
      ctx.addPath(chevron)
      ctx.setStrokeColor(color(Palette.mono, alpha: 0.45))
      ctx.setLineWidth(4)
      ctx.setLineCap(.round)
      ctx.setLineJoin(.round)
      ctx.strokePath()
      ctx.restoreGState()
    }
  }
  guard let image = ctx.makeImage() else { throw RenderFailure.invalid }
  return image
}

/// Chunks kept in every PNG. ImageIO always adds an eXIf chunk, and the release scanner refuses
/// metadata. iDOT is dropped as well: it records IDAT offsets, which removing a chunk invalidates.
let keptChunks: Set<String> = [
  "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "pHYs", "bKGD",
  "cICP",
]
let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
func withoutMetadata(_ png: [UInt8]) throws -> [UInt8] {
  guard png.starts(with: pngSignature) else { throw RenderFailure.output }
  var output = pngSignature
  var cursor = pngSignature.count
  while cursor < png.count {
    guard cursor + 12 <= png.count else { throw RenderFailure.output }
    let length = png[cursor..<cursor + 4].reduce(0) { $0 << 8 | Int($1) }
    let end = cursor + 12 + length
    guard end <= png.count, let kind = String(bytes: png[cursor + 4..<cursor + 8], encoding: .ascii)
    else { throw RenderFailure.output }
    if keptChunks.contains(kind) { output += png[cursor..<end] }
    cursor = end
  }
  return output
}

func png(_ image: CGImage, at url: URL) throws {
  let data = NSMutableData()
  guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
    let dest = CGImageDestinationCreateWithData(
      data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
  else { throw RenderFailure.output }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { throw RenderFailure.output }
  try Data(withoutMetadata([UInt8](data as Data))).write(to: url)
}

func render() throws {
  guard CommandLine.arguments.count == 2 else { throw RenderFailure.invalid }
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .resolvingSymlinksInPath()
  let out = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
  let docs = out.deletingLastPathComponent()
  guard docs.deletingLastPathComponent() == root, docs.lastPathComponent == "docs",
    out.lastPathComponent == "images",
    (try? docs.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
    (try? out.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
  else { throw RenderFailure.output }
  try registerWordmarkFont(at: wordmarkFontURL)
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  try png(socialPreview(), at: out.appendingPathComponent("social-preview.png"))
  try png(banner(), at: out.appendingPathComponent("banner.png"))
  try png(howItWorks(), at: out.appendingPathComponent("how-it-works.png"))
}
do { try render() } catch {
  FileHandle.standardError.write(Data("Artwork rendering failed: \(error)\n".utf8))
  exit(1)
}
