import AppKit
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

/// With the Italian table, the menu item and the menu version line are Italian, and every text of
/// the About window is English.
@MainActor @Test func theAboutWindowStaysEnglishWhenTheMenuIsItalian() throws {
  let italian = try #require(
    Bundle(path: repositoryRoot.appendingPathComponent("Resources/Localization/it.lproj").path))
  Localized.$bundleOverride.withValue(italian) {
    checkAboutWithItalianLocalization(italian)
  }
}

@MainActor private func checkAboutWithItalianLocalization(_ italian: Bundle) {
  #expect(Localized.text("Options") == "Opzioni")
  #expect(MenuTitle.about == "Informazioni su MonoPods")
  #expect(Localized.format("Version %@", "1.1.0", bundle: italian) == "Versione 1.1.0")
  // No table has the texts of the About window, so not even a lookup could translate them.
  #expect(Localized.text("Buy Me a Coffee", bundle: italian) == "Buy Me a Coffee")
  #expect(
    Localized.format("View %@ on GitHub", "MonoPods", bundle: italian) == "View MonoPods on GitHub")
  #expect(AboutText.windowTitle == "About MonoPods")
  #expect(AboutText.gitHubHelp == "View MonoPods on GitHub")
  #expect(AboutText.sponsor == "Buy Me a Coffee")
  let information = AppInformation(infoDictionary: [
    "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "14",
    "NSHumanReadableCopyright": "Copyright © 2026 Example",
  ])
  #expect(information.versionLabel == "Versione 1.1.0")
  #expect(information.englishVersionLabel == "Version 1.1.0")
  #expect(information.copyright == "Copyright © 2026 Example")
  let controller = AboutWindowController(
    information: information, icon: nil, gitHubMark: nil, open: { _ in }, activate: {})
  #expect(controller.window.title == "About MonoPods")
}

@Test func theAboutVersionLineIsEnglishForEveryMetadataShape() {
  let cases: [([String: Any], String)] = [
    (["CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "56"], "Version 2.3.4"),
    (["CFBundleShortVersionString": "1.2"], "Version 1.2"),
    (["CFBundleVersion": "7"], "Version Unavailable"),
    ([:], "Version Unavailable"),
  ]
  for (metadata, label) in cases {
    let information = AppInformation(infoDictionary: metadata)
    #expect(information.englishVersionLabel == label)
    // Without a table the menu line reads the same.
    #expect(information.versionLabel == label)
  }
}

/// Every shape of the bundle metadata: neither the menu line nor the About line shows the build,
/// without a table and with the Italian table in effect.
@Test func theVersionLinesNeverShowTheBuild() throws {
  let italian = try #require(
    Bundle(path: repositoryRoot.appendingPathComponent("Resources/Localization/it.lproj").path))
  let build = "9137"
  let shapes: [([String: Any]?, String?)] = [
    (["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": build], "1.1.0"),
    (["CFBundleShortVersionString": "1.1.0"], "1.1.0"),
    (["CFBundleVersion": build], nil),
    ([:], nil),
    (nil, nil),
    (["CFBundleShortVersionString": "", "CFBundleVersion": build], nil),
    (["CFBundleShortVersionString": " \n\t", "CFBundleVersion": build], nil),
    (["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": ""], "1.1.0"),
    (["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "  "], "1.1.0"),
    (["CFBundleShortVersionString": " 1.1.0 ", "CFBundleVersion": " \(build) "], "1.1.0"),
    (["CFBundleShortVersionString": 1.1, "CFBundleVersion": build], nil),
    (["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": 9137], "1.1.0"),
    (["CFBundleShortVersionString": ["1.1.0"], "CFBundleVersion": [build]], nil),
  ]
  for (metadata, version) in shapes {
    let information = AppInformation(infoDictionary: metadata)
    let english = version.map { "Version \($0)" } ?? "Version Unavailable"
    let menu = information.versionLabel
    let about = information.englishVersionLabel
    let (italianMenu, italianAbout) = Localized.$bundleOverride.withValue(italian) {
      (information.versionLabel, information.englishVersionLabel)
    }
    #expect(menu == english)
    #expect(about == english)
    #expect(italianMenu == (version.map { "Versione \($0)" } ?? "Versione non disponibile"))
    #expect(italianAbout == english)
    for line in [menu, about, italianMenu, italianAbout] {
      #expect(!line.contains(build) && !line.localizedCaseInsensitiveContains("build"))
      #expect(!line.contains("(") && !line.contains("（"))
    }
  }
}
