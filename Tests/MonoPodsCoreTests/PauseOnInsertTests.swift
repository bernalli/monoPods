import Foundation
import Testing

@testable import MonoPodsCore

// macOS sends Play when an earbud goes in, also to a player the user stopped. The app cannot
// prevent it, so it undoes it. Times come from a measured session on 2026-11-08; values are fake.
// All times in this file are milliseconds from the test epoch.

private let nanosPerMilli: UInt64 = 1_000_000
private let reroutedContext = ObservationContext(
  routeEpoch: 2, streamEpoch: 1, connectionEpoch: 2, deviceOrdinal: 1)

private struct Step {
  var input: EngineInput
  var at: UInt64
}
private func moment(_ millis: UInt64) -> Instant { instant(nanos: millis * nanosPerMilli) }
private func ear(
  _ from: EarStatus, _ to: EarStatus, at source: UInt64, arrival: UInt64? = nil,
  context: ObservationContext = .test
) -> Step {
  let received = arrival ?? source
  return Step(
    input: .observation(
      Observation(
        sourceTime: moment(source).utc, source: .m, provenance: .live, context: context,
        receivedContinuousNanos: received * nanosPerMilli,
        value: .transition(from: from, to: to))),
    at: received)
}
private func buds(_ value: Int?, at time: UInt64, context: ObservationContext = .test) -> Step {
  Step(
    input: .observation(
      Observation(
        sourceTime: moment(time).utc, source: .s1, provenance: .live, context: context,
        receivedContinuousNanos: time * nanosPerMilli,
        value: .count(value, detection: value == nil ? .unknown : .on))),
    at: time)
}
private func row(_ playing: Bool, at source: UInt64, arrival: UInt64? = nil) -> Step {
  Step(
    input: .nowPlaying(epoch: 1, playing: playing, sourceTime: moment(source).utc),
    at: arrival ?? source)
}
/// A Pause received by the silent client: from macOS at a removal, or the echo of one of the app.
private func pauseIn(at time: UInt64) -> Step {
  Step(input: .pause(moment(time).utc), at: time)
}
private func rerouted(at time: UInt64 = 3_000) -> [Step] {
  [
    buds(2, at: 1_000),
    Step(input: .route(Route(epoch: 2, deviceOrdinal: 1)), at: time),
    Step(input: .connection(Connection(epoch: 2, boundary: moment(time).utc)), at: time),
    buds(2, at: time + 1_000, context: reroutedContext),
  ]
}

/// Drives the engine as the runtime does: a drain after every input, a tick at every deadline, a
/// reply to every heartbeat. Records the instants of the Pauses and of the Plays.
private struct Session {
  var engine = readyEngine()
  var pauses: [UInt64] = []
  var plays: [UInt64] = []
  private var clock: UInt64 = 0

  private mutating func send(_ input: EngineInput, at millis: UInt64) {
    let actions = engine.handle(input: input, at: moment(millis))
    for action in actions {
      switch action {
      case .pause: pauses.append(millis)
      case .play: plays.append(millis)
      case .emitHeartbeat(let epoch, let nonce, let sequence):
        send(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence), at: millis)
      default: break
      }
    }
  }
  private mutating func advance(to target: UInt64) {
    while let deadline = engine.nextDeadline, deadline <= target * nanosPerMilli {
      let millis = (deadline + nanosPerMilli - 1) / nanosPerMilli
      if millis < clock { break }
      clock = millis
      let before = engine.nextDeadline
      send(.tick, at: millis)
      if engine.nextDeadline == before { break }
    }
    clock = max(clock, target)
  }
  mutating func run(_ steps: [Step], until end: UInt64) {
    let sorted = steps.enumerated().sorted {
      ($0.element.at, $0.offset) < ($1.element.at, $1.offset)
    }
    for step in sorted.map(\.element) {
      advance(to: step.at)
      send(step.input, at: step.at)
      send(.drain, at: step.at)
    }
    advance(to: end)
  }
}
private func session(_ steps: [Step], until end: UInt64) -> Session {
  var session = Session()
  session.run(steps, until: end)
  return session
}

// MARK: - The measured session

@Test func theMeasuredSessionUndoesTheResumeTwiceAndNeverPlays() {
  // 15:27:00.246 is 22 s here. All the offsets below are those of the log.
  let base: UInt64 = 22_000
  let entry = base + 365_653
  let resume = base + 365_846
  let measured = [
    buds(2, at: 1_000),
    row(true, at: base - 20_059),
    row(false, at: base),
    buds(1, at: base + 20_600),
    ear(.both, .one, at: base + 20_616),
    pauseIn(at: base + 20_662),
    row(true, at: base + 56_695),
    row(false, at: base + 58_209),
    buds(2, at: entry - 13),
    ear(.one, .both, at: entry),
    row(true, at: resume),
    row(false, at: base + 395_925),
  ]
  let plain = session(measured, until: base + 400_000)
  #expect(plain.pauses == [entry, resume])
  #expect(plain.plays.isEmpty)
  // The same session with the echoes of the two Pauses.
  let echoed = session(
    measured + [pauseIn(at: entry + 15), pauseIn(at: resume + 15)], until: base + 400_000)
  #expect(echoed.pauses == [entry, resume])
  #expect(echoed.plays.isEmpty)
}
@Test func aSystemPlayWithoutEffectGetsOnePauseOnly() {
  // Measured at 12:00:34: the Play of macOS leaves Not Playing in place.
  let result = session(
    [buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: 20_000)], until: 30_000)
  #expect(result.pauses == [20_000])
  #expect(result.plays.isEmpty)
}

