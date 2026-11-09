import Testing

@testable import MonoPodsRuntime

@Test func emptyTextHasNoMenuLines() {
  #expect(MenuText.lines("").isEmpty)
  #expect(MenuText.lines("   ").isEmpty)
}

@Test func shortTextStaysOnOneLine() {
  #expect(MenuText.lines("Observing") == ["Observing"])
  #expect(MenuText.lines("  Observing  ") == ["Observing"])
}

@Test func longTextWrapsAtWordsWithinWidth() {
  let text =
    "An audio command failed repeatedly. Automatic attempts for this target are blocked until the target or connection changes."
  let lines = MenuText.lines(text)
  #expect(lines.count > 1)
  #expect(lines.allSatisfy { $0.count <= MenuText.width })
  #expect(lines.joined(separator: " ") == text)
}

@Test func overlongWordIsSplitWithinWidth() {
  let word = String(repeating: "x", count: MenuText.width * 2 + 3)
  let lines = MenuText.lines(word)
  #expect(lines.count == 3)
  #expect(lines.allSatisfy { $0.count <= MenuText.width })
  #expect(lines.joined() == word)
}

@Test func customWidthIsRespected() {
  #expect(MenuText.lines("one two three", width: 7) == ["one two", "three"])
}
