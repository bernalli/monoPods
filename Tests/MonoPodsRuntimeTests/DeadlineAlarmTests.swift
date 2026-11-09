import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private let millisecond: UInt64 = 1_000_000

/// An engine with an open Play episode: Pause and the matching ear transition at 1 s, so the Play
/// is due 100 ms later. The clock moves only when the test moves it; no periodic tick runs.
@MainActor private final class PlayEpisode {
  var now: Instant
  private(set) var plays: [UInt64] = []
  private(set) var fires = 0
  let schedule = ManualSchedule()
  var fifo: EngineFIFO!
  var alarm: DeadlineAlarm!

  /// `playerRow` is the Playing row before the removal; without it the player state is unknown.
  init(playerRow: Bool = true) throws {
    now = Instant(continuousNanos: 500 * millisecond, utc: try SourceTime("2026-01-01T00:00:00.5Z"))
    fifo = EngineFIFO(
      engine: Engine(build: testBuild, run: 1, boot: "00000000-0000-4000-8000-000000000001"),
      clock: { [unowned self] in self.now },
      execute: { [unowned self] action, reply in
        switch action {
        case .persist(let request):
          reply(.persistenceAcknowledged(run: 1, id: request.id, success: true))
        case .play(let command):
          self.plays.append(self.now.continuousNanos)
          reply(.playCompleted(run: 1, id: command.id, accepted: true))
        default: break
        }
      })
    alarm = DeadlineAlarm(
      clock: { [unowned self] in self.now }, schedule: schedule.schedule,
      fire: { [unowned self] in
        self.fires += 1
        if self.fifo.tickIfDue() { self.fifo.flush() }
      })
    fifo.flushed = { [unowned self] in self.alarm.arm(self.fifo.nextDeadline) }
    let context = ObservationContext(
      routeEpoch: 1, streamEpoch: 1, connectionEpoch: 1, deviceOrdinal: 1)
    for input: EngineInput in [
      .journalLoaded(.missing), .route(Route(epoch: 1, deviceOrdinal: 1)),
      .connection(Connection(epoch: 1, boundary: try SourceTime("2026-01-01T00:00:00Z"))),
      .streamStarted(epoch: 1, nonce: "test"), .heartbeat(epoch: 1, nonce: "test", sequence: 1),
      .sentinelAvailable(true),
      .audioObserved(AudioReading(generation: 1, mode: .stereo, status: 0, systemMono: .off)),
    ] {
      fifo.enqueue(input)
      fifo.flush()
    }
    now = Instant(
      continuousNanos: 750 * millisecond, utc: try SourceTime("2026-01-01T00:00:00.75Z"))
    if playerRow {
      fifo.enqueue(.nowPlaying(epoch: 1, playing: true, sourceTime: now.utc))
      fifo.flush()
    }
    now = Instant(continuousNanos: 1_000 * millisecond, utc: try SourceTime("2026-01-01T00:00:01Z"))
    for input: EngineInput in [
      .observation(
        Observation(
          sourceTime: now.utc, source: .s1, provenance: .live, context: context,
          receivedContinuousNanos: now.continuousNanos, value: .count(1, detection: .on))),
      .pause(now.utc),
      .observation(
        Observation(
          sourceTime: now.utc, source: .m, provenance: .live, context: context,
          receivedContinuousNanos: now.continuousNanos, value: .transition(from: .both, to: .one))),
    ] {
      fifo.enqueue(input)
      fifo.flush()
    }
  }

  func move(to nanos: UInt64) {
    now = Instant(continuousNanos: nanos, utc: now.utc)
  }
}

@MainActor @Test func playDeadlineTicksAtTheDeadlineWithoutThePeriodicTick() throws {
  let episode = try PlayEpisode()
  #expect(episode.plays.isEmpty)
  #expect(episode.fifo.nextDeadline == 1_100 * millisecond)
  #expect(episode.schedule.delays.last == 100 * millisecond)
  episode.move(to: 1_100 * millisecond)
  #expect(episode.schedule.fireNext())
  #expect(episode.plays == [1_100 * millisecond])
  #expect(episode.fires == 1)
  // The next armed deadline is a later one, never the consumed Play deadline.
  #expect(episode.fifo.nextDeadline.map { $0 > 1_100 * millisecond } ?? true)
  #expect(episode.schedule.delays.last.map { $0 > 0 } ?? true)
}

/// An unknown player state and no stop: the alarm stays on the end of the episode, with no empty
/// firing at the Play deadline.
@MainActor @Test func playThatWaitsForAStopArmsOnlyTheEndOfItsEpisode() throws {
  let episode = try PlayEpisode(playerRow: false)
  #expect(episode.fifo.nextDeadline == 4_000 * millisecond)
  #expect(episode.schedule.delays.last == 3_000 * millisecond)
  episode.move(to: 1_100 * millisecond)
  #expect(episode.fifo.tickIfDue() == false)
  #expect(episode.plays.isEmpty && episode.fires == 0)
  // The stop arrives after the Play deadline: its own flush sends the Play.
  episode.move(to: 1_500 * millisecond)
  episode.fifo.enqueue(.nowPlaying(epoch: 1, playing: false, sourceTime: episode.now.utc))
  episode.fifo.flush()
  #expect(episode.plays == [1_500 * millisecond])
  #expect(episode.fifo.nextDeadline.map { $0 > 1_500 * millisecond } ?? true)
}

@MainActor @Test func alarmThatFiresEarlyWaitsForTheContinuousClock() throws {
  let episode = try PlayEpisode()
  episode.move(to: 1_099 * millisecond)
  #expect(episode.schedule.fireNext())
  #expect(episode.plays.isEmpty && episode.fires == 0)
  #expect(episode.schedule.delays.last == millisecond)
  episode.move(to: 1_100 * millisecond)
  #expect(episode.schedule.fireNext())
  #expect(episode.plays == [1_100 * millisecond])
}

@MainActor @Test func alarmReplacesAStaleDeadlineAndNeverRearmsAFiredOne() throws {
  var now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:00Z"))
  let schedule = ManualSchedule()
  var fired: [UInt64] = []
  let alarm = DeadlineAlarm(
    clock: { now }, schedule: schedule.schedule, fire: { fired.append(now.continuousNanos) })
  alarm.arm(500)
  alarm.arm(500)
  #expect(schedule.count == 1)
  alarm.arm(300)
  #expect(schedule.cancelled == 1 && schedule.count == 1 && schedule.delays == [500, 300])
  now = Instant(continuousNanos: 300, utc: now.utc)
  schedule.fireNext()
  #expect(fired == [300])
  // A deadline that stays due after its tick is left to the pulse: no spinning alarm.
  alarm.arm(300)
  #expect(schedule.count == 0)
  alarm.arm(400)
  alarm.arm(nil)
  #expect(schedule.count == 0 && schedule.cancelled == 2)
  // A past deadline fires at once.
  alarm.arm(200)
  #expect(schedule.delays.last == 0)
  schedule.fireNext()
  #expect(fired == [300, 300])
}

@MainActor @Test func fifoReportsEveryFlushToTheAlarm() throws {
  let now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:00Z"))
  let fifo = EngineFIFO(
    engine: Engine(build: testBuild, run: 1, boot: "00000000-0000-4000-8000-000000000001"),
    clock: { now }, execute: { _, _ in })
  var deadlines: [UInt64?] = []
  fifo.flushed = { deadlines.append(fifo.nextDeadline) }
  fifo.enqueue(.ownerWaiting)
  fifo.flush()
  #expect(deadlines.count == 1 && deadlines[0] == fifo.nextDeadline)
}