// MARK: - Whose stop

@Test func aStopThatARemovalCausedIsNotTheStopOfTheUser() {
  for delay: UInt64 in [32, 45, 135] {
    for (from, to, back): (EarStatus, EarStatus, EarStatus) in [
      (.both, .none, .both), (.both, .none, .one), (.one, .none, .one), (.both, .one, .both),
    ] {
      let removal: UInt64 = 10_000
      let insertion = removal + 600_000
      let result = session(
        [
          buds(2, at: 1_000), row(true, at: 2_000),
          ear(from, to, at: removal), row(false, at: removal + delay),
          buds(back == .both ? 2 : 1, at: insertion - 13),
          ear(to, back, at: insertion),
        ], until: insertion + 3_000)
      #expect(result.pauses.isEmpty, "\(from)->\(to)->\(back), delay=\(delay)")
    }
  }
}
@Test func aRemovalPlayThenBothOutThenBackLeavesTheResumeAlone() {
  let removal: UInt64 = 10_000
  let result = session(
    [
      buds(2, at: 1_000), row(true, at: 2_000),
      buds(1, at: removal), ear(.both, .one, at: removal + 10), pauseIn(at: removal + 20),
      row(false, at: removal + 32), row(true, at: removal + 200),
      buds(0, at: removal + 5_000), ear(.one, .none, at: removal + 5_010),
      row(false, at: removal + 5_042),
      buds(1, at: removal + 300_000), ear(.none, .one, at: removal + 300_010),
      row(true, at: removal + 300_200),
    ], until: removal + 310_000)
  #expect(result.plays == [removal + 120])
  #expect(result.pauses.isEmpty)
}
@Test func theStopBelongsToARemovalOnlyWithinTheConstantAndNotBeforeIt() {
  let removal: UInt64 = 10_000
  for (source, paused): (UInt64, Bool) in [
    (removal - 1, true), (removal, false), (removal + 999, false), (removal + 1_000, true),
  ] {
    let result = session(
      [
        buds(2, at: 1_000), row(true, at: 2_000), ear(.both, .none, at: removal),
        row(false, at: source), buds(1, at: 30_000), ear(.none, .one, at: 30_000),
      ], until: 40_000)
    #expect(result.pauses == (paused ? [30_000] : []), "source=\(source)")
  }
}
@Test func aRemovalSignalAfterItsStopStillClaimsIt() {
  // The row of mediaremoted and the row of the removal can cross on the way to the engine.
  let result = session(
    [
      buds(2, at: 1_000), row(true, at: 2_000),
      row(false, at: 10_032, arrival: 10_040),
      ear(.both, .none, at: 10_000, arrival: 10_050),
      buds(1, at: 30_000), ear(.none, .one, at: 30_000),
    ], until: 40_000)
  #expect(result.pauses.isEmpty)
}
@Test func aRemovalKeepsItsStopAcrossLaterEventsWithoutRows() {
  let result = session(
    [
      buds(2, at: 1_000), row(true, at: 2_000),
      ear(.both, .none, at: 10_000), row(false, at: 10_032),
      buds(1, at: 100_000), ear(.none, .one, at: 100_000),
      buds(0, at: 200_000), ear(.one, .none, at: 200_000),
      buds(1, at: 300_000), ear(.none, .one, at: 300_000),
    ], until: 310_000)
  #expect(result.pauses.isEmpty)
}

// MARK: - The guard

@Test func aKnownPlayingPlayerGetsNoPause() {
  let result = session(
    [buds(2, at: 1_000), row(true, at: 2_000), ear(.one, .both, at: 20_000)], until: 30_000)
  #expect(result.pauses.isEmpty)
}
@Test func aPlayingRowCountsOnlyInsideTheGuard() {
  let entry: UInt64 = 20_000
  let prefix = [buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry)]
  for (source, arrival, second): (UInt64, UInt64, Bool) in [
    (entry, entry, true),
    (entry + 1_499, entry + 1_499, true),
    // The user presses Play after the guard: the content plays.
    (entry + 1_500, entry + 1_500, false),
    (entry + 5_000, entry + 5_000, false),
    // Inside by source time, late by arrival.
    (entry + 100, entry + 1_499, true),
    (entry + 100, entry + 1_500, false),
    // Before the transition, whenever it arrives.
    (entry - 1, entry + 100, false),
  ] {
    let result = session(prefix + [row(true, at: source, arrival: arrival)], until: entry + 10_000)
    #expect(
      result.pauses == (second ? [entry, arrival] : [entry]),
      "source=\(source), arrival=\(arrival)")
    #expect(result.plays.isEmpty)
  }
}
@Test func aLateTransitionOpensItsGuardFromItsSourceTime() {
  // The guard ends 1.5 s after the original entry, including transport delay.
  let entry: UInt64 = 20_000
  let arrival = entry + 1_400
  for (source, second): (UInt64, Bool) in [(entry + 1_499, true), (entry + 1_500, false)] {
    let result = session(
      [
        buds(2, at: 1_000), row(false, at: 2_000),
        ear(.one, .both, at: entry, arrival: arrival), row(true, at: source),
      ], until: entry + 10_000)
    #expect(result.pauses == (second ? [arrival, source] : [arrival]), "source=\(source)")
  }
}
@Test func everyDistinctPlayingRowInsideTheGuardGetsAPause() {
  let entry: UInt64 = 20_000
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry),
      row(true, at: entry + 100), row(true, at: entry + 100, arrival: entry + 110),
      row(false, at: entry + 150), row(true, at: entry + 190),
    ], until: entry + 10_000)
  #expect(result.pauses == [entry, entry + 100, entry + 190])
}

