import Foundation
import Testing

@testable import MonoPodsCore

// The player state of the now-playing application decides whether a removal Play is legitimate:
// macOS sends its removal Pause to every client, also to a player the user had already paused.
// Times and offsets come from a measured session on 2026-11-07; all values are fake.

private let millis: UInt64 = 1_000_000

/// One input with its arrival instant, in continuous nanoseconds from the test epoch.
private struct Step {
  var input: EngineInput
  var at: UInt64
}
private func live(
  _ value: ObservationValue, _ source: Source, at nanos: UInt64,
  context: ObservationContext = .test
) -> EngineInput {
  .observation(
    Observation(
      sourceTime: instant(nanos: nanos).utc, source: source, provenance: .live, context: context,
      receivedContinuousNanos: nanos, value: value))
}
/// A now-playing row with source time `source`; it arrives at `arrival` (default: the same time).
private func row(_ playing: Bool, source: UInt64, arrival: UInt64? = nil, epoch: UInt64 = 1)
  -> Step
{
  Step(
    input: .nowPlaying(epoch: epoch, playing: playing, sourceTime: instant(nanos: source).utc),
    at: arrival ?? source)
}
private func twoEars(at nanos: UInt64 = 1_000 * millis, context: ObservationContext = .test)
  -> Step
{
  Step(input: live(.count(2, detection: .on), .s1, at: nanos, context: context), at: nanos)
}
/// The measured removal: the count of one at `removal`, the Both→One transition 10 ms later and
/// the Pause 20 ms later. `countFirst: false` leaves the count out, so only the transition opens it.
/// `countArrival` and `transitionArrival` deliver those signals later, with the same source times.
private func removalSteps(
  at removal: UInt64, context: ObservationContext = .test, countFirst: Bool = true,
  countArrival: UInt64? = nil, transitionArrival: UInt64? = nil
) -> [Step] {
  var steps = [
    Step(
      input: live(
        .transition(from: .both, to: .one), .m, at: removal + 10 * millis, context: context),
      at: transitionArrival ?? removal + 10 * millis),
    Step(input: .pause(instant(nanos: removal + 20 * millis).utc), at: removal + 20 * millis),
  ]
  if countFirst {
    steps.insert(
      Step(
        input: live(.count(1, detection: .on), .s1, at: removal, context: context),
        at: countArrival ?? removal),
      at: 0)
  }
  return steps
}
/// Stable order by arrival: equal arrivals keep the order in which the test lists them.
private func ordered(_ steps: [Step]) -> [Step] {
  steps.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(
    \.element)
}
private func plays(_ actions: [EngineAction]) -> Int {
  actions.filter { if case .play = $0 { true } else { false } }.count
}
/// Applies the steps with a drain after each, then ticks every 100 ms for 4 s, past the end of
/// every episode. Returns the number of Play actions.
private func playCount(_ steps: [Step], engine: inout Engine) -> Int {
  var count = 0
  let sorted = ordered(steps)
  for step in sorted {
    count += plays(engine.handle(input: step.input, at: instant(nanos: step.at)))
    count += plays(engine.handle(input: .drain, at: instant(nanos: step.at)))
  }
  let last = sorted.last?.at ?? 0
  for tick in UInt64(1)...40 {
    count += plays(engine.handle(input: .tick, at: instant(nanos: last + tick * 100 * millis)))
  }
  return count
}
private func playCount(_ steps: [Step]) -> Int {
  var engine = readyEngine()
  return playCount(steps, engine: &engine)
}

