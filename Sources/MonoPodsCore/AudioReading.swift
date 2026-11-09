import Foundation

public enum SystemMono: String, Codable, Sendable { case on, off, unreadable }

public struct AudioReading: Codable, Equatable, Sendable {
  public var generation: UInt64
  public var mode: Target?
  public var status: Int32
  public var systemMono: SystemMono

  public init(generation: UInt64, mode: Target?, status: Int32, systemMono: SystemMono) {
    self.generation = generation
    self.mode = mode
    self.status = status
    self.systemMono = systemMono
  }

  public var valid: Bool { generation > 0 && ((status == 0) == (mode != nil)) }

  enum CodingKeys: String, CodingKey { case generation, mode, status, systemMono }

  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(generation, forKey: .generation)
    try fields.encode(mode, forKey: .mode)
    try fields.encode(status, forKey: .status)
    try fields.encode(systemMono, forKey: .systemMono)
  }

  public static func decode(_ data: Data) throws -> Self {
    let reading = try ContractValidation.decode(Self.self, data: data)
    guard reading.valid else { throw ContractError.invalid }
    return reading
  }
}