// MARK: - Unknown player state

@Test func anUnknownStateWithoutARemovalGetsNoPause() {
  for (from, to) in [(EarStatus.one, EarStatus.both), (.none, .one), (.none, .both)] {
    let result = session(
      rerouted() + [ear(from, to, at: 9_000, context: reroutedContext)], until: 15_000)
    #expect(result.pauses.isEmpty, "\(from)->\(to)")
  }
}
/// A removal with its Pause, on a route that left the player state unknown.
private func unknownRemoval(at removal: UInt64) -> [Step] {
  rerouted() + [
    buds(1, at: removal, context: reroutedContext),
    ear(.both, .one, at: removal + 10, context: reroutedContext),
    pauseIn(at: removal + 20),
  ]
}
@Test func aRemovalWithoutAStopProvesAStoppedPlayerOnlyAfterItsEpisode() {
  let removal: UInt64 = 6_000
  let end = removal + 3_020
  for (entry, paused): (UInt64, Bool) in [(end - 1, false), (end, true), (end + 60_000, true)] {
    let result = session(
      unknownRemoval(at: removal) + [
        buds(2, at: entry - 1, context: reroutedContext),
        ear(.one, .both, at: entry, context: reroutedContext),
      ], until: entry + 5_000)
    #expect(result.pauses == (paused ? [entry] : []), "entry=\(entry)")
    #expect(result.plays.isEmpty, "entry=\(entry)")
  }
}
@Test func aStopOrAPlayingRowInTheEpisodeLeavesNoDeduction() {
  let removal: UInt64 = 6_000
  let entry = removal + 5_000
  let inward = [
    buds(2, at: entry - 1, context: reroutedContext),
    ear(.one, .both, at: entry, context: reroutedContext),
  ]
  let stopped = session(
    unknownRemoval(at: removal) + [row(false, at: removal + 42)] + inward, until: entry + 5_000)
  #expect(stopped.pauses.isEmpty)
  #expect(stopped.plays == [removal + 120])
  let playing = session(
    unknownRemoval(at: removal) + [row(true, at: removal + 42)] + inward, until: entry + 5_000)
  #expect(playing.pauses.isEmpty)
  #expect(playing.plays.isEmpty)
}
@Test func aNewRowOrAResetEndsTheDeduction() {
  let removal: UInt64 = 6_000
  let after = removal + 5_000
  let entry = removal + 8_000
  let inward = [
    buds(2, at: entry - 1, context: reroutedContext),
    ear(.one, .both, at: entry, context: reroutedContext),
  ]
  // A Playing row after the episode: the state is known.
  let playing = session(
    unknownRemoval(at: removal) + [row(true, at: after)] + inward, until: entry + 5_000)
  #expect(playing.pauses.isEmpty)
  // A row newer than the transition does not say what came before it.
  let newer = session(
    unknownRemoval(at: removal) + [row(false, at: entry + 1, arrival: entry + 1)]
      + [
        buds(2, at: entry - 1, context: reroutedContext),
        ear(.one, .both, at: entry, arrival: entry + 2, context: reroutedContext),
      ], until: entry + 5_000)
  #expect(newer.pauses.isEmpty)
  // A Not Playing row after the episode: the first rule decides.
  let stopped = session(
    unknownRemoval(at: removal) + [row(false, at: after)] + inward, until: entry + 5_000)
  #expect(stopped.pauses == [entry])
  // Resets, each followed by what the context then needs.
  let unreadable = EngineInput.gap(
    epoch: 1, reason: .sourceUnreadable, faultTime: moment(after).utc)
  let resets: [[Step]] = [
    [Step(input: .connection(Connection(epoch: 3, boundary: moment(after).utc)), at: after)],
    [Step(input: unreadable, at: after)],
    [buds(nil, at: after, context: reroutedContext)],
    [Step(input: .automation(false), at: after), Step(input: .automation(true), at: after)],
    [
      Step(input: .environment(awake: false, bluetooth: true), at: after),
      Step(input: .environment(awake: true, bluetooth: true), at: after),
    ],
  ]
  for (index, reset) in resets.enumerated() {
    let context =
      index == 0
      ? ObservationContext(routeEpoch: 2, streamEpoch: 1, connectionEpoch: 3, deviceOrdinal: 1)
      : reroutedContext
    let result = session(
      unknownRemoval(at: removal) + reset + [
        buds(2, at: entry - 1, context: context),
        ear(.one, .both, at: entry, context: context),
      ], until: entry + 5_000)
    #expect(result.pauses.isEmpty, "reset \(index)")
  }
}

// MARK: - Gates