@Test func manualPauseBeforeRemovalGivesNoPlay() {
  // Measured: Not Playing 14.463 s before the removal and no player change in between.
  let removal: UInt64 = 2_444 * millis + 14_463 * millis
  let steps =
    [twoEars(), row(true, source: 1_500 * millis), row(false, source: 2_444 * millis)]
    + removalSteps(at: removal)
  #expect(playCount(steps) == 0)
}
@Test func removalWhilePlayingStillPlaysDespiteItsOwnNotPlaying() {
  // Measured: the removal Pause turns the player to Not Playing 10-20 ms after the Pause.
  let removal: UInt64 = 16_000 * millis
  let steps =
    [twoEars(), row(true, source: 10_000 * millis)] + removalSteps(at: removal)
    + [row(false, source: removal + 32 * millis)]
  #expect(playCount(steps) == 1)
  // The same row that arrives only after the Play changes nothing.
  let late =
    [twoEars(), row(true, source: 10_000 * millis)] + removalSteps(at: removal)
    + [row(false, source: removal + 32 * millis, arrival: removal + 500 * millis)]
  #expect(playCount(late) == 1)
}
@Test func unknownPlayerStateNeedsAnObservedStop() {
  let removal: UInt64 = 16_000 * millis
  for countFirst in [true, false] {
    let steps = [twoEars()] + removalSteps(at: removal, countFirst: countFirst)
    #expect(playCount(steps) == 0)
    #expect(playCount(steps + [row(false, source: removal + 32 * millis)]) == 1)
  }
}
@Test func lateDuplicateFutureAndForeignRowsAreIgnored() {
  let removal: UInt64 = 16_000 * millis
  let paused = [twoEars(), row(false, source: 5_000 * millis)]
  // A Playing row that arrives late with an older source time.
  #expect(
    playCount(
      paused + [row(true, source: 4_900 * millis, arrival: 6_000 * millis)]
        + removalSteps(at: removal)) == 0)
  // Duplicates of the same row.
  #expect(
    playCount(
      paused + [row(false, source: 5_000 * millis, arrival: 6_000 * millis)]
        + [row(false, source: 5_000 * millis, arrival: 7_000 * millis)]
        + removalSteps(at: removal)) == 0)
  // A Playing row from the future, then a Playing row of the current stream with a time after
  // the last applied one: the future row does not hide it.
  let future = row(true, source: 30_000 * millis, arrival: 6_000 * millis)
  #expect(playCount(paused + [future] + removalSteps(at: removal)) == 0)
  #expect(
    playCount(paused + [future, row(true, source: 7_000 * millis)] + removalSteps(at: removal))
      == 1)
  // A Playing row of another stream epoch.
  #expect(
    playCount(paused + [row(true, source: 6_000 * millis, epoch: 2)] + removalSteps(at: removal))
      == 0)
  // With that row ignored the state stays unknown, and the stop releases the Play.
  #expect(
    playCount(
      [twoEars(), row(false, source: 5_000 * millis, epoch: 2)] + removalSteps(at: removal)
        + [row(false, source: removal + 32 * millis)]) == 1)
}
@Test func gapRouteAndStreamRestartForgetThePlayerState() {
  let restarted = ObservationContext(
    routeEpoch: 1, streamEpoch: 2, connectionEpoch: 1, deviceOrdinal: 1)
  let rerouted = ObservationContext(
    routeEpoch: 2, streamEpoch: 1, connectionEpoch: 2, deviceOrdinal: 1)
  func restart(_ reset: [EngineInput]) -> [Step] {
    reset.map { Step(input: $0, at: 3_000 * millis) } + [
      Step(input: .streamStarted(epoch: 2, nonce: "nonce-2"), at: 3_100 * millis),
      Step(input: .heartbeat(epoch: 2, nonce: "nonce-2", sequence: 1), at: 3_200 * millis),
    ]
  }
  let unreadable = EngineInput.gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(3).utc)
  let cases: [(String, [Step], ObservationContext)] = [
    ("none", [], .test),
    ("unreadable", [Step(input: unreadable, at: 3_000 * millis)], .test),
    ("transport", restart([.gap(epoch: 1, reason: .transport, faultTime: nil)]), restarted),
    ("clock", restart([.gap(epoch: 1, reason: .clockChanged, faultTime: nil)]), restarted),
    ("restart", restart([]), restarted),
    (
      "route",
      [
        Step(input: .route(Route(epoch: 2, deviceOrdinal: 1)), at: 3_000 * millis),
        Step(
          input: .connection(Connection(epoch: 2, boundary: instant(3).utc)), at: 3_000 * millis),
      ], rerouted
    ),
  ]
  for (name, reset, context) in cases {
    let steps =
      [twoEars(), row(false, source: 2_000 * millis)] + reset
      + [twoEars(at: 4_000 * millis, context: context)]
      + removalSteps(at: 6_000 * millis, context: context)
    // The removal's own stop plays only where the older Not Playing row was forgotten.
    let stop = row(false, source: 6_032 * millis, epoch: context.streamEpoch)
    #expect(playCount(steps + [stop]) == (name == "none" ? 0 : 1), "\(name)")
    #expect(playCount(steps) == 0, "\(name)")
  }
  // After a restart, a row with a source time before the new stream start is ignored.
  let stale =
    [twoEars()] + restart([]) + [row(false, source: 2_500 * millis, arrival: 3_500 * millis)]
    + [twoEars(at: 4_000 * millis, context: restarted)]
    + removalSteps(at: 6_000 * millis, context: restarted)
    + [row(false, source: 6_032 * millis, epoch: 2)]
  #expect(playCount(stale) == 1)
}
@Test func theRemovalStartsAtItsFirstSignal() {
  let removal: UInt64 = 16_000 * millis
  let playing = [twoEars(), row(true, source: 10_000 * millis)]
  // Not Playing after the count of one and before the transition: the removal had begun.
  #expect(
    playCount(playing + [row(false, source: removal + 5 * millis)] + removalSteps(at: removal)) == 1
  )
  // Not Playing at the first signal itself is not strictly before it.
  #expect(playCount(playing + [row(false, source: removal)] + removalSteps(at: removal)) == 1)
  // Not Playing 1 ms before the first signal.
  #expect(
    playCount(playing + [row(false, source: removal - millis)] + removalSteps(at: removal)) == 0)
  // Without a count of one the transition is the first signal.
  #expect(
    playCount(
      playing + [row(false, source: removal + 5 * millis)]
        + removalSteps(at: removal, countFirst: false)) == 0)
}
@Test func manyRowsKeepTheLastStateBeforeTheRemoval() {
  let removal: UInt64 = 16_000 * millis
  for last in [false, true] {
    var steps = [twoEars()]
    for index in UInt64(0)..<40 {
      let playing = index % 2 == (last ? 1 : 0)
      steps.append(row(playing, source: 5_000 * millis + index * 200 * millis))
    }
    #expect(playCount(steps + removalSteps(at: removal)) == (last ? 1 : 0), "last=\(last)")
  }
}
@Test func resetRejectsBufferedPlayerRowsBeforeItsBarrier() {
  let rerouted = ObservationContext(
    routeEpoch: 2, streamEpoch: 1, connectionEpoch: 2, deviceOrdinal: 1)
  let unreadable = Step(
    input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(3).utc), at: 3_000 * millis)
  let resets: [([Step], ObservationContext)] = [
    ([unreadable], .test),
    (
      [
        Step(input: .route(Route(epoch: 2, deviceOrdinal: 1)), at: 3_000 * millis),
        Step(
          input: .connection(Connection(epoch: 2, boundary: instant(3).utc)),
          at: 3_000 * millis),
      ], rerouted
    ),
  ]
  for (reset, context) in resets {
    let steps =
      [twoEars(), row(false, source: 2_000 * millis)] + reset
      + [
        row(false, source: 2_500 * millis, arrival: 3_500 * millis),
        twoEars(at: 4_000 * millis, context: context),
      ]
      + removalSteps(at: 6_000 * millis, context: context)
      + [row(false, source: 6_032 * millis)]
    #expect(playCount(steps) == 1)
    #expect(playCount(steps + [row(false, source: 3_600 * millis)]) == 0)
  }
}
@Test func rowsAfterRemovalCannotEvictItsManualPause() {
  let removal: UInt64 = 16_000 * millis
  var steps = [twoEars(), row(false, source: 2_000 * millis)] + removalSteps(at: removal)
  for index in UInt64(0)..<64 {
    steps.append(row(false, source: removal + (32 + index) * millis))
  }
  #expect(playCount(steps) == 0)
}
@Test func countChangesCannotRewriteTheRemovalSnapshot() {
  let removal: UInt64 = 16_000 * millis
  let steps =
    [twoEars(), row(true, source: 2_000 * millis)] + removalSteps(at: removal)
    + [row(false, source: removal + 5 * millis), twoEars(at: removal + 50 * millis)]
  #expect(playCount(steps) == 1)
}
@Test func delayedTransitionKeepsTheFirstCountEvidenceUntilTheDecision() {
  let steps = [
    twoEars(), row(false, source: 2_000 * millis),
    Step(input: live(.count(1, detection: .on), .s1, at: 4_000 * millis), at: 4_000 * millis),
    row(true, source: 4_100 * millis),
    Step(input: .pause(instant(nanos: 4_020 * millis).utc), at: 6_500 * millis),
    Step(
      input: live(.transition(from: .both, to: .one), .m, at: 4_010 * millis),
      at: 7_100 * millis),
  ]
  #expect(playCount(steps) == 0)
}
@Test func latePreRemovalRowsRefineOnlyTheirRemovalSnapshot() {
  let removal: UInt64 = 16_000 * millis
  for playing in [false, true] {
    let prefix = [twoEars(), row(!playing, source: 2_000 * millis)]
    let suffix = removalSteps(at: removal) + [row(false, source: removal + 32 * millis)]
    let timely = row(playing, source: removal - millis)
    let delayed = row(playing, source: removal - millis, arrival: removal + 60 * millis)
    let expected = playing ? 1 : 0
    #expect(playCount(prefix + [timely] + suffix) == expected)
    #expect(playCount(prefix + [delayed] + suffix) == expected)
  }
}
// Bluetooth and player rows come from different processes: a removal signal can arrive after a
// player row with a later source time. That row must not hide the state before the removal.
@Test func lateRemovalSignalsStillSeeTheStateBeforeTheRemoval() {
  let removal: UInt64 = 16_000 * millis
  for playing in [false, true] {
    let prefix = [twoEars(), row(playing, source: 2_000 * millis)]
    let after = row(false, source: removal + 30 * millis, arrival: removal + 31 * millis)
    let expected = playing ? 1 : 0
    // Only the transition, which arrives after the post-removal row.
    #expect(
      playCount(
        prefix + [after]
          + removalSteps(at: removal, countFirst: false, transitionArrival: removal + 50 * millis))
        == expected, "transition, playing=\(playing)")
    // The count of one exists but it also arrives after that row.
    #expect(
      playCount(
        prefix + [after]
          + removalSteps(
            at: removal, countArrival: removal + 45 * millis,
            transitionArrival: removal + 50 * millis)) == expected, "count, playing=\(playing)")
  }
}
@Test func aLateEarlierCountMovesTheEvidenceBeforeItsTime() {
  // The transition arrives on time and sees a Not Playing row 5 ms after the count of one. The
  // count arrives later and moves the first signal before that row.
  let removal: UInt64 = 16_000 * millis
  for playing in [false, true] {
    let steps =
      [
        twoEars(), row(playing, source: 2_000 * millis),
        row(false, source: removal + 5 * millis, arrival: removal + 6 * millis),
      ]
      + removalSteps(at: removal, countArrival: removal + 40 * millis)
    #expect(playCount(steps) == (playing ? 1 : 0), "playing=\(playing)")
  }
}
@Test func anOldRowStaysTheBackgroundStateAcrossManyLaterRows() {
  // 110 post-removal rows over 1.1 s, all applied before a transition that arrives 1.19 s late.
  // The row at 2 s is far older than the newest row and is still the state before the removal.
  let removal: UInt64 = 10_000 * millis
  for playing in [false, true] {
    var steps = [
      twoEars(), row(!playing, source: 1_500 * millis), row(playing, source: 2_000 * millis),
    ]
    for index in UInt64(0)..<110 {
      steps.append(row(false, source: removal + (30 + 10 * index) * millis))
    }
    steps += removalSteps(
      at: removal, countFirst: false, transitionArrival: removal + 1_200 * millis)
    #expect(playCount(steps) == (playing ? 1 : 0), "playing=\(playing)")
  }
}
@Test func aRemovalOlderThanTheHistoryWindowHasAnUnknownState() {
  // The history keeps rows only within three removal windows of the newest row. A transition
  // that trails the newest row by more than that, with its Pause just as late, finds the rows
  // before it dropped: the state is unknown, and the retained Not Playing rows after the
  // transition are its stop.
  let removal: UInt64 = 10_000 * millis
  var steps = [
    twoEars(), row(false, source: 1_500 * millis), row(false, source: 2_000 * millis),
  ]
  for index in UInt64(0)..<12 {
    steps.append(row(false, source: removal + (30 + 1_000 * index) * millis))
  }
  steps += [
    Step(
      input: live(.transition(from: .both, to: .one), .m, at: removal + 10 * millis),
      at: removal + 12_000 * millis),
    Step(input: .pause(instant(nanos: removal + 20 * millis).utc), at: removal + 12_010 * millis),
  ]
  #expect(playCount(steps) == 1)
}
// MARK: - Unknown player state

