/// The menu bar icon state: which mode the app last applied, or that it needs attention.
public enum MenuBarGlyph: Equatable, Sendable {
  case idle
  case mono(MonoSide)
  case stereo, attention

  /// The ring that Mono fills.
  public enum MonoSide: Equatable, Sendable { case left, right }

  /// Attention wins over everything: a blocked engine or a failed last command. Otherwise the last
  /// successful command picks mono or stereo, and no command at all is idle. The ear count never
  /// drives the icon. In Mono, `side` picks the ring: only a known single right ear fills the right
  /// ring; an unknown side, both ears or none keep the left ring.
  public static func glyph(for snapshot: EngineSnapshot?, side: EarSide? = nil) -> MenuBarGlyph {
    guard let snapshot else { return .idle }
    if snapshot.blocked { return .attention }
    guard let last = snapshot.lastCompleted else { return .idle }
    guard last.exitCode == 0 else { return .attention }
    switch last.target {
    case .mono: return .mono(side == .right ? .right : .left)
    case .stereo: return .stereo
    }
  }
}