@Test func noPauseWithoutTheControlsOfThePlay() {
  let entry: UInt64 = 20_000
  let off: [[Step]] = [
    [Step(input: .automation(false), at: entry - 5)],
    [Step(input: .sentinelAvailable(false), at: entry - 5)],
    [Step(input: .environment(awake: false, bluetooth: true), at: entry - 5)],
    [Step(input: .environment(awake: true, bluetooth: false), at: entry - 5)],
    [buds(nil, at: entry - 5)],
    [buds(0, at: entry - 5)],
    [Step(input: .route(nil), at: entry - 5)],
  ]
  for (index, gate) in off.enumerated() {
    let result = session(
      [buds(2, at: 1_000), row(false, at: 2_000)] + gate + [
        ear(.one, .both, at: entry), row(true, at: entry + 193),
      ], until: entry + 5_000)
    #expect(result.pauses.isEmpty, "gate \(index)")
  }
  // Inside the guard the same controls stop the second Pause.
  for (index, gate) in off.enumerated() {
    let moved = gate.map { Step(input: $0.input, at: entry + 100) }
    var steps = [buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry)] + moved
    steps.append(row(true, at: entry + 193))
    let result = session(steps, until: entry + 5_000)
    #expect(result.pauses == [entry], "gate \(index)")
  }
}
@Test func aHistoryThatLostTheTimeOfTheTransitionDecidesNothing() {
  // The transition arrives more than the history window after its source time.
  var steps = [buds(2, at: 1_000), row(false, at: 2_000)]
  for second in UInt64(3)...15 { steps.append(row(false, at: second * 1_000)) }
  steps.append(ear(.one, .both, at: 3_500, arrival: 15_500))
  #expect(session(steps, until: 20_000).pauses.isEmpty)
}

// MARK: - The Pause of the app

@Test func theEchoAfterARemovalMsBeforeCreatesNoPlay() {
  let entry: UInt64 = 20_000
  for gap: UInt64 in [1, 5, 50] {
    let result = session(
      [
        buds(2, at: 1_000), row(false, at: 2_000), ear(.both, .one, at: entry - gap),
        ear(.one, .both, at: entry), pauseIn(at: entry + 10), pauseIn(at: entry + 20),
      ], until: entry + 10_000)
    #expect(result.pauses == [entry], "gap=\(gap)")
    #expect(result.plays.isEmpty, "gap=\(gap)")
  }
}
@Test func theEchoOfTheSecondPauseIsCoveredAfterTheGuardEnds() {
  // Playing is the last row, so an episode that paired with the removal below would send a Play.
  let entry: UInt64 = 20_000
  let second = entry + 1_400
  for (time, play): (UInt64, Bool) in [(second + 499, false), (second + 500, true)] {
    let result = session(
      [
        buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry),
        row(true, at: second), ear(.both, .one, at: time - 10), pauseIn(at: time),
      ], until: entry + 10_000)
    #expect(result.pauses == [entry, second], "time=\(time)")
    #expect(result.plays == (play ? [time + 100] : []), "time=\(time)")
  }
}
@Test func theStopThatAnswersThePauseReleasesNoWaitingEpisode() {
  // The deduction holds and a new removal waits for a stop: the row after the Pause of the app
  // would be that stop.
  let removal: UInt64 = 6_000
  let first = removal + 5_000
  let second = first + 3_000
  let result = session(
    unknownRemoval(at: removal) + [
      buds(2, at: first - 1, context: reroutedContext),
      ear(.one, .both, at: first, context: reroutedContext),
      buds(1, at: first + 2_000, context: reroutedContext),
      ear(.both, .one, at: first + 2_010, context: reroutedContext),
      pauseIn(at: first + 2_020),
      buds(2, at: second - 1, context: reroutedContext),
      ear(.one, .both, at: second, context: reroutedContext),
      row(true, at: second + 193),
      row(false, at: second + 210),
    ], until: second + 10_000)
  #expect(result.pauses == [first, second, second + 193])
  #expect(result.plays.isEmpty)
}
@Test func fumblingAnEarbudKeepsTheStopOfTheUser() {
  // The stop that answers the Pause falls within the constant of the removal before it.
  let removal: UInt64 = 20_000
  let first = removal + 500
  let again = first + 800
  let second = again + 500
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000),
      ear(.both, .one, at: removal), pauseIn(at: removal + 40),
      ear(.one, .both, at: first), row(true, at: first + 193), row(false, at: first + 210),
      ear(.both, .one, at: again), pauseIn(at: again + 40),
      ear(.one, .both, at: second), row(true, at: second + 193), row(false, at: second + 210),
    ], until: second + 10_000)
  #expect(result.pauses == [first, first + 193, second, second + 193])
  #expect(result.plays.isEmpty)
}

// MARK: - Hostile order

