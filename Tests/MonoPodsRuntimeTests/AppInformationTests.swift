import Testing

@testable import MonoPodsRuntime

@Test func versionAndBuildComeFromBundleMetadata() {
  let info = AppInformation(infoDictionary: [
    "CFBundleName": "MonoPods", "CFBundleShortVersionString": "2.3.4",
    "CFBundleVersion": "56", "NSHumanReadableCopyright": "Copyright example",
  ])
  #expect(info.versionLabel == "Version 2.3.4 (56)")
  #expect(info.name == "MonoPods")
  #expect(info.copyright == "Copyright example")
}

@Test func absentBundleMetadataHasReadableFallbacks() {
  let info = AppInformation(infoDictionary: nil)
  #expect(info.name == "MonoPods")
  #expect(info.version == nil)
  #expect(info.build == nil)
  #expect(info.versionLabel == "Version Unavailable")
  #expect(info.copyright == nil)
}

@Test func partialAndMalformedMetadataDoesNotProduceEmptyLabels() {
  let info = AppInformation(infoDictionary: [
    "CFBundleName": " \n", "CFBundleShortVersionString": "  ", "CFBundleVersion": " 7 ",
    "NSHumanReadableCopyright": 42,
  ])
  #expect(info.name == "MonoPods")
  #expect(info.versionLabel == "Version Unavailable (Build 7)")
  #expect(info.copyright == nil)
  #expect(
    AppInformation(infoDictionary: ["CFBundleShortVersionString": "1.2"]).versionLabel
      == "Version 1.2")
}

@Test func longVersionMetadataCanBeDisplayedInFull() {
  let version = String(repeating: "1234567890", count: 12)
  let info = AppInformation(infoDictionary: ["CFBundleShortVersionString": version])
  let lines = MenuText.lines(info.versionLabel)
  #expect(lines.allSatisfy { $0.count <= MenuText.width })
  #expect(lines.joined().contains(version))
}
