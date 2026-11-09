import CoreFoundation
import Foundation

/// An AirPods model recognised from the Bluetooth product ID. It is shown in the menu and marks the
/// models without ear detection; switching never depends on it, so an unknown ID works as before.
public struct AirPodsModel: Equatable, Sendable {
  public let productID: Int
  /// Commercial English name.
  public let name: String
  /// Whether the model reports ear detection, which MonoPods needs to switch.
  public let earDetection: Bool

  /// Product IDs confirmed by at least two independent sources. Any other ID is not recognised.
  public static let known: [AirPodsModel] = [
    AirPodsModel(productID: 0x2002, name: "AirPods (1st generation)", earDetection: true),
    AirPodsModel(productID: 0x200F, name: "AirPods (2nd generation)", earDetection: true),
    AirPodsModel(productID: 0x2013, name: "AirPods (3rd generation)", earDetection: true),
    AirPodsModel(productID: 0x2019, name: "AirPods 4", earDetection: true),
    AirPodsModel(
      productID: 0x201B, name: "AirPods 4 with Active Noise Cancellation", earDetection: true),
    // Two IDs are reported for AirPods 5; they are not told apart with certainty.
    AirPodsModel(productID: 0x2036, name: "AirPods 5", earDetection: true),
    AirPodsModel(productID: 0x2030, name: "AirPods 5", earDetection: true),
    AirPodsModel(productID: 0x200E, name: "AirPods Pro (1st generation)", earDetection: true),
    AirPodsModel(productID: 0x2014, name: "AirPods Pro 2", earDetection: true),
    AirPodsModel(productID: 0x2024, name: "AirPods Pro 2 (USB-C)", earDetection: true),
    AirPodsModel(productID: 0x2027, name: "AirPods Pro 3", earDetection: true),
    AirPodsModel(productID: 0x200A, name: "AirPods Max", earDetection: false),
    AirPodsModel(productID: 0x201F, name: "AirPods Max (USB-C)", earDetection: false),
    AirPodsModel(productID: 0x202D, name: "AirPods Max 2", earDetection: false),
  ]

  /// The model for a product ID read from the system, or nil when it is not a valid ID or not in
  /// the table.
  public static func model(productID value: Any?) -> AirPodsModel? {
    guard let id = productNumber(value) else { return nil }
    return known.first { $0.productID == id }
  }

  /// The product ID as an integer, with the same acceptance rule as `RouteIdentity.resolve`:
  /// a finite, integral number in 0...65535 that is not a Boolean.
  public static func productNumber(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
      number.doubleValue >= 0, number.doubleValue <= 65535
    else { return nil }
    return Int(number.doubleValue)
  }
}