@Test func aResumeSeenBeforeALateTransitionDoesNotConsumeTheGuard() {
  let entry: UInt64 = 20_000
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), row(true, at: entry + 193, arrival: entry + 200),
      ear(.one, .both, at: entry, arrival: entry + 250),
      row(true, at: entry + 300),
    ], until: entry + 10_000)
  #expect(result.pauses == [entry + 250, entry + 300])
}
@Test func rowsThatArriveLateDoNotChangeADecisionTaken() {
  let entry: UInt64 = 20_000
  // A stop before the transition arrives after it: the player was known to be playing.
  let stop = session(
    [
      buds(2, at: 1_000), row(true, at: 2_000), ear(.one, .both, at: entry),
      row(false, at: entry - 100, arrival: entry + 50),
    ], until: entry + 10_000)
  #expect(stop.pauses.isEmpty)
  // A Playing row before the transition arrives after it: no second Pause.
  let play = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry),
      row(true, at: entry - 100, arrival: entry + 50),
    ], until: entry + 10_000)
  #expect(play.pauses == [entry])
}
@Test func onlyTheFirstRowOfASourceTimeSaysWhatTheUserDid() {
  let entry: UInt64 = 20_000
  for (first, paused) in [(false, true), (true, false)] {
    let result = session(
      [
        buds(2, at: 1_000), row(first, at: 2_000), row(!first, at: 2_000, arrival: 2_100),
        ear(.one, .both, at: entry),
      ], until: entry + 10_000)
    #expect(result.pauses == (paused ? [entry] : []), "first=\(first)")
  }
}
@Test func repeatedTransitionsGiveOnePause() {
  let entry: UInt64 = 20_000
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry),
      // The same source time, an older one, and a newer one with the same status.
      ear(.one, .both, at: entry, arrival: entry + 10),
      ear(.one, .both, at: entry - 100, arrival: entry + 20),
      ear(.one, .both, at: entry + 30),
      ear(.none, .both, at: entry + 40),
    ], until: entry + 10_000)
  #expect(result.pauses == [entry])
}
@Test func twoEntriesInARowAreUndoneOneByOne() {
  let first: UInt64 = 20_000
  let second = first + 1_000
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000),
      ear(.none, .one, at: first), row(true, at: first + 193), row(false, at: first + 210),
      ear(.one, .both, at: second), row(true, at: second + 193), row(false, at: second + 210),
    ], until: second + 10_000)
  #expect(result.pauses == [first, first + 193, second, second + 193])
  #expect(result.plays.isEmpty)
}
@Test func aSecondEntryBeforeTheAnswerToTheFirstStillSeesTheStopOfTheUser() {
  // The last row before the second entry is the resume that the guard caught.
  let first: UInt64 = 20_000
  let second = first + 200
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000),
      ear(.none, .one, at: first), row(true, at: first + 193),
      ear(.one, .both, at: second), row(false, at: second + 10), row(true, at: second + 193),
    ], until: second + 10_000)
  #expect(result.pauses == [first, first + 193, second, second + 193])
}
@Test func aResetDuringTheGuardEndsIt() {
  let entry: UInt64 = 20_000
  let reset = entry + 100
  let back = entry + 150
  let connected = ObservationContext(
    routeEpoch: 1, streamEpoch: 1, connectionEpoch: 3, deviceOrdinal: 1)
  let moved = ObservationContext(
    routeEpoch: 3, streamEpoch: 1, connectionEpoch: 3, deviceOrdinal: 1)
  // Each reset, then what brings the controls back: only the reset can stop the second Pause.
  let resets: [[Step]] = [
    [
      Step(input: .connection(Connection(epoch: 3, boundary: moment(reset).utc)), at: reset),
      buds(2, at: back, context: connected),
    ],
    [
      Step(
        input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: moment(reset).utc), at: reset),
      buds(2, at: back),
    ],
    [buds(nil, at: reset), buds(2, at: back)],
    [
      Step(input: .automation(false), at: reset), Step(input: .automation(true), at: reset),
      buds(2, at: back),
    ],
    [
      Step(input: .environment(awake: false, bluetooth: true), at: reset),
      Step(input: .environment(awake: true, bluetooth: true), at: reset),
      buds(2, at: back),
    ],
    [
      Step(input: .route(Route(epoch: 3, deviceOrdinal: 1)), at: reset),
      Step(input: .connection(Connection(epoch: 3, boundary: moment(reset).utc)), at: reset),
      buds(2, at: back, context: moved),
    ],
    [Step(input: .gap(epoch: 1, reason: .transport, faultTime: nil), at: reset)],
    [Step(input: .gap(epoch: 1, reason: .clockChanged, faultTime: nil), at: reset)],
    [Step(input: .streamFinished(epoch: 1), at: reset)],
    [Step(input: .streamStarted(epoch: 2, nonce: "second"), at: reset)],
  ]
  for (index, steps) in resets.enumerated() {
    let result = session(
      [buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry)] + steps
        + [row(true, at: entry + 193)], until: entry + 5_000)
    #expect(result.pauses == [entry], "reset \(index)")
    #expect(result.plays.isEmpty, "reset \(index)")
  }
}
@Test func theEchoAfterAResetStillCreatesNoEpisode() {
  // The Pause is on its way when the gap resets the guard; only time ends the echo window. The gap
  // also forgets the player, so an episode paired with this removal would be released by the stop.
  let entry: UInt64 = 20_000
  let gap = entry + 100
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: entry),
      Step(input: .gap(epoch: 1, reason: .sourceUnreadable, faultTime: moment(gap).utc), at: gap),
      buds(2, at: gap + 10), ear(.both, .one, at: gap + 20), pauseIn(at: gap + 30),
      row(false, at: gap + 50),
    ], until: entry + 10_000)
  #expect(result.pauses == [entry])
  #expect(result.plays.isEmpty)
}
@Test func aPauseOlderThanTheHistoryWindowIsStillTheStopOfTheUser() {
  // Four minutes, far beyond the window: the row is the retained background state.
  let entry: UInt64 = 240_000
  let silent = session(
    [buds(2, at: 1_000), row(true, at: 1_500), row(false, at: 2_000), ear(.one, .both, at: entry)],
    until: entry + 5_000)
  #expect(silent.pauses == [entry])
  // The same with rows that push it out of the window, then a transition after all of them.
  var steps = [buds(2, at: 1_000), row(true, at: 1_500), row(false, at: 2_000)]
  for second in UInt64(3)...20 { steps.append(row(second % 2 == 0, at: second * 1_000)) }
  steps += [row(false, at: 21_000), ear(.one, .both, at: entry)]
  #expect(session(steps, until: entry + 5_000).pauses == [entry])
}

