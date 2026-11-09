import Foundation

public enum ContractError: Error, Equatable { case invalid }

public indirect enum JSONValue: Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(String)
  case bool(Bool)
  case null

  public func object(keys: Set<String>) throws -> [String: JSONValue] {
    guard case .object(let fields) = self, Set(fields.keys) == keys else {
      throw ContractError.invalid
    }
    return fields
  }
  public func string() throws -> String {
    guard case .string(let value) = self else { throw ContractError.invalid }
    return value
  }
  public func uint(positive: Bool = false) throws -> UInt64 {
    guard case .number(let raw) = self, !raw.isEmpty,
      raw.utf8.allSatisfy({ (48...57).contains($0) }),
      let value = UInt64(raw), !positive || value > 0
    else { throw ContractError.invalid }
    return value
  }
  public func int32() throws -> Int32 {
    guard case .number(let raw) = self, let value = Int32(raw) else { throw ContractError.invalid }
    return value
  }
  public func boolean() throws -> Bool {
    guard case .bool(let value) = self else { throw ContractError.invalid }
    return value
  }
}

/// Bounded lexical decoder: duplicate keys are rejected before Foundation decoding.
public enum StrictJSON {
  public static func parse(_ data: Data) throws -> JSONValue {
    guard data.count <= 65536, String(data: data, encoding: .utf8) != nil else {
      throw ContractError.invalid
    }
    var reader = Reader(bytes: Array(data))
    let value = try reader.value(depth: 0)
    reader.whitespace()
    guard reader.index == reader.bytes.count else { throw ContractError.invalid }
    return value
  }
  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    _ = try parse(data)
    return try JSONDecoder().decode(type, from: data)
  }
  private struct Reader {
    let bytes: [UInt8]
    var index = 0
    mutating func whitespace() {
      while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    mutating func take(_ byte: UInt8) -> Bool {
      whitespace()
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }
    mutating func quoted() throws -> String {
      whitespace()
      let start = index
      guard take(34) else { throw ContractError.invalid }
      var escaped = false
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 34 && !escaped {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
        }
        if byte == 92 && !escaped { escaped = true } else { escaped = false }
      }
      throw ContractError.invalid
    }
    mutating func value(depth: Int) throws -> JSONValue {
      guard depth < 32 else { throw ContractError.invalid }
      whitespace()
      guard index < bytes.count else { throw ContractError.invalid }
      if bytes[index] == 34 { return .string(try quoted()) }
      if take(123) {
        var result: [String: JSONValue] = [:]
        if take(125) { return .object(result) }
        repeat {
          let key = try quoted()
          guard result[key] == nil, take(58) else { throw ContractError.invalid }
          result[key] = try value(depth: depth + 1)
          if take(125) { return .object(result) }
          guard take(44) else { throw ContractError.invalid }
        } while true
      }
      if take(91) {
        var result: [JSONValue] = []
        if take(93) { return .array(result) }
        repeat {
          result.append(try value(depth: depth + 1))
          if take(93) { return .array(result) }
          guard take(44) else { throw ContractError.invalid }
        } while true
      }
      let start = index
      while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
      guard let raw = String(bytes: bytes[start..<index], encoding: .utf8) else {
        throw ContractError.invalid
      }
      switch raw {
      case "true": return .bool(true)
      case "false": return .bool(false)
      case "null": return .null
      default:
        guard
          raw.range(
            of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression)
            != nil
        else {
          throw ContractError.invalid
        }
        return .number(raw)
      }
    }
  }
}