/// Drives the engine as the runtime does: a drain after every input, a tick at every deadline the
/// engine asks for. It records the Plays and that no deadline is ever repeated or left in the past.
private struct Drive {
  var engine = readyEngine()
  var plays: [UInt64] = []
  private var clock: UInt64 = 0

  private mutating func send(_ input: EngineInput, at nanos: UInt64) {
    for action in engine.handle(input: input, at: instant(nanos: nanos)) {
      if case .play = action { plays.append(nanos) }
    }
  }
  private mutating func advance(to target: UInt64) {
    while let deadline = engine.nextDeadline, deadline <= target {
      guard deadline >= clock else {
        Issue.record("deadline \(deadline) is before the clock \(clock)")
        return
      }
      clock = deadline
      send(.tick, at: deadline)
      if engine.nextDeadline == deadline {
        Issue.record("deadline \(deadline) repeats")
        return
      }
    }
    clock = target
  }
  /// Applies the steps in arrival order, then moves the clock up to `end`.
  mutating func run(_ steps: [Step], until end: UInt64) {
    for step in ordered(steps) {
      advance(to: step.at)
      send(step.input, at: step.at)
      send(.drain, at: step.at)
      if let deadline = engine.nextDeadline, deadline <= step.at {
        Issue.record("deadline \(deadline) is due after the drain at \(step.at)")
      }
    }
    advance(to: end)
  }
}
private let reroutedContext = ObservationContext(
  routeEpoch: 2, streamEpoch: 1, connectionEpoch: 2, deviceOrdinal: 1)
/// A route change at 3 s: the barrier leaves the player state unknown for the removal.
private func rerouted() -> [Step] {
  [
    twoEars(),
    Step(input: .route(Route(epoch: 2, deviceOrdinal: 1)), at: 3_000 * millis),
    Step(input: .connection(Connection(epoch: 2, boundary: instant(3).utc)), at: 3_000 * millis),
    twoEars(at: 4_000 * millis, context: reroutedContext),
  ]
}
/// Pause 20 ms after `removal`: the Play is due 100 ms later and the episode ends 3 s later.
private func dueTime(_ removal: UInt64) -> UInt64 { removal + 120 * millis }
private func endTime(_ removal: UInt64) -> UInt64 { removal + 3_020 * millis }