// MARK: - The independent oracle

/// Aims the hostile alphabet at the rule: rows, removals and entries around one another, with the
/// echo of each Pause, and a reset now and then.
@Test func generatedEntriesMatchTheIndependentOracle() {
  var interventions = 0
  var byDeduction = 0
  var declined = 0
  var resumesCaught = 0
  var plays = 0
  for seed in UInt64(1)...400 {
    var random = seed &* 2_654_435_761
    func roll(_ bound: UInt64) -> UInt64 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      return (random >> 33) % bound
    }
    var engine = readyEngine()
    var model = ReferenceModel()
    var echoes: [UInt64] = []
    var clock: UInt64 = 2_000
    let rowsAtAll = seed % 5 != 0
    func apply(_ input: EngineInput, at nanos: UInt64) -> Bool {
      var queue = [input]
      while !queue.isEmpty {
        let next = queue.removeFirst()
        let now = instant(nanos: nanos)
        let actions = engine.handle(input: next, at: now)
        let violation = model.apply(
          next, at: now, actions: actions, engineCount: engine.snapshot.count)
        #expect(violation == nil, "seed=\(seed), \(next), \(violation ?? "")")
        if violation != nil { return false }
        for action in actions {
          switch action {
          case .pause: echoes.append(nanos + 15 * nanosPerMilli)
          case .play: plays += 1
          case .emitHeartbeat(let epoch, let nonce, let sequence):
            queue.append(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence))
          case .persist(let request):
            queue.append(.persistenceAcknowledged(run: 1, id: request.id, success: true))
          default: break
          }
        }
      }
      return true
    }
    steps: for _ in 0..<160 {
      // Steps from a few ms, for the races, to 2.5 s, so that some episodes and guards end.
      let spread: [UInt64] = [5, 50, 200, 700, 2_500]
      clock += 1 + roll(spread[Int(roll(5))])
      let nanos = clock * nanosPerMilli
      let now = instant(nanos: nanos)
      func ears(_ from: EarStatus, _ to: EarStatus, back: UInt64 = 0) -> EngineInput {
        .observation(
          Observation(
            sourceTime: instant(nanos: nanos - back * nanosPerMilli).utc, source: .m,
            provenance: .live, context: model.context ?? .test,
            receivedContinuousNanos: nanos, value: .transition(from: from, to: to)))
      }
      func count(_ value: Int) -> EngineInput {
        .observation(
          Observation(
            sourceTime: now.utc, source: .s1, provenance: .live, context: model.context ?? .test,
            receivedContinuousNanos: nanos, value: .count(value, detection: .on)))
      }
      var inputs: [EngineInput] = []
      while let echo = echoes.first, echo <= nanos {
        echoes.removeFirst()
        inputs.append(.pause(now.utc))
      }
      switch roll(16) {
      case 0: inputs += [count(1), ears(.both, .one, back: roll(40))]
      case 1: inputs += [count(1), ears(.both, .one), .pause(now.utc)]
      case 2: inputs += [count(0), ears(.one, .none)]
      case 3: inputs += [count(0), ears(.both, .none)]
      case 4: inputs += [count(2), ears(.one, .both)]
      case 5: inputs += [count(2), ears(.one, .both, back: roll(40))]
      case 6: inputs += [ears(.none, .one), count(1)]
      case 7: inputs += [ears(.none, .both), count(2)]
      case 8, 9, 10:
        if rowsAtAll {
          let back = min(roll(3) == 0 ? roll(400) : 0, clock - 1)
          inputs.append(
            .nowPlaying(
              epoch: model.streamEpoch, playing: roll(2) == 0,
              sourceTime: instant(nanos: nanos - back * nanosPerMilli).utc))
        }
      case 11: inputs.append(.tick)
      case 12:
        if roll(8) == 0 {
          inputs.append(
            .connection(
              Connection(
                epoch: model.connectionHighWater + 1,
                boundary: instant(nanos: nanos - 20 * nanosPerMilli).utc)))
        }
      case 14: inputs.append(ears(.none, .one))
      case 15: inputs.append(ears(.one, .both))
      default:
        if rowsAtAll, let last = model.playOracle.rows.last, roll(4) == 0 {
          inputs.append(
            .nowPlaying(epoch: model.streamEpoch, playing: !last.playing, sourceTime: last.time))
        }
      }
      inputs.append(.drain)
      for input in inputs where !apply(input, at: nanos) { break steps }
    }
    interventions += model.playOracle.interventions
    byDeduction += model.playOracle.interventionsByDeduction
    declined += model.playOracle.declined
    resumesCaught += model.playOracle.resumesCaught
  }
  // Each outcome of the rule must be reached, or the property proves nothing.
  #expect(interventions > 0 && byDeduction > 0 && declined > 0 && resumesCaught > 0 && plays > 0)
}
@Test func theOracleDetectsAMissingAndAnUnjustifiedPause() {
  var engine = readyEngine()
  var model = ReferenceModel()
  func feed(_ input: EngineInput, at millis: UInt64) -> [EngineAction] {
    let actions = engine.handle(input: input, at: moment(millis))
    #expect(
      model.apply(input, at: moment(millis), actions: actions, engineCount: engine.snapshot.count)
        == nil)
    return actions
  }
  _ = feed(buds(2, at: 3_000).input, at: 3_000)
  // The player plays: a Pause here has no stop of the user to protect.
  _ = feed(row(true, at: 4_000).input, at: 4_000)
  let declined = ear(.one, .both, at: 5_000)
  let none = engine.handle(input: declined.input, at: moment(5_000))
  var unjustified = model
  #expect(
    unjustified.apply(
      declined.input, at: moment(5_000), actions: none + [.pause(context: .test)],
      engineCount: engine.snapshot.count)?.hasPrefix("Pause without") == true)
  #expect(
    model.apply(
      declined.input, at: moment(5_000), actions: none, engineCount: engine.snapshot.count)
      == nil)
  // The user stops it: the Pause at the next entry is owed.
  _ = feed(row(false, at: 6_000).input, at: 6_000)
  _ = feed(ear(.both, .one, at: 7_000).input, at: 7_000)
  let owed = ear(.one, .both, at: 7_500)
  let actions = engine.handle(input: owed.input, at: moment(7_500))
  #expect(actions.contains(.pause(context: .test)))
  var missing = model
  #expect(
    missing.apply(
      owed.input, at: moment(7_500),
      actions: actions.filter { $0 != .pause(context: .test) },
      engineCount: engine.snapshot.count)?.hasPrefix("missing Pause") == true)
  #expect(
    model.apply(owed.input, at: moment(7_500), actions: actions, engineCount: engine.snapshot.count)
      == nil)
}

