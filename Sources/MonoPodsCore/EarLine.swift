import Foundation

public enum EarLine {
  /// Start of the mediaremoted row that reports the now-playing application state.
  public static let nowPlayingPrefix =
    "Posting com.apple.MediaRemote.nowPlayingApplicationIsPlayingDidChange with "
  public static func parse(record: LogRecord) -> ParseResult {
    guard (try? SourceTime(record.timestamp)) != nil else { return .gap }
    let family: Int
    switch (record.process, record.subsystem, record.category) {
    case ("bluetoothd", "com.apple.bluetooth", "Server.AACP"): family = 1
    case ("audioaccessoryd", "com.apple.bluetooth", "BTSmartRoutingDaemon"): family = 3
    case ("mediaremoted", "com.apple.amp.mediaremote", "MediaRemote"): family = 2
    case ("MonoPods", "io.github.bernalli.monopods", "heartbeat"):
      guard
        let parts = captures(#"^HEARTBEAT ([A-Za-z0-9-]{1,64}) ([1-9][0-9]*)\z"#, record.message),
        let seq = UInt64(parts[1])
      else { return .gap }
      return .heartbeat(parts[0], seq)
    case ("mediaremoted", "com.apple.amp.mediaremote", "NowPlaying"):
      // Only the two exact rows count; every other row of the category is ignored, not a gap.
      switch record.message {
      case nowPlayingPrefix + "<Playing>": return .playback(true)
      case nowPlayingPrefix + "<Not Playing>": return .playback(false)
      default: return .unrelated
      }
    default: return .unrelated
    }
    let prefixes = [
      1: "received in-ear state update from device ",
      3: "SmartRouting CONNECTED STATE shows inEar: ",
      2: "[AccessoryController] Device ",
    ]
    guard record.message.hasPrefix(prefixes[family]!) else { return .unrelated }
    let addr = #"([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5})"#
    let identityPattern: String
    if family == 1 {
      identityPattern = "^received in-ear state update from device " + addr + "(?: |\\z)"
    } else if family == 3 {
      identityPattern =
        "^SmartRouting CONNECTED STATE shows inEar: .*? for device " + addr + "(?: |\\z)"
    } else {
      identityPattern =
        #"^\[AccessoryController\] Device <MRDBluetoothDevice 0x[0-9A-Fa-f]+ "# + addr + ">"
    }
    guard let identity = captures(identityPattern, record.message) else { return .gap }
    let address = identity[0].uppercased().replacingOccurrences(of: "-", with: ":")
    if family == 2 {
      let pattern =
        identityPattern
        + #" ear status changed from (Unknown|None|One|Both) to (Unknown|None|One|Both)\z"#
      guard let parts = captures(pattern, record.message) else { return .gap }
      return .transition(address, parts[1], parts[2])
    }
    let pattern =
      family == 1
      ? "^received in-ear state update from device " + addr
        + " primary bud state = (in ear|out of ear|in case|unknown), secondary bud state = (in ear|out of ear|in case|unknown)\\z"
      : "^SmartRouting CONNECTED STATE shows inEar: (?:yes|no) for device " + addr
        + " primary:(InEar|OutOfEar|InCase|Unknown|Disabled) secondary:(InEar|OutOfEar|InCase|Unknown|Disabled)\\z"
    guard let parts = captures(pattern, record.message) else {
      return .state(EarState(address: address, primary: .unknown, secondary: .unknown))
    }
    let map: [String: BudState] = [
      "in ear": .inEar, "out of ear": .outOfEar, "in case": .inCase, "unknown": .unknown,
      "InEar": .inEar, "OutOfEar": .outOfEar, "InCase": .inCase, "Unknown": .unknown,
      "Disabled": .disabled,
    ]
    return .state(EarState(address: address, primary: map[parts[1]]!, secondary: map[parts[2]]!))
  }
  private static func captures(_ pattern: String, _ value: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    else { return nil }
    return (1..<match.numberOfRanges).map { String(value[Range(match.range(at: $0), in: value)!]) }
  }
}
public struct LogRecord: Sendable {
  public let timestamp: String
  public let process: String
  public let subsystem: String
  public let category: String
  public let message: String
  public init(
    timestamp: String, process: String, subsystem: String, category: String, message: String
  ) {
    self.timestamp = timestamp
    self.process = process
    self.subsystem = subsystem
    self.category = category
    self.message = message
  }
}
extension LogRecord {
  public static func decode(_ data: Data) throws -> LogRecord {
    guard case .event(let record) = try SystemLogEnvelope.decode(data) else {
      throw ContractError.invalid
    }
    return record
  }
  /// Explicit five-key projection used by synthetic core fixtures, never system output.
  public static func decodeProjection(_ data: Data) throws -> LogRecord {
    let fields = try StrictJSON.parse(data).object(keys: [
      "timestamp", "process", "subsystem", "category", "eventMessage",
    ])
    let timestamp = try fields["timestamp"]!.string()
    _ = try SourceTime(timestamp)
    return try LogRecord(
      timestamp: timestamp, process: fields["process"]!.string(),
      subsystem: fields["subsystem"]!.string(),
      category: fields["category"]!.string(), message: fields["eventMessage"]!.string())
  }
}
public enum BudState: String, Codable, Sendable, CaseIterable {
  case inEar, outOfEar, inCase, unknown, disabled
}
public struct EarState: Equatable, Sendable {
  public let address: String
  public let primary: BudState
  public let secondary: BudState
  public init(address: String, primary: BudState, secondary: BudState) {
    self.address = address
    self.primary = primary
    self.secondary = secondary
  }
  public var count: Int? {
    guard ![primary, secondary].contains(.unknown), !detectionOff else { return nil }
    return [primary, secondary].filter { $0 == .inEar }.count
  }
  public var detectionOff: Bool { primary == .disabled || secondary == .disabled }
}
public enum ParseResult: Equatable, Sendable {
  case state(EarState)
  case transition(String, String, String)
  case heartbeat(String, UInt64)
  /// The now-playing application is playing (`true`) or not playing (`false`).
  case playback(Bool)
  case unrelated
  case gap
}
