import Foundation
import Testing

@testable import MonoPodsRuntime

/// The product IDs verified against independent sources; any other ID is not recognised.
private let verified: [Int: (String, Bool)] = [
  0x2002: ("AirPods (1st generation)", true),
  0x200F: ("AirPods (2nd generation)", true),
  0x2013: ("AirPods (3rd generation)", true),
  0x2019: ("AirPods 4", true),
  0x201B: ("AirPods 4 with Active Noise Cancellation", true),
  0x2036: ("AirPods 5", true),
  0x2030: ("AirPods 5", true),
  0x200E: ("AirPods Pro (1st generation)", true),
  0x2014: ("AirPods Pro 2", true),
  0x2024: ("AirPods Pro 2 (USB-C)", true),
  0x2027: ("AirPods Pro 3", true),
  0x200A: ("AirPods Max", false),
  0x201F: ("AirPods Max (USB-C)", false),
  0x202D: ("AirPods Max 2", false),
]

@Test func modelTableHoldsExactlyTheVerifiedProductIDs() {
  #expect(AirPodsModel.known.count == verified.count)
  for model in AirPodsModel.known {
    let expected = verified[model.productID]
    #expect(expected?.0 == model.name, "\(model.productID)")
    #expect(expected?.1 == model.earDetection, "\(model.productID)")
  }
}

@Test func modelTableHasUniqueInRangeAirPodsEntries() {
  let ids = AirPodsModel.known.map(\.productID)
  #expect(Set(ids).count == ids.count)
  for model in AirPodsModel.known {
    #expect((0...65535).contains(model.productID))
    #expect(!model.name.isEmpty)
    #expect(model.name.hasPrefix("AirPods"))
    // Only AirPods Max lack ear detection.
    #expect(model.earDetection == !model.name.hasPrefix("AirPods Max"))
  }
}

@Test func everyProductIDResolvesToItsTableEntryOrToNothing() {
  for id in 0...65535 {
    let model = AirPodsModel.model(productID: NSNumber(value: id))
    #expect(model?.productID == (verified[id] == nil ? nil : id))
    #expect(model?.name == verified[id]?.0)
    if model != nil || verified[id] != nil {
      #expect(AirPodsModel.model(productID: id) == model)
    }
  }
}

@Test func productIDsOutsideTheVerifiedTableAreNotRecognised() {
  // 0x2028 has a single source; neighbouring 0x20xx IDs are not verified AirPods.
  for id in [0x2028, 0x2012, 0x2017, 0x2000, 0, 65535] {
    #expect(AirPodsModel.model(productID: NSNumber(value: id)) == nil)
  }
}

@Test func modelLookupRejectsBooleanFractionalAndNonNumericValues() {
  let rejected: [Any?] = [
    nil, true, false, kCFBooleanTrue as Any, NSNumber(value: true), 8194.5, Double.nan,
    Double.infinity, -1, 65536, NSNumber(value: -8194), "8194", "0x2002", NSNull(), [8194],
  ]
  for value in rejected {
    #expect(AirPodsModel.model(productID: value) == nil, "\(String(describing: value))")
    #expect(AirPodsModel.productNumber(value) == nil, "\(String(describing: value))")
  }
  #expect(
    AirPodsModel.model(productID: NSNumber(value: 8194.0))?.name == "AirPods (1st generation)")
  #expect(AirPodsModel.model(productID: 0x2014)?.name == "AirPods Pro 2")
}

@Test func productNumberAcceptsExactlyWhatRouteIdentityAccepts() {
  let values: [Any?] = [
    nil, true, false, NSNumber(value: true), 0, 1, 0x2014, 65535, 65536, -1, 8194.0, 8194.5,
    Double.nan, Double.infinity, -Double.infinity, "1", NSNull(), NSNumber(value: UInt64.max),
  ]
  for value in values {
    let accepted =
      RouteIdentity.resolve(
        uid: "00-11-22-33-44-55", address: "00:11:22:33:44:55", connected: true, paired: true,
        bluetoothTransport: true, productID: value) != nil
    #expect((AirPodsModel.productNumber(value) != nil) == accepted, "\(String(describing: value))")
  }
}
