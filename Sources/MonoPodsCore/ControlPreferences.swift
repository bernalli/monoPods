import Foundation

public struct ControlPreferences: Codable, Equatable, Sendable {
  public var v = 1
  public var automationEnabled = true
  public var menuBarVisible = true
  public var launchAtLogin = true
  public init() {}
  public static func decode(_ data: Data) throws -> Self {
    let value = try ContractValidation.decode(Self.self, data: data)
    guard value.v == 1 else { throw ContractError.invalid }
    return value
  }
}
public struct HeartbeatRecord: Codable, Equatable, Sendable {
  public var v: Int
  public var epoch: UInt64
  public var nonce: String
  public var sequence: UInt64
  public var issuedContinuousNanos: UInt64
  public var receivedContinuousNanos: UInt64
  public static func decode(_ data: Data) throws -> Self {
    let value = try ContractValidation.decode(Self.self, data: data)
    guard value.v == 1, value.epoch > 0, value.sequence > 0,
      value.nonce.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil,
      value.receivedContinuousNanos >= value.issuedContinuousNanos,
      value.receivedContinuousNanos - value.issuedContinuousNanos < 25_000_000_000
    else { throw ContractError.invalid }
    return value
  }
}
