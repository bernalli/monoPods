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
@Test func noBreakSpacesStayInsideALine() {
  for space in ["\u{00A0}", "\u{202F}", "\u{2007}"] {
    let text = "Sortie audio\(space): AirPods Pro"
    #expect(MenuText.lines(text) == [text], "\(space.unicodeScalars.first?.value ?? 0)")
  }
}

@Test func onlySpacesGiveNoLines() {
  #expect(MenuText.lines("\u{00A0}").isEmpty)
  #expect(MenuText.lines(" \u{202F} \n").isEmpty)
}

/// Deterministic generator with a fixed seed (SplitMix64).
private struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

@Test func randomTextsKeepEveryCharacterButBreakingSpaces() {
  let pieces = ["a", "bb", "ccc", " ", "\u{00A0}", "\u{202F}", "\n", ":"]
  let noBreak: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2007}"]
  func breaking(_ character: Character) -> Bool {
    character.isWhitespace && !noBreak.contains(character)
  }
  var random = SplitMix64(state: 0x6E62_7370)
  for _ in 0..<2000 {
    let text = (0..<(1 + random.below(60))).map { _ in pieces[random.below(pieces.count)] }
      .joined()
    for width in [1, 5, 10, 44] {
      let lines = MenuText.lines(text, width: width)
      if text.allSatisfy(\.isWhitespace) {
        #expect(lines.isEmpty, "\(text.debugDescription)")
        continue
      }
      for line in lines {
        #expect(!line.isEmpty && line.count <= width, "\(text.debugDescription) \(width)")
        #expect(line.first.map(breaking) == false, "\(text.debugDescription) \(width)")
        #expect(line.last.map(breaking) == false, "\(text.debugDescription) \(width)")
      }
      #expect(
        String(text.filter { !breaking($0) }) == String(lines.joined().filter { !breaking($0) }),
        "\(text.debugDescription) \(width)")
    }
  }
}
