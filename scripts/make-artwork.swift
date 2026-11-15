#!/usr/bin/env swift  // Renders the repository artwork into docs/images: the README cover
// and the GitHub social preview, both from cover design D (1280 x 640 CSS px). Run from the
// repository root:
//   swift scripts/make-artwork.swift docs/images
// The cover is the design at 2x (2560 x 1280); the social preview is the design at 1x. All text
// uses the bundled Plus Jakarta Sans SemiBold, registered only for this process.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RenderFailure: Error { case invalid, output, font, icon }
let wordmarkPostScriptName = "PlusJakartaSans-SemiBold"
// render() requires the repository root as the working directory.
let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let wordmarkFontURL = repositoryRoot.appendingPathComponent(
  "Assets/Fonts/PlusJakartaSans-SemiBold.ttf")
let appIconURL = repositoryRoot.appendingPathComponent(
  "Assets/AppIcon.iconset/icon_512x512@2x.png")

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

/// An opaque, top-left origin context: y grows downwards, as in CSS.
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

/// Cover design D in CSS px: one row, a 360 px icon column and the text column, centred
/// vertically on a 1280 x 640 canvas.
enum CoverD {
  static let width: CGFloat = 1280
  static let height: CGFloat = 640
  static let background: UInt32 = 0xFBF3E8
  static let ink: UInt32 = 0x0E2A3D
  static let padding: CGFloat = 96
  static let iconColumn: CGFloat = 360
  static let columnGap: CGFloat = 72
  static let iconSide: CGFloat = 380
  static let iconMarginLeft: CGFloat = -18
  static let shadowOffset: CGFloat = 30
  static let shadowBlur: CGFloat = 40
  static let shadowAlpha: CGFloat = 0.25
  static let blockGap: CGFloat = 24
  static let secondaryAlpha: CGFloat = 0.68
}

/// A block of text as CSS lays it out: lines of `lineHeight` times the font size, each with its
/// half-leading above the ascent; lines wrap at word boundaries within `width`.
struct TextBlock {
  let lines: [CTLine]
  let font: NSFont
  let lineHeight: CGFloat
  init(
    _ paragraphs: [String], font: NSFont, lineHeight: CGFloat, kern: CGFloat = 0, ink: CGColor,
    width: CGFloat
  ) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
      .kern: kern,
    ]
    var lines: [CTLine] = []
    for paragraph in paragraphs {
      let text = NSAttributedString(string: paragraph, attributes: attributes)
      let typesetter = CTTypesetterCreateWithAttributedString(text)
      var start = 0
      while start < text.length {
        let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
        lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
        start += count
      }
    }
    self.lines = lines
    self.font = font
    self.lineHeight = font.pointSize * lineHeight
  }
  var height: CGFloat { CGFloat(lines.count) * lineHeight }
  func draw(_ ctx: CGContext, x: CGFloat, top: CGFloat) {
    let halfLeading = (lineHeight - (font.ascender - font.descender)) / 2
    for (index, line) in lines.enumerated() {
      ctx.saveGState()
      ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      ctx.textPosition = CGPoint(
        x: x, y: top + CGFloat(index) * lineHeight + halfLeading + font.ascender)
      CTLineDraw(line, ctx)
      ctx.restoreGState()
    }
  }
}

/// Draws cover design D with every CSS length multiplied by `scale`.
func coverD(scale: CGFloat) throws -> CGImage {
  let width = CoverD.width * scale
  let height = CoverD.height * scale
  let ctx = try canvas(width: Int(width), height: Int(height))
  ctx.setFillColor(color(CoverD.background))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

  // Column 1: the app icon with its drop shadow, centred in the row.
  guard let source = CGImageSourceCreateWithURL(appIconURL as CFURL, nil),
    let icon = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { throw RenderFailure.icon }
  let side = CoverD.iconSide * scale
  let iconRect = CGRect(
    x: (CoverD.padding + CoverD.iconMarginLeft) * scale, y: (height - side) / 2,
    width: side, height: side)
  ctx.saveGState()
  // Shadow offsets are in device space, where y grows upwards: a negative height moves it down.
  ctx.setShadow(
    offset: CGSize(width: 0, height: -CoverD.shadowOffset * scale),
    blur: CoverD.shadowBlur * scale, color: color(CoverD.ink, alpha: CoverD.shadowAlpha))
  // The context is flipped; flip back locally so the image is not drawn upside down.
  ctx.translateBy(x: iconRect.minX, y: iconRect.maxY)
  ctx.scaleBy(x: 1, y: -1)
  ctx.draw(icon, in: CGRect(origin: .zero, size: iconRect.size))
  ctx.restoreGState()

  // Column 2: title, tagline and description, 24 px apart, centred in the row as one block.
  let columnX = (CoverD.padding + CoverD.iconColumn + CoverD.columnGap) * scale
  let columnWidth = width - CoverD.padding * scale - columnX
  let ink = color(CoverD.ink)
  let blocks = [
    TextBlock(
      ["MonoPods"], font: try wordmarkFont(size: 120 * scale), lineHeight: 0.95,
      kern: -3 * scale, ink: ink, width: columnWidth),
    TextBlock(
      ["Mono with one AirPod.", "Stereo with two."], font: try wordmarkFont(size: 36 * scale),
      lineHeight: 1.25, ink: ink, width: columnWidth),
    // The design asks for weight 500; the repository has only SemiBold (600).
    TextBlock(
      [
        "A small menu bar app that changes your Mac's audio for you, as soon as you put an AirPod in or take it out."
      ], font: try wordmarkFont(size: 22 * scale), lineHeight: 1.45,
      ink: color(CoverD.ink, alpha: CoverD.secondaryAlpha), width: columnWidth),
  ]
  let gap = CoverD.blockGap * scale
  let total = blocks.reduce(0) { $0 + $1.height } + gap * CGFloat(blocks.count - 1)
  var top = (height - total) / 2
  for block in blocks {
    block.draw(ctx, x: columnX, top: top)
    top += block.height + gap
  }
  guard let image = ctx.makeImage() else { throw RenderFailure.invalid }
  return image
}

func socialPreview() throws -> CGImage { try coverD(scale: 1) }

func banner() throws -> CGImage { try coverD(scale: 2) }

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
  let root = repositoryRoot.resolvingSymlinksInPath()
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
}
do { try render() } catch {
  FileHandle.standardError.write(Data("Artwork rendering failed: \(error)\n".utf8))
  exit(1)
}
