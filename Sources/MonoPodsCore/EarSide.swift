import Foundation

/// The ears that hold an AirPod. It is read only for the menu bar icon: the engine never receives
/// it, so the ear count, the Mono/Stereo choice and Play stay on the in-ear rows.
public enum EarSide: String, Equatable, Sendable {
  case left, right, both, none
}

/// Reads `EarSide` from the placement fragment of one audioaccessoryd row.
///
/// audioaccessoryd prints CBDevice descriptions that contain
/// `Plcm P <place> S <place> M Enabled, Prim <Left|Right>`, where a place is `InEar`, `OutOfEar` or
/// `InCase`. P is the primary bud, S the secondary bud and Prim the side of the primary. `InCase`
/// counts as not in the ear; any other place rejects the row. The primary role moves between the
/// buds, so the side comes only from P, S and Prim of one row, never from an older Prim.
///
/// Only `Connected device updated: CBDevice` is read, because it describes the connected device.
/// The `Airpods fw version is …, pairing record CBDevice` and `Pairing found device CBDevice` rows
/// describe pairing records, and nothing in them binds them to the current route, so they are
/// ignored. The row also carries serial numbers and battery levels: only P, S and Prim are read.
public enum PlacementLine {
  private static let uuid =
    "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
  private static let mac =
    "[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}"

  /// The side in `record`, or nil when the row is not a complete placement row of the connected
  /// device. `route` is the normalized address of the current route. A row whose BDA field shows
  /// a different address is rejected; a redacted BDA (`<private>`, the measured form) is accepted.
  public static func side(record: LogRecord, route: String) -> EarSide? {
    guard record.process == "audioaccessoryd", record.subsystem == "com.apple.bluetooth",
      record.category == "BTSmartRoutingDaemon"
    else { return nil }
    let message = record.message
    let head = "^Connected device updated: CBDevice " + uuid + ", BDA (<private>|" + mac + "), "
    guard let bda = captures(head, message) else { return nil }
    if bda[0] != "<private>",
      bda[0].uppercased().replacingOccurrences(of: "-", with: ":") != route
    {
      return nil
    }
    // Reject ambiguous placement, side and identity fields.
    guard message.components(separatedBy: "Plcm").count == 2,
      message.components(separatedBy: ", Prim ").count == 2,
      message.components(separatedBy: ", BDA ").count == 2
    else { return nil }
    // The trailing ", " proves that Prim is whole and that the row was not cut after it.
    let place = "(InEar|OutOfEar|InCase)"
    let fragment = ", Plcm P " + place + " S " + place + " M Enabled, Prim (Left|Right), "
    guard let parts = captures(fragment, message) else { return nil }
    let primary = parts[0] == "InEar"
    let secondary = parts[1] == "InEar"
    let primarySide: EarSide = parts[2] == "Left" ? .left : .right
    let secondarySide: EarSide = primarySide == .left ? .right : .left
    switch (primary, secondary) {
    case (true, true): return .both
    case (true, false): return primarySide
    case (false, true): return secondarySide
    case (false, false): return EarSide.none
    }
  }

  private static func captures(_ pattern: String, _ value: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    else { return nil }
    return (1..<match.numberOfRanges).map { String(value[Range(match.range(at: $0), in: value)!]) }
  }
}