// MARK: - Echo accounting and delayed controls

@Test func aConsumedEchoDoesNotHideTheNextRemovalPause() {
  for delay: UInt64 in [0, 30] {
    let result = session(
      [
        buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: 20_000),
        pauseIn(at: 20_005), row(true, at: 21_400 - delay, arrival: 21_400),
        pauseIn(at: 21_405), row(false, at: 21_410 - delay, arrival: 21_410),
        row(true, at: 21_600 - delay, arrival: 21_600),
        ear(.both, .one, at: 22_010 - delay, arrival: 22_010), pauseIn(at: 22_020),
      ], until: 25_000)
    #expect(result.pauses == [20_000, 21_400])
    #expect(result.plays == [22_120])
  }
}
@Test func aPauseExpectationExpiresEvenWhenNoEchoArrives() {
  for offset: UInt64 in [499, 500, 501] {
    let time: UInt64 = 20_000 + offset
    let result = session(
      [
        buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: 20_000),
        ear(.both, .one, at: time - 10), row(true, at: 19_999, arrival: time - 5),
        pauseIn(at: time),
      ], until: 25_000)
    // Accepted ambiguity: a real system Pause within 500 ms can consume the expected echo.
    #expect(result.plays == (offset < 500 ? [] : [time + 100]))
  }
}
@Test func eachSentPauseSuppressesOnlyOneEcho() {
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: 20_000),
      pauseIn(at: 20_005), ear(.both, .one, at: 20_010),
      row(true, at: 19_999, arrival: 20_015), pauseIn(at: 20_020),
    ], until: 25_000)
  #expect(result.pauses == [20_000])
  #expect(result.plays == [20_120])
}
@Test func delayedControlsPreserveTheOriginalEntryAndIgnoreLaterPlayerRows() {
  for to: EarStatus in [.one, .both] {
    for delay: UInt64 in [13, 300, 1_499] {
      let result = session(
        [
          buds(0, at: 1_000), row(false, at: 2_000), ear(.none, to, at: 20_000),
          row(true, at: 20_193, arrival: 20_200),
          buds(to == .one ? 1 : 2, at: 20_000 + delay),
          row(true, at: 21_499), row(true, at: 21_500),
        ], until: 25_000)
      let expected: [UInt64] =
        delay < 200
        ? [20_000 + delay, 20_200, 21_499] : [20_000 + delay, 21_499]
      #expect(result.pauses == expected, "delay=\(delay), to=\(to)")
      #expect(result.plays.isEmpty)
    }
  }
}
@Test func delayedEntryUsesSourceTimeForItsExpiry() {
  for valid: UInt64 in [21_499, 21_500, 22_000] {
    let result = session(
      [
        buds(0, at: 1_000), row(false, at: 2_000),
        ear(.none, .one, at: 20_000, arrival: 20_400), buds(1, at: valid),
        row(true, at: 21_500),
      ], until: 25_000)
    #expect(result.pauses == (valid < 21_500 ? [valid] : []))
  }
  let stale = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000),
      ear(.none, .one, at: 20_000, arrival: 21_500),
    ], until: 25_000)
  #expect(stale.pauses.isEmpty)
}
@Test func aResetDiscardsAnEntryWaitingForControls() {
  let unreadable = EngineInput.gap(
    epoch: 1, reason: .sourceUnreadable, faultTime: moment(20_100).utc)
  let resets: [[Step]] = [
    [Step(input: .automation(false), at: 20_100), Step(input: .automation(true), at: 20_110)],
    [Step(input: unreadable, at: 20_100)],
    [buds(nil, at: 20_100)],
  ]
  for reset in resets {
    let result = session(
      [buds(0, at: 1_000), row(false, at: 2_000), ear(.none, .one, at: 20_000)]
        + reset + [buds(1, at: 20_200), row(true, at: 20_300)], until: 25_000)
    #expect(result.pauses.isEmpty)
  }
}
@Test func aDelayedPreEntryPlayCanRevokeThePendingUserStop() {
  let result = session(
    [
      buds(0, at: 1_000), row(false, at: 2_000), ear(.none, .one, at: 20_000),
      row(true, at: 19_900, arrival: 20_100), buds(1, at: 20_200),
      row(true, at: 20_300),
    ], until: 25_000)
  #expect(result.pauses.isEmpty)
}
@Test func overlappingEntriesKeepEverySystemResumeStoppedUntilTheExtendedEnd() {
  for delay: UInt64 in [0, 40] {
    let result = session(
      [
        buds(2, at: 1_000), row(false, at: 2_000),
        ear(.none, .one, at: 20_000, arrival: 20_000 + delay),
        ear(.one, .both, at: 20_100, arrival: 20_100 + delay),
        row(true, at: 20_193, arrival: 20_193 + delay),
        row(false, at: 20_210, arrival: 20_210 + delay),
        row(true, at: 20_293, arrival: 20_293 + delay),
        row(true, at: 21_550), row(true, at: 21_600),
      ], until: 25_000)
    #expect(
      result.pauses == [
        20_000 + delay, 20_100 + delay,
        20_193 + delay, 20_293 + delay, 21_550,
      ])
    #expect(result.plays.isEmpty)
  }
}
@Test func aDelayedStopKeepsItsRemovalAcrossAnEntryWithoutAResume() {
  let result = session(
    [
      buds(2, at: 1_000), row(true, at: 2_000),
      ear(.both, .none, at: 10_000), buds(0, at: 10_001),
      ear(.none, .one, at: 20_000), buds(1, at: 20_010),
      row(false, at: 10_032, arrival: 20_020),
      ear(.one, .both, at: 21_000), row(true, at: 21_193),
    ], until: 25_000)
  #expect(result.pauses.isEmpty)
  #expect(result.plays.isEmpty)
}