@Test func aPlayerStoppedBeforeARouteChangeGetsNoPlay() {
  // Measured 2026-11-08 11:58: the route changes, no player row for 13.85 s, then the removal.
  // The player was already stopped, so its Not Playing row never comes.
  let removal: UInt64 = 16_850 * millis
  var drive = Drive()
  drive.run(
    rerouted() + removalSteps(at: removal, context: reroutedContext), until: dueTime(removal))
  #expect(drive.plays.isEmpty)
  // The end of the episode is the only wake-up left: the deadline of the Play is gone.
  #expect(drive.engine.nextDeadline == endTime(removal))
  drive.run([], until: endTime(removal) + millis)
  #expect(drive.plays.isEmpty)
  // A stop after the end has no episode left to release.
  drive.run(
    [row(false, source: endTime(removal) + 2 * millis)], until: endTime(removal) + 500 * millis)
  #expect(drive.plays.isEmpty)
}
@Test func aPlayerStoppedByTheRemovalGetsOnePlayNotBeforeItsDeadline() {
  let removal: UInt64 = 6_000 * millis
  // Measured delays of Not Playing after the removal; the first two arrive before the deadline.
  for delay: UInt64 in [32, 45, 135] {
    let arrival = removal + delay * millis
    var drive = Drive()
    drive.run(
      rerouted() + removalSteps(at: removal, context: reroutedContext)
        + [row(false, source: arrival), row(false, source: arrival + 5 * millis)],
      until: endTime(removal) + 500 * millis)
    #expect(drive.plays == [max(dueTime(removal), arrival)], "delay=\(delay)")
  }
}
@Test func aStopCountsOnlyWithinTheEpisode() {
  let removal: UInt64 = 6_000 * millis
  let signals = rerouted() + removalSteps(at: removal, context: reroutedContext)
  let last = endTime(removal) - 1
  var drive = Drive()
  drive.run(signals + [row(false, source: last)], until: endTime(removal) + 500 * millis)
  #expect(drive.plays == [last])
  for arrival in [endTime(removal), endTime(removal) + 1] {
    var late = Drive()
    late.run(signals + [row(false, source: arrival)], until: endTime(removal) + 500 * millis)
    #expect(late.plays.isEmpty, "arrival=\(arrival)")
    // A row inside the window that arrives after its end is just as late.
    var delayed = Drive()
    delayed.run(
      signals + [row(false, source: last, arrival: arrival)],
      until: endTime(removal) + 500 * millis)
    #expect(delayed.plays.isEmpty, "arrival=\(arrival)")
  }
}
@Test func aStopBeforeTheRemovalSignalsArriveCountsWithItsSourceTime() {
  let removal: UInt64 = 6_000 * millis
  let transition = removal + 10 * millis
  // The player row wins the race with the signals of another process.
  for (source, played) in [
    (transition, true), (transition + 5 * millis, true), (transition - 1, false),
  ] {
    var drive = Drive()
    drive.run(
      rerouted() + [row(false, source: source, arrival: transition + 6 * millis)]
        + removalSteps(
          at: removal, context: reroutedContext, countFirst: false,
          transitionArrival: transition + 40 * millis),
      until: endTime(removal) + 500 * millis)
    // The row before the first signal makes the state known: Not Playing, so no Play.
    #expect(drive.plays.count == (played ? 1 : 0), "source=\(source)")
  }
}
@Test func aLateRowBeforeTheRemovalSettlesAWaitingEpisode() {
  let removal: UInt64 = 6_000 * millis
  let arrival = removal + 500 * millis
  let signals = rerouted() + removalSteps(at: removal, context: reroutedContext)
  // Known Playing: the Play leaves at once, and only once.
  var playing = Drive()
  playing.run(
    signals + [row(true, source: removal - millis, arrival: arrival)],
    until: endTime(removal) + 500 * millis)
  #expect(playing.plays == [arrival])
  // Known Not Playing: the episode ends without a Play, and a later stop does not revive it.
  var paused = Drive()
  paused.run(
    signals + [row(false, source: removal - millis, arrival: arrival)], until: arrival + millis)
  #expect(paused.plays.isEmpty)
  #expect(paused.engine.nextDeadline != endTime(removal))
  paused.run([row(false, source: arrival + 100 * millis)], until: endTime(removal) + 500 * millis)
  #expect(paused.plays.isEmpty)
}
/// Rows after the first signal that keep the history cut at `removal`: the removal finds its
/// player state unknown, and its signals arrive 12 s late with the Pause just as late.
private func truncatedHistory(_ removal: UInt64) -> [Step] {
  var steps = [twoEars(), row(false, source: 1_500 * millis), row(false, source: 2_000 * millis)]
  for index in UInt64(0)..<12 {
    steps.append(row(true, source: removal + (30 + 1_000 * index) * millis))
  }
  steps += [
    Step(
      input: live(.transition(from: .both, to: .one), .m, at: removal + 10 * millis),
      at: removal + 12_000 * millis),
    Step(input: .pause(instant(nanos: removal + 20 * millis).utc), at: removal + 12_010 * millis),
  ]
  return steps
}
@Test func aCutHistoryFollowsTheSameTwoRules() {
  let removal: UInt64 = 3_000 * millis
  let start = removal + 12_010 * millis
  let due = start + 100 * millis
  let end = start + 3_000 * millis
  // No stop: no Play, and only the end of the episode as wake-up.
  var silent = Drive()
  silent.run(truncatedHistory(removal), until: due)
  #expect(silent.plays.isEmpty)
  #expect(silent.engine.nextDeadline == end)
  silent.run([], until: end + 500 * millis)
  #expect(silent.plays.isEmpty)
  // A stop applied after the capture: one Play.
  let arrival = start + 500 * millis
  var stopped = Drive()
  stopped.run(truncatedHistory(removal) + [row(false, source: arrival)], until: end + 500 * millis)
  #expect(stopped.plays == [arrival])
  // A Not Playing row before the first signal is neither evidence, in a cut history, nor a stop.
  var older = Drive()
  older.run(
    truncatedHistory(removal) + [row(false, source: removal - millis, arrival: arrival)],
    until: end + 500 * millis)
  #expect(older.plays.isEmpty)
  // A stop already in the history at the capture, even when the history is cut.
  var retained = Drive()
  retained.run(
    truncatedHistory(removal) + [row(false, source: removal + 11_500 * millis)],
    until: end + 500 * millis)
  #expect(retained.plays == [due])
}
@Test func evictedAndRetainedDuplicatesCannotReleaseAnUnknownEpisode() {
  let removal: UInt64 = 3_000 * millis
  let end = removal + 15_510 * millis
  for index in UInt64(0)..<12 {
    let source = removal + (30 + 1_000 * index) * millis
    for arrival in [removal + 11_500 * millis, removal + 12_500 * millis] {
      var drive = Drive()
      drive.run(
        truncatedHistory(removal) + [row(false, source: source, arrival: arrival)], until: end)
      #expect(drive.plays.isEmpty, "source=\(source), arrival=\(arrival)")
    }
  }
}
@Test func movingFirstBackDoesNotTurnItsEvidenceIntoAStop() {
  // The transition reads a row 5 ms after the count of one, as the state before it. Then later
  // rows push that row out of the history, and the count arrives: its own capture cannot see the
  // row. The annulled evidence precedes the transition, so it cannot prove a stop.
  let removal: UInt64 = 3_000 * millis
  for playing in [false, true] {
    var drive = Drive()
    let late = 12_600 * millis
    drive.run(
      [
        twoEars(),
        row(playing, source: removal + 5 * millis),
        Step(
          input: live(.transition(from: .both, to: .one), .m, at: removal + 10 * millis),
          at: removal + 11 * millis),
        row(true, source: removal + 100 * millis),
        row(true, source: 12_500 * millis),
        Step(input: live(.count(1, detection: .on), .s1, at: removal), at: late),
        Step(input: .pause(instant(nanos: removal + 20 * millis).utc), at: late + 100 * millis),
      ], until: late + 3_500 * millis)
    #expect(drive.plays.isEmpty, "playing=\(playing)")
  }
}
@Test func aStopBeforeTheTransitionDoesNotCountInEitherArrivalOrder() {
  // Moving the first signal back to the count must not attribute a prior manual pause to the
  // transition, whether the count arrives before the transition or after it.
  let removal: UInt64 = 6_000 * millis
  for countArrival in [removal, removal + 40 * millis] {
    var drive = Drive()
    drive.run(
      rerouted()
        + [row(false, source: removal + 3 * millis), row(true, source: removal + 6 * millis)]
        + removalSteps(at: removal, context: reroutedContext, countArrival: countArrival),
      until: endTime(removal) + 500 * millis)
    #expect(drive.plays.isEmpty, "countArrival=\(countArrival)")
  }
}
@Test func aManualPauseBetweenCountAndTransitionCannotReleaseTheEpisode() {
  for arrival: UInt64 in [7_000, 8_050, 8_500] {
    var drive = Drive()
    drive.run(
      rerouted() + [
        Step(
          input: live(
            .count(1, detection: .on), .s1, at: 6_000 * millis,
            context: reroutedContext), at: 6_000 * millis),
        row(false, source: 7_000 * millis, arrival: arrival * millis),
        Step(
          input: live(
            .transition(from: .both, to: .one), .m, at: 8_000 * millis,
            context: reroutedContext), at: 8_000 * millis),
        Step(input: .pause(instant(nanos: 8_020 * millis).utc), at: 8_020 * millis),
      ], until: 11_500 * millis)
    #expect(drive.plays.isEmpty, "arrival=\(arrival)")
  }
}
@Test func onlyRowsAtOrAfterTheTransitionProveAStop() {
  let removal: UInt64 = 6_000 * millis
  for (source, played): (UInt64, Bool) in [(6_009, false), (6_010, true)] {
    for (transitionArrival, rowArrival): (UInt64, UInt64) in [(6_060, 6_012), (6_010, 6_500)] {
      for countArrival: UInt64 in [6_000, 6_100] {
        var drive = Drive()
        drive.run(
          rerouted()
            + removalSteps(
              at: removal, context: reroutedContext, countArrival: countArrival * millis,
              transitionArrival: transitionArrival * millis)
            + [row(false, source: source * millis, arrival: rowArrival * millis)],
          until: endTime(removal) + 500 * millis)
        #expect(
          drive.plays == (played ? [max(dueTime(removal), rowArrival * millis)] : []),
          "source=\(source), rowArrival=\(rowArrival), countArrival=\(countArrival)")
      }
    }
  }
}
@Test func movingFirstBackKeepsAnObservedStop() {
  let removal: UInt64 = 6_000 * millis
  for countArrival: UInt64 in [6_060, 6_500] {
    var drive = Drive()
    drive.run(
      rerouted()
        + removalSteps(at: removal, context: reroutedContext, countArrival: countArrival * millis)
        + [row(false, source: removal + 32 * millis)],
      until: endTime(removal) + 500 * millis)
    #expect(drive.plays == [dueTime(removal)], "countArrival=\(countArrival)")
  }
}
@Test func onlyTheFirstRowOfASourceTimeCounts() {
  let removal: UInt64 = 6_000 * millis
  let source = removal + 15 * millis
  // Both rows before the capture of the removal, or both after it: the same result.
  for arrival: UInt64 in [removal + 16 * millis, removal + 200 * millis] {
    for (first, played) in [(true, 0), (false, 1)] {
      var drive = Drive()
      drive.run(
        rerouted()
          + [
            row(first, source: source, arrival: arrival),
            row(!first, source: source, arrival: arrival + millis),
          ]
          + removalSteps(
            at: removal, context: reroutedContext, countFirst: false,
            transitionArrival: removal + 50 * millis),
        until: endTime(removal) + 500 * millis)
      #expect(drive.plays.count == played, "first=\(first), arrival=\(arrival)")
    }
  }
}
@Test func rowOrderAndLaterPlayingRowsDoNotTakeBackAStop() {
  let removal: UInt64 = 6_000 * millis
  let signals = rerouted() + removalSteps(at: removal, context: reroutedContext)
  // Inverted order: the newer Playing row arrives first.
  var inverted = Drive()
  inverted.run(
    signals + [
      row(true, source: removal + 80 * millis, arrival: removal + 150 * millis),
      row(false, source: removal + 60 * millis, arrival: removal + 200 * millis),
    ], until: endTime(removal) + 500 * millis)
  #expect(inverted.plays == [removal + 200 * millis])
  // Playing after the stop, both before the deadline.
  var resumed = Drive()
  resumed.run(
    signals + [
      row(false, source: removal + 32 * millis), row(true, source: removal + 40 * millis),
    ],
    until: endTime(removal) + 500 * millis)
  #expect(resumed.plays == [dueTime(removal)])
  // Playing alone is not a stop.
  var playing = Drive()
  playing.run(
    signals + [row(true, source: removal + 32 * millis)], until: endTime(removal) + 500 * millis)
  #expect(playing.plays.isEmpty)
}
@Test func twoEpisodesWaitAndReleaseEachOnItsOwnFirstSignal() {
  let first: UInt64 = 6_000 * millis
  let second: UInt64 = 7_000 * millis
  let signals =
    rerouted() + removalSteps(at: first, context: reroutedContext)
    + [
      twoEars(at: 6_500 * millis, context: reroutedContext),
      Step(
        input: live(
          .transition(from: .one, to: .both), .m, at: 6_510 * millis, context: reroutedContext),
        at: 6_510 * millis),
    ]
    + removalSteps(at: second, context: reroutedContext)
  // A stop between the two signals releases the first removal only. For the second one the same
  // row is the known state before its first signal, so its own stop does not play.
  var apart = Drive()
  apart.run(
    signals + [row(false, source: 6_300 * millis), row(false, source: 7_500 * millis)],
    until: endTime(second) + 500 * millis)
  #expect(apart.plays == [6_300 * millis])
  // A stop after both is the stop of each: one Play per episode, none repeated.
  var together = Drive()
  together.run(
    signals + [row(false, source: 7_500 * millis)], until: endTime(second) + 500 * millis)
  #expect(together.plays == [7_500 * millis, 7_500 * millis])
  // Without a stop neither episode is released.
  var neither = Drive()
  neither.run(signals, until: endTime(second) + 500 * millis)
  #expect(neither.plays.isEmpty)
}
@Test func aResetDuringTheWaitEndsTheEpisode() {
  let removal: UInt64 = 6_000 * millis
  let reset = removal + 500 * millis
  let resets: [EngineInput] = [
    .route(Route(epoch: 3, deviceOrdinal: 1)),
    .connection(Connection(epoch: 3, boundary: instant(nanos: reset).utc)),
    .gap(epoch: 1, reason: .sourceUnreadable, faultTime: instant(nanos: reset).utc),
    .gap(epoch: 1, reason: .transport, faultTime: nil),
    .streamFinished(epoch: 1),
    .environment(awake: false, bluetooth: true),
    .automation(false),
    .sentinelAvailable(false),
    live(.count(0, detection: .on), .s1, at: reset, context: reroutedContext),
  ]
  for input in resets {
    var drive = Drive()
    drive.run(
      rerouted() + removalSteps(at: removal, context: reroutedContext)
        + [Step(input: input, at: reset), row(false, source: reset + 100 * millis)],
      until: endTime(removal) + 500 * millis)
    #expect(drive.plays.isEmpty, "\(input)")
  }
}
@Test func aCountOfTwoDuringTheWaitKeepsTheEpisode() {
  let removal: UInt64 = 6_000 * millis
  var drive = Drive()
  drive.run(
    rerouted() + removalSteps(at: removal, context: reroutedContext)
      + [
        twoEars(at: removal + 300 * millis, context: reroutedContext),
        row(false, source: removal + 500 * millis),
      ], until: endTime(removal) + 500 * millis)
  #expect(drive.plays == [removal + 500 * millis])
}
@Test func aKnownStateIsNotDelayedAndIgnoresTheStop() {
  let removal: UInt64 = 6_000 * millis
  // Playing: the Play leaves at its deadline, without any stop.
  var playing = Drive()
  playing.run(
    [twoEars(), row(true, source: 2_000 * millis)] + removalSteps(at: removal),
    until: endTime(removal) + 500 * millis)
  #expect(playing.plays == [dueTime(removal)])
  // Not Playing: the removal's own stop does not turn it into a Play.
  var paused = Drive()
  paused.run(
    [twoEars(), row(false, source: 2_000 * millis)] + removalSteps(at: removal)
      + [row(false, source: removal + 32 * millis)], until: endTime(removal) + 500 * millis)
  #expect(paused.plays.isEmpty)
}
/// Every run contains an earlier legitimate Play, followed by an independently decided removal.
/// That earlier removal cannot excuse a later spurious Play or conceal a missing legitimate one.
@Test func generatedRemovalEpisodesMatchTheIndependentLedger() {
  var decisions: Set<Int> = []
  var lateDecisions: Set<Int> = []
  var suppressed = 0
  var released = 0
  var waited = 0
  for seed in UInt64(1)...280 {
    let reset = seed % 7
    let unknown = seed % 5 == 0 && reset != 0
    // An unknown state whose player keeps playing: no row is ever a stop.
    let neverStopped = unknown && seed % 3 == 1
    let finalPlaying = seed % 2 == 0
    let delayed = seed % 3 == 0
    // 0: signals on time; 1: the transition arrives after post-removal rows; 2: the count and
    // the transition both arrive after them, so the first signal of the removal is late.
    let lateSignals = (seed / 2) % 3
    var context = ObservationContext.test
    var steps =
      [twoEars(), row(true, source: 2_000 * millis)]
      + removalSteps(at: 4_000 * millis)
      + [
        row(false, source: 4_032 * millis),
        Step(input: .tick, at: 4_120 * millis), twoEars(at: 4_500 * millis),
        Step(
          input: live(.transition(from: .one, to: .both), .m, at: 4_510 * millis),
          at: 4_510 * millis),
      ]
    switch reset {
    case 1:
      steps.append(
        Step(
          input: .gap(
            epoch: 1, reason: .sourceUnreadable,
            faultTime: instant(5).utc), at: 5_000 * millis))
    case 2:
      context.routeEpoch = 2
      context.connectionEpoch = 2
      steps += [
        Step(input: .route(Route(epoch: 2, deviceOrdinal: 1)), at: 5_000 * millis),
        Step(
          input: .connection(Connection(epoch: 2, boundary: instant(5).utc)),
          at: 5_000 * millis),
      ]
    case 3...6:
      if reset == 4 || reset == 5 {
        steps.append(
          Step(
            input: .gap(
              epoch: 1, reason: reset == 4 ? .transport : .clockChanged,
              faultTime: nil), at: 5_000 * millis))
      } else if reset == 6 {
        steps.append(Step(input: .streamFinished(epoch: 1), at: 5_000 * millis))
      }
      context.streamEpoch = 2
      steps += [
        Step(input: .streamStarted(epoch: 2, nonce: "second"), at: 5_010 * millis),
        Step(
          input: .heartbeat(epoch: 2, nonce: "second", sequence: 1),
          at: 5_020 * millis),
      ]
    default: break
    }
    if reset != 0 {
      steps += [
        row(
          false, source: 4_900 * millis, arrival: 5_100 * millis,
          epoch: context.streamEpoch),
        row(
          false, source: 5_000 * millis, arrival: 5_101 * millis,
          epoch: context.streamEpoch),
      ]
    }
    steps.append(twoEars(at: 5_500 * millis, context: context))
    if !unknown {
      steps += [
        row(!finalPlaying, source: 5_550 * millis, epoch: context.streamEpoch),
        row(
          finalPlaying, source: 5_999 * millis,
          arrival: (delayed ? 6_060 : 5_999) * millis, epoch: context.streamEpoch),
      ]
    }
    steps += removalSteps(
      at: 6_000 * millis, context: context, countFirst: seed % 4 != 0,
      countArrival: lateSignals == 2 ? 6_045 * millis : nil,
      transitionArrival: lateSignals == 0 ? nil : 6_048 * millis)
    for index in UInt64(0)..<(40 + seed % 40) {
      steps.append(
        row(neverStopped, source: (6_032 + index) * millis, epoch: context.streamEpoch))
    }
    if seed % 2 == 0 { steps.append(twoEars(at: 6_050 * millis, context: context)) }
    if seed % 6 == 0 {
      steps.append(
        Step(
          input: live(
            .count(1, detection: .on), .s1, at: 6_080 * millis,
            context: context), at: 6_080 * millis))
    }
    steps.append(Step(input: .tick, at: 6_120 * millis))
    var engine = readyEngine()
    var model = ReferenceModel()
    var total = 0
    for step in ordered(steps) {
      for input in [step.input, .drain] {
        let now = instant(nanos: step.at)
        let actions = engine.handle(input: input, at: now)
        let violation = model.apply(
          input, at: now, actions: actions,
          engineCount: engine.snapshot.count)
        #expect(violation == nil, "seed=\(seed), \(violation ?? "")")
        if violation != nil { return }
        total += plays(actions)
      }
    }
    let expected = unknown ? (neverStopped ? 0 : 1) : (finalPlaying ? 1 : 0)
    #expect(total == 1 + expected, "seed=\(seed)")
    decisions.insert(total - 1)
    if lateSignals == 2 { lateDecisions.insert(total - 1) }
    suppressed += model.playOracle.suppressed
    released += model.playOracle.unknownReleased
    waited += model.playOracle.unknownWaited
  }
  #expect(decisions == [0, 1])
  #expect(lateDecisions == [0, 1])
  #expect(suppressed > 0)
  #expect(released > 0 && waited > 0)
}
@Test func independentLedgerAttributesLateStopsToTheTransition() {
  var unknownOutcomes: Set<Int> = []
  var released = 0
  var waited = 0
  for (source, expected): (UInt64, Int) in [(7_000, 0), (7_999, 0), (8_000, 1), (8_032, 1)] {
    for delayed in [false, true] {
      for countArrival: UInt64 in [6_000, 8_100] {
        let steps =
          rerouted() + [
            Step(
              input: live(
                .count(1, detection: .on), .s1, at: 6_000 * millis,
                context: reroutedContext), at: countArrival * millis),
            Step(
              input: live(
                .transition(from: .both, to: .one), .m, at: 8_000 * millis,
                context: reroutedContext), at: 8_050 * millis),
            Step(input: .pause(instant(nanos: 8_020 * millis).utc), at: 8_020 * millis),
            row(false, source: source * millis, arrival: (delayed ? 8_500 : source) * millis),
            Step(input: .tick, at: 8_120 * millis),
            Step(input: .tick, at: 11_020 * millis),
          ]
        var engine = readyEngine()
        var model = ReferenceModel()
        var total = 0
        for step in ordered(steps) {
          for input in [step.input, .drain] {
            let now = instant(nanos: step.at)
            let actions = engine.handle(input: input, at: now)
            #expect(
              model.apply(input, at: now, actions: actions, engineCount: engine.snapshot.count)
                == nil,
              "source=\(source), delayed=\(delayed), countArrival=\(countArrival)")
            total += plays(actions)
          }
        }
        #expect(total == expected)
        unknownOutcomes.insert(total)
        released += model.playOracle.unknownReleased
        waited += model.playOracle.unknownWaited
      }
    }
  }
  #expect(unknownOutcomes == [0, 1])
  #expect(released > 0 && waited > 0)
}
@Test func independentLedgerDetectsMissingAndMisattributedPlays() throws {
  let steps =
    [twoEars(), row(true, source: 2_000 * millis)]
    + removalSteps(at: 4_000 * millis)
    + [
      Step(input: .tick, at: 4_120 * millis), twoEars(at: 4_500 * millis),
      Step(
        input: live(.transition(from: .one, to: .both), .m, at: 4_510 * millis),
        at: 4_510 * millis), row(false, source: 4_600 * millis),
    ]
    + removalSteps(at: 6_000 * millis) + [Step(input: .tick, at: 6_120 * millis)]
  var engine = readyEngine()
  var model = ReferenceModel()
  var earlierPlay: PlayCommand?
  var detectedMissing = false
  var detectedUnrelated = false
  for step in ordered(steps) {
    for input in [step.input, .drain] {
      let now = instant(nanos: step.at)
      let actions = engine.handle(input: input, at: now)
      if let play = actions.compactMap({ if case .play(let play) = $0 { play } else { nil } }).first
      {
        earlierPlay = play
        var missing = model
        let violation = missing.apply(
          input, at: now,
          actions: actions.filter { if case .play = $0 { false } else { true } },
          engineCount: engine.snapshot.count)
        #expect(violation?.hasPrefix("missing legitimate Play") == true)
        detectedMissing = true
      }
      if step.at == 6_120 * millis, case .tick = input {
        var unrelated = model
        let play = try #require(earlierPlay)
        let violation = unrelated.apply(
          input, at: now, actions: actions + [.play(play)],
          engineCount: engine.snapshot.count)
        #expect(violation?.hasPrefix("Play without its eligible Pause/removal") == true)
        detectedUnrelated = true
      }
      #expect(
        model.apply(
          input, at: now, actions: actions,
          engineCount: engine.snapshot.count) == nil)
    }
  }
  #expect(detectedMissing && detectedUnrelated)
}
/// Property: for any rows in any order, a known state decides by the accepted row with the greatest
/// source time before the removal, and an unknown state plays exactly when an accepted Not Playing
/// row at or after the transition is applied. The oracle is computed from the rows alone, whatever
/// their arrival order and whatever the arrival of the removal signals, and it decides at the
/// first step at or after the Play deadline, or at the row that settles a waiting removal.
@Test func playFollowsTheKnownStateOrTheObservedStop() {
  var outcomes: Set<Int> = []
  var lateOutcomes: Set<Int> = []
  var unknownOutcomes: Set<Int> = []
  let removal: UInt64 = 12_000 * millis
  for seed in UInt64(1)...400 {
    var random = seed
    func roll(_ bound: UInt64) -> UInt64 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      return (random >> 33) % bound
    }
    var rows: [Step] = []
    // Every fourth seed delivers its rows only around and after the removal: mostly unknown states.
    let aroundRemoval = seed % 4 == 1
    for _ in 0..<roll(12) {
      let arrival =
        aroundRemoval
        ? removal + roll(2_500) * millis : 1_100 * millis + roll(10_960) * millis
      let source: UInt64
      switch roll(6) {
      case 0: source = arrival + (1 + roll(2_000)) * millis
      case 1: source = arrival - min(arrival, roll(3_000) * millis)
      case 2: source = rows.randomElementSource(roll) ?? arrival
      default: source = arrival
      }
      rows.append(row(roll(2) == 0, source: source, arrival: arrival, epoch: roll(10) == 0 ? 2 : 1))
    }
    // Every third seed delivers the count and the transition after a post-removal row.
    let late = seed % 3 == 0
    if late {
      rows.append(row(roll(2) == 0, source: removal + 30 * millis, arrival: removal + 31 * millis))
    }
    let transitionArrival = late ? removal + 60 * millis : removal + 10 * millis
    let signals = removalSteps(
      at: removal, countArrival: late ? removal + 55 * millis : nil,
      transitionArrival: transitionArrival)
    let steps = ordered([twoEars()] + rows + signals)
    let due = max(removal + 120 * millis, transitionArrival)
    // Rows arrive in this order; a row is accepted when it is not from the future, is after the
    // stream start barrier and is the first one with its source time.
    var accepted: [(UInt64, Bool)] = []
    var decision: Int?
    func decide() -> Int? {
      if let before = accepted.filter({ $0.0 < removal }).max(by: { $0.0 < $1.0 }) {
        return before.1 ? 1 : 0
      }
      return accepted.contains { $0.0 >= removal + 10 * millis && !$0.1 } ? 1 : nil
    }
    for step in steps where decision == nil {
      if case .nowPlaying(let epoch, let playing, let time) = step.input, epoch == 1 {
        let source = UInt64(time.nanos - instant(0).utc.nanos)
        if source > 0, source <= step.at, !accepted.contains(where: { $0.0 == source }) {
          accepted.append((source, playing))
        }
      }
      if step.at >= due { decision = decide() }
    }
    let expected = decision ?? decide() ?? 0
    var engine = readyEngine()
    let count = playCount(steps, engine: &engine)
    #expect(count == expected, "seed=\(seed)")
    outcomes.insert(count)
    if late { lateOutcomes.insert(count) }
    if !accepted.contains(where: { $0.0 < removal }) { unknownOutcomes.insert(count) }
  }
  #expect(outcomes == [0, 1])
  #expect(lateOutcomes == [0, 1])
  #expect(unknownOutcomes == [0, 1])
}
extension Array where Element == Step {
  /// The source time of an earlier row, to build duplicates.
  fileprivate func randomElementSource(_ roll: (UInt64) -> UInt64) -> UInt64? {
    guard !isEmpty else { return nil }
    guard case .nowPlaying(_, _, let time) = self[Int(roll(UInt64(count)))].input else {
      return nil
    }
    return UInt64(time.nanos - instant(0).utc.nanos)
  }
}

