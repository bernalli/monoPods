#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RenderFailure: Error { case invalid, output }
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: colorSpace,
    components: [
      CGFloat((hex >> 16) & 255) / 255,
      CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha,
    ])!
}
func context(_ pixels: Int, grid: CGFloat) throws -> CGContext {
  guard
    let ctx = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw RenderFailure.invalid }
  ctx.translateBy(x: 0, y: CGFloat(pixels))
  ctx.scaleBy(x: CGFloat(pixels) / grid, y: -CGFloat(pixels) / grid)
  return ctx
}
func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> CGRect {
  CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
}
func icon(_ pixels: Int) throws -> CGImage {
  let ctx = try context(pixels, grid: 1024)
  ctx.addPath(
    CGPath(
      roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185,
      cornerHeight: 185, transform: nil))
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: colorSpace, colors: [color(0x12586B), color(0x0B2A3C)] as CFArray,
    locations: [0, 1])!
  ctx.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
  let left = circle(424, 512, 214)
  let right = circle(600, 512, 214)
  ctx.setFillColor(color(0x7FD3FF, alpha: 0.92))
  ctx.fillEllipse(in: left)
  ctx.setFillColor(color(0xFF9F7A, alpha: 0.92))
  ctx.fillEllipse(in: right)
  ctx.addEllipse(in: left)
  ctx.clip()
  ctx.setFillColor(color(0xFFF4E8))
  ctx.fillEllipse(in: right)
  guard let image = ctx.makeImage() else { throw RenderFailure.invalid }
  return image
}
func menu(_ scale: Int) throws -> CGImage {
  let ctx = try context(18 * scale, grid: 36)
  let left = circle(13.5, 18, 9.5)
  let right = circle(22.5, 18, 9.5)
  ctx.setStrokeColor(color(0))
  ctx.setLineWidth(2.2)
  ctx.strokeEllipse(in: left)
  ctx.strokeEllipse(in: right)
  ctx.addEllipse(in: left)
  ctx.clip()
  ctx.setFillColor(color(0))
  ctx.fillEllipse(in: right)
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
func bigEndian(_ bytes: ArraySlice<UInt8>) -> Int {
  bytes.reduce(0) { $0 << 8 | Int($1) }
}
func bigEndianBytes(_ value: Int) -> [UInt8] {
  [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }
}
func withoutMetadata(_ png: [UInt8]) throws -> [UInt8] {
  guard png.starts(with: pngSignature) else { throw RenderFailure.output }
  var output = pngSignature
  var cursor = pngSignature.count
  while cursor < png.count {
    guard cursor + 12 <= png.count else { throw RenderFailure.output }
    let end = cursor + 12 + bigEndian(png[cursor..<cursor + 4])
    guard end <= png.count, let kind = String(bytes: png[cursor + 4..<cursor + 8], encoding: .ascii)
    else { throw RenderFailure.output }
    if keptChunks.contains(kind) { output += png[cursor..<end] }
    cursor = end
  }
  return output
}
/// Rebuilds an icns file with metadata-free PNG elements and a table of contents that matches them.
func icnsWithoutMetadata(_ icns: [UInt8]) throws -> [UInt8] {
  guard icns.count >= 8, icns.starts(with: Array("icns".utf8)),
    bigEndian(icns[4..<8]) == icns.count
  else { throw RenderFailure.output }
  var elements: [(kind: [UInt8], body: [UInt8])] = []
  var cursor = 8
  while cursor < icns.count {
    guard cursor + 8 <= icns.count else { throw RenderFailure.output }
    let end = cursor + bigEndian(icns[cursor + 4..<cursor + 8])
    guard end >= cursor + 8, end <= icns.count else { throw RenderFailure.output }
    let body = Array(icns[cursor + 8..<end])
    elements.append(
      (
        Array(icns[cursor..<cursor + 4]),
        body.starts(with: pngSignature) ? try withoutMetadata(body) : body
      ))
    cursor = end
  }
  let contents = Array("TOC ".utf8)
  let table = elements.filter { $0.kind != contents }.flatMap {
    $0.kind + bigEndianBytes($0.body.count + 8)
  }
  let body = elements.flatMap { element -> [UInt8] in
    let data = element.kind == contents ? table : element.body
    return element.kind + bigEndianBytes(data.count + 8) + data
  }
  return Array("icns".utf8) + bigEndianBytes(body.count + 8) + body
}
func save(_ bytes: [UInt8], to url: URL) throws {
  guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
    throw RenderFailure.output
  }
  try Data(bytes).write(to: url)
}
func png(_ image: CGImage, at url: URL, scale: Int) throws {
  let data = NSMutableData()
  guard
    let dest = CGImageDestinationCreateWithData(
      data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
  else { throw RenderFailure.output }
  CGImageDestinationAddImage(
    dest, image,
    [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { throw RenderFailure.output }
  try save(withoutMetadata([UInt8](data as Data)), to: url)
}
func render() throws {
  guard CommandLine.arguments.count == 2 else { throw RenderFailure.invalid }
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .resolvingSymlinksInPath()
  let out = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
  guard out.deletingLastPathComponent() == root, out.lastPathComponent == "Assets",
    (try? out.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
  else { throw RenderFailure.output }
  let set = out.appendingPathComponent("AppIcon.iconset")
  guard (try? set.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
    throw RenderFailure.output
  }
  try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
  let sizes = [16, 32, 128, 256, 512].flatMap { points in [1, 2].map { (points, $0) } }
  let icnsURL = out.appendingPathComponent("AppIcon.icns")
  guard (try? icnsURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
    throw RenderFailure.output
  }
  let icnsData = NSMutableData()
  guard
    let icns = CGImageDestinationCreateWithData(
      icnsData as CFMutableData, "com.apple.icns" as CFString, sizes.count, nil)
  else { throw RenderFailure.output }
  for (points, scale) in sizes {
    let image = try icon(points * scale)
    let suffix = scale == 2 ? "@2x" : ""
    let url = set.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw RenderFailure.output
    }
    try png(image, at: url, scale: scale)
    CGImageDestinationAddImage(
      icns, image,
      [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
  }
  guard CGImageDestinationFinalize(icns) else { throw RenderFailure.output }
  try save(icnsWithoutMetadata([UInt8](icnsData as Data)), to: icnsURL)
  for scale in [1, 2] {
    let url = out.appendingPathComponent(scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@2x.png")
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw RenderFailure.output
    }
    try png(menu(scale), at: url, scale: scale)
  }
}
do { try render() } catch {
  FileHandle.standardError.write(Data("Icon rendering failed\n".utf8))
  exit(1)
}
