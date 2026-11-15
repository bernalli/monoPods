import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MonoPodsRuntime

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

/// Draws a view off screen with the given appearance, on a transparent bitmap.
@MainActor private func render<V: View>(_ view: V, appearance name: NSAppearance.Name) throws
  -> NSBitmapImageRep
{
  let hosting = NSHostingView(rootView: view)
  let appearance = try #require(NSAppearance(named: name))
  hosting.appearance = appearance
  hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
  hosting.layoutSubtreeIfNeeded()
  let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
  appearance.performAsCurrentDrawingAppearance {
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
  }
  return bitmap
}

private func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
  bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1
}

@MainActor @Test func theCoffeeButtonIsDrawnAsALowContrastCapsule() throws {
  let button = Button {
  } label: {
    Label(AboutText.sponsor, systemImage: "cup.and.saucer.fill")
  }
  .buttonStyle(CoffeeButtonStyle())
  for name in appearances {
    let bitmap = try render(button, appearance: name)
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    let scale = CGFloat(width) / bitmap.size.width
    #expect(width > height && height > 0, "\(name.rawValue)")
    // A capsule leaves the four corners of its frame empty.
    for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
      #expect(alpha(bitmap, x, y) == 0, "\(name.rawValue) corner \(x),\(y)")
    }
    // The border reaches the middle of the left and right edges.
    #expect(alpha(bitmap, 0, height / 2) > 0, "\(name.rawValue) left edge")
    #expect(alpha(bitmap, width - 1, height / 2) > 0, "\(name.rawValue) right edge")
    // Inside the border and before the label: only the faint background.
    let inside = Int((4 * scale).rounded())
    let fill = try #require(bitmap.colorAt(x: inside, y: height / 2)?.usingColorSpace(.sRGB))
    #expect(fill.alphaComponent >= 0.02 && fill.alphaComponent <= 0.08, "\(name.rawValue) fill")
    // The fill is the primary colour: dark in light mode, light in dark mode.
    if name == .aqua {
      #expect(fill.brightnessComponent < 0.5, "light fill")
    } else {
      #expect(fill.brightnessComponent > 0.5, "dark fill")
    }
  }
}

/// Renders the whole About view in light and dark mode. With `MONOPODS_ABOUT_RENDER_DIR` set, it
/// also writes `about-light.png` and `about-dark.png` there, for a person to look at.
@MainActor @Test func theAboutViewRendersInLightAndDarkMode() throws {
  // The real Info.plist and, as `scripts/bundle-info.py` adds it, the copyright line of LICENSE.
  let plist = try #require(
    NSDictionary(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
      as? [String: Any])
  let license = try String(
    contentsOf: repositoryRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
  let copyright = try #require(
    license.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("Copyright ") })
  let information = AppInformation(
    infoDictionary: plist.merging([
      "CFBundleShortVersionString": "1.1.0", "NSHumanReadableCopyright": copyright,
    ]) { $1 })
  #expect(information.copyright != nil)
  let icon = try #require(
    NSImage(contentsOf: repositoryRoot.appendingPathComponent("Assets/AppIcon.icns")))
  let mark = try #require(
    AboutArtwork.templateImage(
      contentsOf: repositoryRoot.appendingPathComponent("Assets/GitHubMark.pdf")))
  let controller = AboutWindowController(
    information: information, icon: icon, gitHubMark: mark,
    titleFontURL: repositoryRoot.appendingPathComponent(
      "Assets/Fonts/PlusJakartaSans-SemiBold.ttf"),
    open: { _ in }, activate: {})
  let hosting = try #require(controller.window.contentView as? NSHostingView<AboutView>)
  let directory = ProcessInfo.processInfo.environment["MONOPODS_ABOUT_RENDER_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
  }
  if let directory {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  for (name, file) in [(NSAppearance.Name.aqua, "about-light"), (.darkAqua, "about-dark")] {
    let content = try render(hosting.rootView, appearance: name)
    #expect(content.size.width == 280 && content.pixelsHigh > 0)
    let image = try onWindowBackground(content, appearance: name)
    guard let directory else { continue }
    let data = try #require(image.representation(using: .png, properties: [:]))
    try data.write(to: directory.appendingPathComponent("\(file).png"))
  }
}

/// Puts a transparent rendering on the window background colour of the given appearance.
@MainActor private func onWindowBackground(
  _ content: NSBitmapImageRep, appearance name: NSAppearance.Name
) throws -> NSBitmapImageRep {
  let appearance = try #require(NSAppearance(named: name))
  let image = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: content.pixelsWide, pixelsHigh: content.pixelsHigh,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  image.size = content.size
  let context = try #require(NSGraphicsContext(bitmapImageRep: image))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  let bounds = NSRect(origin: .zero, size: content.size)
  appearance.performAsCurrentDrawingAppearance {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
  }
  content.draw(
    in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  NSGraphicsContext.restoreGraphicsState()
  return image
}
