import Foundation
import MonoPodsCore
import Testing

// Synthetic rows in the measured shape of audioaccessoryd's CBDevice descriptions. Identifiers,
// addresses and serial numbers are fake.
let placementRoute = "00:11:22:33:44:55"
private let device = "00000000-0000-4000-8000-0000000000AA"
private let before =
  ", Nm <private> , Md Device0,0000, PID 0x0000 (Device0,0000), PrNm AirPods Pro, VID 0x004C,"
  + " DvT Headphones, RSSI -50, BTv 5.3, MicM Auto, "
private let after =
  ", fmCI 00000000-0000-4000-8000-00000000F00D, modU A0000, SN 'SERIAL00000',"
  + " SN Left'SERIALLEFT0', SN Right 'SERIALRIGHT', BatL 50%, BatR 50%"

func placementMessage(
  _ primary: String = "InEar", _ secondary: String = "OutOfEar", prim: String = "Left",
  head: String = "Connected device updated: CBDevice " + device, bda: String = "<private>"
) -> String {
  head + ", BDA " + bda + before + "Plcm P \(primary) S \(secondary) M Enabled, Prim \(prim)"
    + after
}

func placementRecord(
  _ message: String, process: String = "audioaccessoryd",
  category: String = "BTSmartRoutingDaemon"
) -> LogRecord {
  LogRecord(
    timestamp: "2026-11-05 16:45:26.736132+0100", process: process,
    subsystem: "com.apple.bluetooth", category: category, message: message)
}

private func side(_ message: String) -> EarSide? {
  PlacementLine.side(record: placementRecord(message), route: placementRoute)
}

@Test func everyPlacementCombinationGivesTheEarsInUse() {
  let cases: [(String, String, String, EarSide)] = [
    ("InEar", "OutOfEar", "Left", .left), ("InEar", "OutOfEar", "Right", .right),
    ("OutOfEar", "InEar", "Left", .right), ("OutOfEar", "InEar", "Right", .left),
    ("InEar", "InEar", "Left", .both), ("InEar", "InEar", "Right", .both),
    ("OutOfEar", "OutOfEar", "Left", EarSide.none), ("OutOfEar", "OutOfEar", "Right", EarSide.none),
  ]
  for (primary, secondary, prim, expected) in cases {
    #expect(side(placementMessage(primary, secondary, prim: prim)) == expected)
  }
}

// Measured with the other bud in the case: `Plcm P InEar S InCase M Enabled, Prim Right`.
@Test func aBudInTheCaseIsNotInTheEar() {
  let cases: [(String, String, String, EarSide)] = [
    ("InEar", "InCase", "Right", .right), ("InEar", "InCase", "Left", .left),
    ("InCase", "InEar", "Left", .right), ("InCase", "InEar", "Right", .left),
    ("InCase", "InCase", "Left", EarSide.none), ("InCase", "InCase", "Right", EarSide.none),
    ("InCase", "OutOfEar", "Left", EarSide.none), ("InCase", "OutOfEar", "Right", EarSide.none),
    ("OutOfEar", "InCase", "Left", EarSide.none), ("OutOfEar", "InCase", "Right", EarSide.none),
  ]
  for (primary, secondary, prim, expected) in cases {
    #expect(
      side(placementMessage(primary, secondary, prim: prim)) == expected,
      "P \(primary) S \(secondary) Prim \(prim)")
  }
}

@Test func placementRowsNeverReachTheEngineParser() {
  let heads = [
    "Connected device updated: CBDevice " + device,
    "Airpods fw version is 0A000, pairing record CBDevice " + device,
    "Pairing found device CBDevice " + device,
  ]
  for head in heads {
    for prim in ["Left", "Right"] {
      let record = placementRecord(placementMessage(prim: prim, head: head))
      #expect(EarLine.parse(record: record) == .unrelated)
    }
  }
}

@Test func pairingRecordFormsAreIgnored() {
  #expect(
    side(placementMessage(head: "Airpods fw version is 0A000, pairing record CBDevice " + device))
      == nil)
  #expect(side(placementMessage(head: "Pairing found device CBDevice " + device)) == nil)
  #expect(side(placementMessage(head: "Connected device updated: CBDevice 0000")) == nil)
  #expect(side("x" + placementMessage()) == nil)
}