@Test func anotherRemovalCannotEvictTheCauseOfADelayedStop() {
  let result = session(
    [
      buds(2, at: 1_000), row(true, at: 2_000),
      ear(.both, .none, at: 10_000), buds(0, at: 10_001),
      ear(.none, .one, at: 20_000), buds(1, at: 20_010),
      ear(.one, .none, at: 20_500),
      row(false, at: 10_032, arrival: 20_600),
      ear(.none, .both, at: 21_000), row(true, at: 21_193),
    ], until: 25_000)
  #expect(result.pauses.isEmpty)
  #expect(result.plays.isEmpty)
}

@Test func theOracleChecksEveryResumeAcrossConnectedEntries() {
  var engine = readyEngine()
  var model = ReferenceModel()
  let steps = [
    buds(2, at: 1_000), row(false, at: 2_000),
    ear(.none, .one, at: 20_000), ear(.one, .both, at: 20_100),
    row(true, at: 20_193), row(false, at: 20_210), row(true, at: 20_293),
    row(true, at: 20_050, arrival: 21_550),
  ]
  for step in steps {
    let actions = engine.handle(input: step.input, at: moment(step.at))
    if case .nowPlaying(_, true, _) = step.input {
      var missing = model
      let violation = missing.apply(
        step.input, at: moment(step.at), actions: actions.filter { $0 != .pause(context: .test) },
        engineCount: engine.snapshot.count)
      #expect(violation == "system resume left playing inside protected entries")
    }
    #expect(
      model.apply(
        step.input, at: moment(step.at), actions: actions,
        engineCount: engine.snapshot.count) == nil)
  }
}
@Test func twoSentPausesExpectTwoEchoesAndLeaveTheThirdPauseAlone() {
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: 20_000),
      row(true, at: 20_100), ear(.both, .one, at: 20_120),
      pauseIn(at: 20_130), pauseIn(at: 20_140), pauseIn(at: 20_150),
    ], until: 25_000)
  #expect(result.pauses == [20_000, 20_100])
  #expect(result.plays == [20_250])
}
@Test func aPendingEntryKeepsItsDeductionWhenAPostEntryRowArrives() {
  let result = session(
    unknownRemoval(at: 6_000) + [
      buds(0, at: 10_000, context: reroutedContext),
      ear(.one, .none, at: 10_010, context: reroutedContext),
      ear(.none, .one, at: 11_000, context: reroutedContext),
      row(true, at: 11_193), buds(1, at: 11_300, context: reroutedContext),
      row(true, at: 11_400),
    ], until: 15_000)
  #expect(result.pauses == [11_300, 11_400])
  #expect(result.plays.isEmpty)
}

@Test func anEchoDeliveredWithoutTheSentinelStillConsumesItsExpectation() {
  let result = session(
    [
      buds(2, at: 1_000), row(false, at: 2_000), ear(.one, .both, at: 20_000),
      Step(input: .sentinelAvailable(false), at: 20_010), pauseIn(at: 20_020),
      Step(input: .sentinelAvailable(true), at: 20_030),
      ear(.both, .one, at: 20_040), row(true, at: 19_999, arrival: 20_045),
      pauseIn(at: 20_050),
    ], until: 25_000)
  #expect(result.pauses == [20_000])
  #expect(result.plays == [20_150])
}
