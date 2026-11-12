import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing

@testable import MonoPodsRuntime

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
private let gitHubMark = repositoryRoot.appendingPathComponent("Assets/GitHubMark.pdf")

@Test func bundledGitHubMarkIsTheUnmodifiedOfficialAsset() throws {
  // SHA-256 of GitHub_Invertocat_Black.pdf from the GitHub logo kit: the mark must not be edited.
  #expect(
    ArtifactHash.data(try Data(contentsOf: gitHubMark))
      == "9d30aac7deaf046f3e6ca4a46a6d03bcc347c595c64521dc103f4bad313aaf65")
}

@Test func projectLinksPointAtTheRepositoryAndSponsorsPageOnGitHub() {
  for (url, path) in [
    (ProjectLinks.repository, "/bernalli/monoPods"), (ProjectLinks.sponsors, "/sponsors/bernalli"),
  ] {
    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    #expect(parts?.scheme == "https")
    #expect(parts?.host == "github.com")
    #expect(parts?.path == path)
    #expect(parts?.port == nil && parts?.user == nil && parts?.password == nil)
    #expect(parts?.query == nil && parts?.fragment == nil)
  }
}

@MainActor @Test func gitHubMarkLoadsAsATemplateImageWithItsProportions() throws {
  let image = try #require(AboutArtwork.templateImage(contentsOf: gitHubMark))
  #expect(image.isTemplate)
  // The official mark is 98 x 96 points; it is shown with these proportions.
  #expect(image.size == NSSize(width: 98, height: 96))
  #expect(AboutArtwork.templateImage(contentsOf: nil) == nil)
  #expect(
    AboutArtwork.templateImage(contentsOf: repositoryRoot.appendingPathComponent("Assets/none.pdf"))
      == nil)
}

@MainActor private final class LinkRecorder {
  var opened: [URL] = []
  var activations = 0
}

@MainActor private func aboutController(_ recorder: LinkRecorder) -> AboutWindowController {
  AboutWindowController(
    information: AppInformation(infoDictionary: ["CFBundleShortVersionString": "1.2"]),
    icon: nil, gitHubMark: nil, open: { recorder.opened.append($0) },
    activate: { recorder.activations += 1 })
}

@MainActor @Test func aboutLinksOpenThroughTheInjectedOpener() {
  let recorder = LinkRecorder()
  let controller = aboutController(recorder)
  controller.openRepository()
  controller.openSponsors()
  #expect(recorder.opened == [ProjectLinks.repository, ProjectLinks.sponsors])
  #expect(recorder.activations == 0)
}

@MainActor @Test func aboutWindowIsASingleFixedSizeWindowWithOnlyACloseButton() {
  let controller = aboutController(LinkRecorder())
  let window = controller.window
  #expect(controller.window === window)
  #expect(window.title == AboutText.windowTitle)
  #expect(window.styleMask.contains(.titled))
  #expect(window.styleMask.contains(.closable))
  #expect(!window.styleMask.contains(.resizable))
  #expect(!window.styleMask.contains(.miniaturizable))
  #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
  #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true)
  #expect(window.standardWindowButton(.zoomButton)?.isHidden ?? true)
  #expect(!window.isReleasedWhenClosed)
  #expect(!window.isVisible)
  #expect(window.contentView is NSHostingView<AboutView>)
}

/// Counts close notifications posted while `action` runs; closing posts it synchronously.
@MainActor private func closes(_ window: NSWindow, after action: () -> Void) -> Bool {
  let count = CloseCount()
  let token = NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification, object: window, queue: nil
  ) { _ in count.add() }
  action()
  NotificationCenter.default.removeObserver(token)
  return count.value > 0
}

private final class CloseCount: @unchecked Sendable {
  // Only touched on the main thread: the notification is posted synchronously by close().
  private(set) var value = 0
  func add() { value += 1 }
}

private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
    context: nil, characters: characters, charactersIgnoringModifiers: characters,
    isARepeat: false, keyCode: 0)
}

@MainActor @Test func escapeClosesTheAboutWindowAndKeepsItForReuse() {
  let controller = aboutController(LinkRecorder())
  let window = controller.window
  #expect(closes(window) { window.cancelOperation(nil) })
  #expect(controller.window === window)
}

// Closing a window that is already closed posts no notification, so each case uses a new window.
@MainActor @Test func commandWClosesTheAboutWindow() throws {
  let modifiers: [NSEvent.ModifierFlags] = [.command, [.command, .capsLock]]
  for flags in modifiers {
    let window = aboutController(LinkRecorder()).window
    let commandW = try #require(key("w", flags))
    var handled = false
    #expect(closes(window) { handled = window.performKeyEquivalent(with: commandW) })
    #expect(handled)
  }
}

@MainActor @Test func otherKeysDoNotCloseTheAboutWindow() {
  let window = aboutController(LinkRecorder()).window
  let others = [key("w", [.command, .shift]), key("w", []), key("q", .command)].compactMap { $0 }
  #expect(others.count == 3)
  for event in others {
    #expect(!closes(window) { _ = window.performKeyEquivalent(with: event) })
  }
}

private let wordmarkFont = repositoryRoot.appendingPathComponent(
  "Assets/Fonts/PlusJakartaSans-SemiBold.ttf")

@Test func wordmarkFontHasTheExpectedPostScriptName() throws {
  let descriptors = try #require(
    CTFontManagerCreateFontDescriptorsFromURL(wordmarkFont as CFURL) as? [CTFontDescriptor])
  #expect(descriptors.count == 1)
  let descriptor = try #require(descriptors.first)
  let font = CTFontCreateWithFontDescriptor(descriptor, 14, nil)
  #expect(CTFontCopyPostScriptName(font) as String == "PlusJakartaSans-SemiBold")
}

@MainActor private func aboutTitleFont(_ url: URL?) throws -> NSFont {
  let controller = AboutWindowController(
    information: AppInformation(infoDictionary: [:]), icon: nil, gitHubMark: nil,
    titleFontURL: url, open: { _ in }, activate: {})
  let hosting = try #require(controller.window.contentView as? NSHostingView<AboutView>)
  return hosting.rootView.titleFont
}

@MainActor @Test func aboutTitleUsesTheRegisteredWordmarkAtTheOriginalSize() throws {
  let font = try aboutTitleFont(wordmarkFont)
  #expect(font.fontName == "PlusJakartaSans-SemiBold")
  #expect(font.pointSize == NSFont.systemFontSize + 1)
}

@MainActor @Test func aboutTitleCanRegisterTheSameFontMoreThanOnce() throws {
  _ = try aboutTitleFont(wordmarkFont)
  #expect(try aboutTitleFont(wordmarkFont).fontName == "PlusJakartaSans-SemiBold")
}

@MainActor @Test func aboutTitleFallsBackEvenIfTheFontWasRegisteredEarlier() throws {
  _ = try aboutTitleFont(wordmarkFont)
  let font = try aboutTitleFont(nil)
  #expect(font == NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1))
}

@MainActor @Test func aboutTitleFallsBackForMissingInvalidOrUnexpectedFontFiles() throws {
  let otherFont = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
  let otherURL = try #require(CTFontCopyAttribute(otherFont, kCTFontURLAttribute) as? URL)
  for url in [repositoryRoot.appendingPathComponent("Assets/none.ttf"), gitHubMark, otherURL] {
    #expect(try aboutTitleFont(url) == NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1))
  }
}
