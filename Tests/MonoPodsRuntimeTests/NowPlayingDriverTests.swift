import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

private let posting = "Posting com.apple.MediaRemote.nowPlayingApplicationIsPlayingDidChange with "

/// A mediaremoted row of the fixture, moved to the NowPlaying category with a new message.
private func nowPlayingRow(_ message: String, time: String, fixtureIndex: Int = 3) throws -> Data {
  let line = try envelopeFixture()[fixtureIndex]
  var object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
  object["category"] = "NowPlaying"
  object["timestamp"] = time
  object["formatString"] = "Posting %{public}@ with %{public}@"
  object["eventMessage"] = message
  return try JSONSerialization.data(withJSONObject: object)
}
@MainActor private func nowPlayingDriver() throws -> (
  ObservationDriver, () -> [EngineInput], UInt64
) {
  var inputs: [EngineInput] = []
  let now = Instant(continuousNanos: 2, utc: try SourceTime("2026-11-06T12:00:00Z"))
  let driver = ObservationDriver(clock: { now }, submit: { inputs.append($0) })
  driver.route(address: "00:11:22:33:44:55")
  let epoch = try driver.beginStream(nonce: "test")
  return (driver, { inputs }, epoch)
}

@MainActor @Test func nowPlayingRowsBecomeOneInputWithStateAndSourceTime() throws {
  #expect(try LogRecord.decode(envelopeFixture()[3]).process == "mediaremoted")
  let (driver, inputs, epoch) = try nowPlayingDriver()
  let before = inputs()
  let playingTime = "2026-11-06 12:59:58.100000+0100"
  let pausedTime = "2026-11-06 12:59:59.200000+0100"
  driver.consume(try nowPlayingRow(posting + "<Playing>", time: playingTime), epoch: epoch)
  driver.consume(try nowPlayingRow(posting + "<Not Playing>", time: pausedTime), epoch: epoch)
  #expect(
    inputs()
      == before + [
        .nowPlaying(epoch: epoch, playing: true, sourceTime: try SourceTime(playingTime)),
        .nowPlaying(epoch: epoch, playing: false, sourceTime: try SourceTime(pausedTime)),
      ])
}
@MainActor @Test func otherNowPlayingRowsGiveNoInputAndNoGap() throws {
  let (driver, inputs, epoch) = try nowPlayingDriver()
  let before = inputs()
  let time = "2026-11-06 12:59:58.100000+0100"
  for message in [
    "Posting com.apple.MediaRemote.nowPlayingActivePlayersIsPlayingDidChange with <Playing>",
    "[MRDNowPlayingPlayerClient] isPlaying changed to false for 【 LOCL (Mac) ❯ "
      + "com.example.player (1) Player ❯ default 】",
    posting + "<Paused>", posting + "<Playing> extra", posting + "<Not Pla", "",
  ] {
    driver.consume(try nowPlayingRow(message, time: time), epoch: epoch)
  }
  // The exact row from another process is not the now-playing row.
  driver.consume(
    try nowPlayingRow(posting + "<Playing>", time: time, fixtureIndex: 0), epoch: epoch)
  // A row of an older stream is dropped like every other row.
  driver.consume(try nowPlayingRow(posting + "<Playing>", time: time), epoch: epoch - 1)
  #expect(inputs() == before)
}
@Test func predicatesAddOnlyTheExactNowPlayingRow() {
  let clause =
    "(process == 'mediaremoted' AND subsystem == 'com.apple.amp.mediaremote'"
    + " AND category == 'NowPlaying' AND eventMessage BEGINSWITH '" + posting + "')"
  #expect(LogArguments.predicate.contains(clause))
  #expect(LogArguments.predicate.components(separatedBy: " OR ").count == 5)
  #expect(LogArguments.stream.last == LogArguments.predicate)
  let boot = "00000000-0000-4000-8000-000000000001"
  #expect(
    LogArguments.history(boot: boot).last
      == "(" + LogArguments.predicate + ") AND bootUUID == '" + boot + "'")
}
@MainActor @Test func diaryKeepsEveryNowPlayingInput() throws {
  let input = EngineInput.nowPlaying(
    epoch: 1, playing: true, sourceTime: try SourceTime("2026-11-06T12:00:00Z"))
  #expect(EngineFIFO.recordsInDiary(input, actions: [], changed: false))
}
