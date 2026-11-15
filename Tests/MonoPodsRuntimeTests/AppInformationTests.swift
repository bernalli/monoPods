import Testing

@testable import MonoPodsRuntime

@Test func versionComesFromBundleMetadataWithoutTheBuild() {
  let info = AppInformation(infoDictionary: [
    "CFBundleName": "MonoPods", "CFBundleShortVersionString": "2.3.4",
    "CFBundleVersion": "56", "NSHumanReadableCopyright": "Copyright example",
  ])
  #expect(info.englishVersionLabel == "Version 2.3.4")
  #expect(info.name == "MonoPods")
  #expect(info.copyright == "Copyright example")
}

@Test func absentBundleMetadataHasReadableFallbacks() {
  let info = AppInformation(infoDictionary: nil)
  #expect(info.name == "MonoPods")
  #expect(info.version == nil)
  #expect(info.englishVersionLabel == "Version Unavailable")
  #expect(info.copyright == nil)
}

@Test func partialAndMalformedMetadataDoesNotProduceEmptyLabels() {
  let info = AppInformation(infoDictionary: [
    "CFBundleName": " \n", "CFBundleShortVersionString": "  ", "CFBundleVersion": " 7 ",
    "NSHumanReadableCopyright": 42,
  ])
  #expect(info.name == "MonoPods")
  #expect(info.englishVersionLabel == "Version Unavailable")
  #expect(info.copyright == nil)
  #expect(
    AppInformation(infoDictionary: ["CFBundleShortVersionString": "1.2"]).englishVersionLabel
      == "Version 1.2")
}

@Test func longVersionMetadataIsShownInFullInTheAbout() {
  let version = String(repeating: "1234567890", count: 12)
  let info = AppInformation(infoDictionary: ["CFBundleShortVersionString": version])
  #expect(info.englishVersionLabel == "Version \(version)")
  #expect(info.englishVersionLabel.contains(version))
}
