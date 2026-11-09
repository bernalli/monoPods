import Foundation

public struct SourceTime: Equatable, Hashable, Comparable, Sendable, Codable {
  public let raw: String
  public let nanos: Int64
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanos < rhs.nanos }
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.nanos == rhs.nanos }
  public func hash(into hasher: inout Hasher) { hasher.combine(nanos) }
  public init(_ raw: String) throws {
    let pattern =
      #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})\z"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(raw.startIndex..., in: raw)
    guard let match = regex.firstMatch(in: raw, range: range) else { throw ContractError.invalid }
    func field(_ index: Int) -> String {
      guard let range = Range(match.range(at: index), in: raw) else { return "" }
      return String(raw[range])
    }
    let values = (1...6).map { Int(field($0)) ?? -1 }
    guard values[0] >= 1970, values[0] <= 2200, values[3] < 24, values[4] < 60, values[5] < 60
    else { throw ContractError.invalid }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
      year: values[0], month: values[1], day: values[2], hour: values[3], minute: values[4],
      second: values[5])
    guard let date = calendar.date(from: components),
      calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        == components
    else {
      throw ContractError.invalid
    }
    let zone = field(8)
    var offset = 0
    if zone != "Z" {
      let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
      let hour = Int(digits.prefix(2)) ?? 99
      let minute = Int(digits.suffix(2)) ?? 99
      guard hour <= 23, minute <= 59 else { throw ContractError.invalid }
      offset = (hour * 3600 + minute * 60) * (zone.first == "-" ? -1 : 1)
    }
    let fraction = field(7)
    let nanos = Int64(fraction + String(repeating: "0", count: 9 - fraction.count)) ?? 0
    self.raw = raw
    self.nanos = (Int64(date.timeIntervalSince1970) - Int64(offset)) * 1_000_000_000 + nanos
  }
  public init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(raw)
  }
}