@Test func onlyTheSmartRoutingCategoryOfAudioaccessorydIsRead() {
  let message = placementMessage()
  #expect(PlacementLine.side(record: placementRecord(message), route: placementRoute) == .left)
  for (process, category) in [
    ("bluetoothd", "BTSmartRoutingDaemon"), ("audioaccessoryd", "CBDiscovery"),
    ("bluetoothd", "CBDaemonServer"),
  ] {
    let record = placementRecord(message, process: process, category: category)
    #expect(PlacementLine.side(record: record, route: placementRoute) == nil)
  }
  let other = LogRecord(
    timestamp: "2026-11-05 16:45:26.736132+0100", process: "audioaccessoryd",
    subsystem: "com.apple.other", category: "BTSmartRoutingDaemon", message: message)
  #expect(PlacementLine.side(record: other, route: placementRoute) == nil)
}

/// Every cut before the comma that closes Prim loses the side; no cut gives a different side.
@Test func truncatedRowsNeverGiveASide() {
  for prim in ["Left", "Right"] {
    let message = placementMessage(prim: prim)
    let whole = side(message)
    guard let end = message.range(of: "Prim \(prim), ")?.upperBound, let whole else {
      Issue.record("whole row rejected")
      continue
    }
    var index = message.startIndex
    while index < message.endIndex {
      let cut = side(String(message[..<index]))
      if index < end { #expect(cut == nil) } else { #expect(cut == whole) }
      index = message.index(after: index)
    }
    #expect(side(String(message[..<message.index(end, offsetBy: -2)]) + "<…>") == nil)
  }
}

@Test func missingOrUnknownPlacementFieldsGiveNoSide() {
  let message = placementMessage()
  for removed in [" P InEar", " S OutOfEar", " M Enabled", ", Prim Left", "Plcm "] {
    #expect(side(message.replacingOccurrences(of: removed, with: "")) == nil)
  }
  for value in ["Unknown", "Disabled", "", "inEar", "incase", "InCaseX", "<private>"] {
    #expect(side(placementMessage(value, "OutOfEar")) == nil)
    #expect(side(placementMessage("InEar", value)) == nil)
    #expect(side(placementMessage(value, "InCase")) == nil)
    #expect(side(placementMessage("InCase", value)) == nil)
  }
  for prim in ["", "Center", "left", "Unknown", "<private>"] {
    #expect(side(placementMessage(prim: prim)) == nil)
  }
  for mode in ["Disabled", "Unknown", ""] {
    #expect(side(message.replacingOccurrences(of: "M Enabled", with: "M " + mode)) == nil)
  }
}

@Test func twoPlacementFragmentsInOneRowGiveNoSide() {
  let message = placementMessage()
  let doubled = message + ", Plcm P OutOfEar S InEar M Enabled, Prim Left, x"
  #expect(side(doubled) == nil)
}

@Test func repeatedIdentityAndSideFieldsGiveNoSide() {
  for prim in ["Left", "Right"] {
    let message = placementMessage(prim: prim)
    let opposite = prim == "Left" ? "Right" : "Left"
    for extra in [", Prim " + opposite, ", BDA 66:77:88:99:AA:BB"] {
      #expect(side(message + extra + ", x") == nil)
      #expect(
        side(message.replacingOccurrences(of: ", Plcm", with: extra + ", Plcm")) == nil)
    }
  }
}

@Test func aVisibleBluetoothAddressMustBeTheRoute() {
  #expect(side(placementMessage(bda: placementRoute)) == .left)
  #expect(side(placementMessage(bda: "00-11-22-33-44-55")) == .left)
  #expect(side(placementMessage(bda: "00:11:22:33:44:5f")) == nil)
  for bda in ["66:77:88:99:AA:BB", "", "<redacted>", "00:11:22", "00:11-22:33:44:55"] {
    #expect(side(placementMessage(bda: bda)) == nil)
  }
  let noBDA = placementMessage().replacingOccurrences(of: ", BDA <private>", with: "")
  #expect(side(noBDA) == nil)
}
