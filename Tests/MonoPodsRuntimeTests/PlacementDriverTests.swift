import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

// Fake identifiers, addresses and serial numbers in the measured row shape.
private let route = "00:11:22:33:44:55"

private func placementRow(
  _ primary: String, _ secondary: String, prim: String, time: String,
  head: String = "Connected device updated: CBDevice 00000000-0000-4000-8000-0000000000AA"
) throws -> Data {
  let line = try envelopeFixture()[0]
  var object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
  object["timestamp"] = time
  object["eventMessage"] =
    head + ", BDA <private>, Nm <private> , PrNm AirPods Pro, MicM Auto, Plcm P \(primary) S "
    + "\(secondary) M Enabled, Prim \(prim), fmCI 00000000-0000-4000-8000-00000000F00D, "
    + "SN 'SERIAL00000', BatL 50%"
  return try JSONSerialization.data(withJSONObject: object)
}

@MainActor private func recorder(route address: String? = route) throws -> (
  ObservationDriver, () -> [EngineInput], () -> [EarSide?], UInt64
) {
  var inputs: [EngineInput] = []
  var sides: [EarSide?] = []
  var now = Instant(
    continuousNanos: 2, utc: try SourceTime("2026-11-05 16:45:00.000000+0100"))
  let driver = ObservationDriver(clock: { now }, submit: { inputs.append($0) })
  driver.placement = { sides.append($0) }
  driver.route(address: address)
  now = Instant(continuousNanos: 2, utc: try SourceTime("2026-11-06T12:00:00Z"))
  let epoch = try driver.beginStream(nonce: "test")
  return (driver, { inputs }, { sides }, epoch)
}

@MainActor @Test func placementRowGivesTheSideAndNoEngineInput() throws {
  let (driver, inputs, sides, epoch) = try recorder()
  let before = inputs()
  driver.consume(
    try placementRow("OutOfEar", "InEar", prim: "Left", time: "2026-11-05 16:45:26.000000+0100"),
    epoch: epoch)
  #expect(sides() == [nil, .right])
  #expect(inputs() == before)
}

@MainActor @Test func aBudInTheCaseStillGivesTheSideOfTheOtherBud() throws {
  let (driver, inputs, sides, epoch) = try recorder()
  let before = inputs()
  driver.consume(
    try placementRow("InEar", "InCase", prim: "Right", time: "2026-11-05 16:45:26.000000+0100"),
    epoch: epoch)
  #expect(sides() == [nil, .right])
  #expect(inputs() == before)
}

/// The same stream with and without placement rows gives identical engine inputs.
@MainActor @Test func placementRowsLeaveEngineInputsIdentical() throws {
  let fixture = try envelopeFixture()
  let rows = try [
    placementRow("InEar", "OutOfEar", prim: "Right", time: "2026-11-05 16:45:20.000000+0100"),
    placementRow("InEar", "InEar", prim: "Left", time: "2026-11-05 16:45:30.000000+0100"),
    placementRow(
      "OutOfEar", "InEar", prim: "Left", time: "2026-11-05 16:45:40.000000+0100",
      head: "Pairing found device CBDevice 00000000-0000-4000-8000-0000000000AA"),
    placementRow("Unknown", "InEar", prim: "Left", time: "2026-11-05 16:45:50.000000+0100"),
  ]
  let (plain, plainInputs, _, plainEpoch) = try recorder()
  for line in fixture { plain.consume(line, epoch: plainEpoch) }
  let (mixed, mixedInputs, sides, mixedEpoch) = try recorder()
  for (index, line) in fixture.enumerated() {
    mixed.consume(line, epoch: mixedEpoch)
    if index < rows.count { mixed.consume(rows[index], epoch: mixedEpoch) }
  }
  #expect(mixedInputs() == plainInputs())
  #expect(mixedInputs().contains { if case .observation = $0 { true } else { false } })
  #expect(sides() == [nil, .right, .both])
}

@MainActor @Test func anOlderPlacementRowNeverReplacesANewerSide() throws {
  let (driver, _, sides, epoch) = try recorder()
  driver.consume(
    try placementRow("InEar", "OutOfEar", prim: "Right", time: "2026-11-05 16:45:10.000000+0100"),
    epoch: epoch)
  // The primary role moved to the left bud; Prim of the newer row is the only one used.
  driver.consume(
    try placementRow("InEar", "OutOfEar", prim: "Left", time: "2026-11-05 16:45:30.000000+0100"),
    epoch: epoch)
  driver.consume(
    try placementRow("InEar", "OutOfEar", prim: "Right", time: "2026-11-05 16:45:20.000000+0100"),
    epoch: epoch)
  #expect(sides() == [nil, .right, .left])
  // A route change clears the side; an older row still cannot bring it back.
  driver.route(address: "66:77:88:99:AA:BB")
  driver.consume(
    try placementRow("InEar", "OutOfEar", prim: "Right", time: "2026-11-05 16:45:25.000000+0100"),
    epoch: epoch)
  #expect(sides() == [nil, .right, .left, nil])
  driver.consume(
    try placementRow(
      "OutOfEar", "OutOfEar", prim: "Right", time: "2026-11-05 16:45:40.000000+0100"),
    epoch: epoch)
  // Newer than the last accepted placement, but still before the route change.
  #expect(sides() == [nil, .right, .left, nil])
  driver.consume(
    try placementRow(
      "OutOfEar", "OutOfEar", prim: "Right", time: "2026-11-06T12:00:00Z"),
    epoch: epoch)
  #expect(sides() == [nil, .right, .left, nil, EarSide.none])
}

@MainActor @Test func placementNeedsARouteALiveStreamAndAPastTime() throws {
  let row = try placementRow(
    "InEar", "OutOfEar", prim: "Right", time: "2026-11-05 16:45:10.000000+0100")
  let (unrouted, _, unroutedSides, unroutedEpoch) = try recorder(route: nil)
  unrouted.consume(row, epoch: unroutedEpoch)
  #expect(unroutedSides().isEmpty)
  let (driver, _, sides, epoch) = try recorder()
  driver.consume(row, epoch: epoch + 1)
  driver.consume(
    try placementRow("InEar", "OutOfEar", prim: "Right", time: "2026-11-07 16:45:10.000000+0100"),
    epoch: epoch)
  #expect(sides() == [nil])
  // A row before the observed connection belongs to the previous connection.
  driver.connected(address: route, at: try SourceTime("2026-11-05 16:45:15.000000+0100"))
  driver.consume(row, epoch: epoch)
  #expect(sides() == [nil])
  driver.consume(
    try placementRow("InEar", "OutOfEar", prim: "Right", time: "2026-11-05 16:45:16.000000+0100"),
    epoch: epoch)
  #expect(sides() == [nil, .right])
}