// MARK: - Parser

private let nowPlayingPrefix =
  "Posting com.apple.MediaRemote.nowPlayingApplicationIsPlayingDidChange with "
private func nowPlayingRecord(
  _ message: String, process: String = "mediaremoted",
  subsystem: String = "com.apple.amp.mediaremote", category: String = "NowPlaying"
) -> LogRecord {
  LogRecord(
    timestamp: "2001-01-01T00:00:01Z", process: process, subsystem: subsystem,
    category: category, message: message)
}
@Test func onlyTheTwoExactNowPlayingRowsParse() {
  #expect(
    EarLine.parse(record: nowPlayingRecord(nowPlayingPrefix + "<Playing>")) == .playback(true))
  #expect(
    EarLine.parse(record: nowPlayingRecord(nowPlayingPrefix + "<Not Playing>")) == .playback(false))
  // Other rows of the category, in the measured shape with a fake player.
  for other in [
    "Posting com.apple.MediaRemote.nowPlayingActivePlayersIsPlayingDidChange with <Playing>",
    "Posting com.apple.MediaRemote.nowPlayingActivePlayersIsPlayingDidChange with <Not Playing>",
    "[MRDNowPlayingPlayerClient] PlaybackState changed from Playing to Paused for 【 LOCL (Mac) ❯ "
      + "com.example.player (1) Player ❯ default 】",
    "[MRDNowPlayingPlayerClient] isPlaying changed to false for 【 LOCL (Mac) ❯ "
      + "com.example.player (1) Player ❯ default 】",
    "",
  ] {
    #expect(EarLine.parse(record: nowPlayingRecord(other)) == .unrelated, "\(other)")
  }
  for value in [
    "<Paused>", "<playing>", "<Not playing>", "<NotPlaying>", "<>", "<private>", "Playing",
    " <Playing>", "<Playing> ", "<Playing>\n", "<Playing><Playing>", "<Not Playing> extra",
  ] {
    #expect(
      EarLine.parse(record: nowPlayingRecord(nowPlayingPrefix + value)) == .unrelated, "\(value)")
  }
  for exact in [nowPlayingPrefix + "<Playing>", nowPlayingPrefix + "<Not Playing>"] {
    let characters = Array(exact)
    for end in 0..<characters.count {
      let truncated = String(characters[..<end])
      #expect(EarLine.parse(record: nowPlayingRecord(truncated)) == .unrelated, "end=\(end)")
    }
    // The exact text under another process, subsystem or category is not this row.
    #expect(EarLine.parse(record: nowPlayingRecord(exact, process: "bluetoothd")) == .unrelated)
    #expect(
      EarLine.parse(record: nowPlayingRecord(exact, subsystem: "com.apple.bluetooth")) == .unrelated
    )
    #expect(EarLine.parse(record: nowPlayingRecord(exact, category: "MediaRemote")) == .unrelated)
    #expect(EarLine.parse(record: nowPlayingRecord(exact, category: "RemoteControl")) == .unrelated)
  }
}
@Test func nowPlayingRowsLeaveTheHistorySnapshotUnchanged() throws {
  let address = "00:11:22:33:44:55"
  let state = LogRecord(
    timestamp: "2001-01-01T00:00:02Z", process: "bluetoothd", subsystem: "com.apple.bluetooth",
    category: "Server.AACP",
    message:
      "received in-ear state update from device \(address) primary bud state = in ear, "
      + "secondary bud state = in ear")
  let rows = ["2001-01-01T00:00:01Z", "2001-01-01T00:00:03Z"].map {
    LogRecord(
      timestamp: $0, process: "mediaremoted", subsystem: "com.apple.amp.mediaremote",
      category: "NowPlaying", message: nowPlayingPrefix + "<Not Playing>")
  }
  let context = HistoryContext(
    address: address, connection: "2001-01-01T00:00:00Z", readTime: "2001-01-01T00:00:04Z",
    complete: true)
  let plain = HistorySnapshot.select(records: [state], context: context)
  #expect(plain != .unknown)
  #expect(HistorySnapshot.select(records: [rows[0], state, rows[1]], context: context) == plain)
}
@Test func diaryRecordsTheNowPlayingInputInContract() throws {
  let input = EngineInput.nowPlaying(epoch: 1, playing: false, sourceTime: instant(1).utc)
  let record = TraceRecord(
    build: String(repeating: "a", count: 64), run: 1, seq: 2, m: 1_000_000_000,
    payload: .input(InputPayload(utc: instant(1).utc, input: input)))
  let data = try JSONEncoder().encode(record)
  #expect(try TraceRecord.decode(data) == record)
  var stale = record
  stale.payload = .input(
    InputPayload(
      utc: instant(1).utc,
      input: .nowPlaying(epoch: 0, playing: true, sourceTime: instant(1).utc)))
  #expect(throws: (any Error).self) { try TraceRecord.decode(JSONEncoder().encode(stale)) }
}
