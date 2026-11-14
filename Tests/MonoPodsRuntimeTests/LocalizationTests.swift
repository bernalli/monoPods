import Foundation
import Testing

@testable import MonoPodsRuntime

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

@Test func withoutATableTheKeyIsShown() throws {
  // A folder with sources only: no `Localizable` table to read.
  let bundle = try #require(
    Bundle(path: repositoryRoot.appendingPathComponent("Tests/MonoPodsRuntimeTests").path))
  #expect(Localized.text("Options", bundle: bundle) == "Options")
  #expect(Localized.format("Quit %@", "MonoPods", bundle: bundle) == "Quit MonoPods")
}

@Test func theItalianTableTranslatesTextAndFormats() throws {
  let bundle = try #require(
    Bundle(path: repositoryRoot.appendingPathComponent("Resources/Localization/it.lproj").path))
  #expect(Localized.text("Options", bundle: bundle) == "Opzioni")
  #expect(Localized.format("Quit %@", "MonoPods", bundle: bundle) == "Esci da MonoPods")
}
