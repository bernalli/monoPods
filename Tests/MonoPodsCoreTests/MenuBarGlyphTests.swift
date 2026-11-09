import Testing

@testable import MonoPodsCore

private func snapshot(blocked: Bool = false, last: CommandReceipt? = nil) -> EngineSnapshot {
  var snapshot = Engine(build: String(repeating: "a", count: 64), run: 1, boot: "boot").snapshot
  snapshot.blocked = blocked
  snapshot.lastCompleted = last
  return snapshot
}

@Test func missingSnapshotIsIdle() {
  #expect(MenuBarGlyph.glyph(for: nil) == .idle)
}

@Test func snapshotWithoutCommandsIsIdle() {
  #expect(MenuBarGlyph.glyph(for: snapshot()) == .idle)
}

@Test func successfulMonoCommandShowsMono() {
  let last = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  #expect(MenuBarGlyph.glyph(for: snapshot(last: last)) == .mono(.left))
}

@Test func successfulStereoCommandShowsStereo() {
  let last = CommandReceipt(id: 1, target: .stereo, exitCode: 0)
  #expect(MenuBarGlyph.glyph(for: snapshot(last: last)) == .stereo)
}

@Test func failedMonoCommandNeedsAttention() {
  let last = CommandReceipt(id: 1, target: .mono, exitCode: 1)
  #expect(MenuBarGlyph.glyph(for: snapshot(last: last)) == .attention)
}

@Test func failedStereoCommandNeedsAttention() {
  let last = CommandReceipt(id: 1, target: .stereo, exitCode: -1)
  #expect(MenuBarGlyph.glyph(for: snapshot(last: last)) == .attention)
}

@Test func blockedEngineWithoutCommandsNeedsAttention() {
  #expect(MenuBarGlyph.glyph(for: snapshot(blocked: true)) == .attention)
}

@Test func blockedEngineOverridesSuccessfulMonoCommand() {
  let last = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  #expect(MenuBarGlyph.glyph(for: snapshot(blocked: true, last: last)) == .attention)
}

@Test func monoFillsTheRightRingOnlyForASingleRightEar() {
  let mono = snapshot(last: CommandReceipt(id: 1, target: .mono, exitCode: 0))
  #expect(MenuBarGlyph.glyph(for: mono, side: .right) == .mono(.right))
  for side: EarSide? in [nil, .left, .both, EarSide.none] {
    #expect(MenuBarGlyph.glyph(for: mono, side: side) == .mono(.left))
  }
}

@Test func earSideNeverChangesStereoIdleOrAttention() {
  let stereo = snapshot(last: CommandReceipt(id: 1, target: .stereo, exitCode: 0))
  let failed = snapshot(last: CommandReceipt(id: 1, target: .mono, exitCode: 1))
  for side: EarSide? in [nil, .left, .right, .both, EarSide.none] {
    #expect(MenuBarGlyph.glyph(for: stereo, side: side) == .stereo)
    #expect(MenuBarGlyph.glyph(for: snapshot(), side: side) == .idle)
    #expect(MenuBarGlyph.glyph(for: failed, side: side) == .attention)
    #expect(MenuBarGlyph.glyph(for: nil, side: side) == .idle)
  }
}
