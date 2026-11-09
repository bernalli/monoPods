import Foundation

/// Size of one diagnostic file: the rotation threshold and the report's read limit. Two files
/// hold about four days of the 10 s heartbeat cycle.
public enum DiagnosticLimits {
  public static let fileBytes = 16 * 1024 * 1024
}
public struct LaunchPayload: Codable, Equatable, Sendable {
  public var utc: SourceTime
  public var boot: String
  public init(utc: SourceTime, boot: String) {
    self.utc = utc
    self.boot = boot
  }
}
public struct InputPayload: Codable, Equatable, Sendable {
  public var utc: SourceTime
  public var input: EngineInput
  public init(utc: SourceTime, input: EngineInput) {
    self.utc = utc
    self.input = input
  }
}
public struct ActionsPayload: Codable, Equatable, Sendable {
  public var utc: SourceTime
  public var actions: [EngineAction]
  public init(utc: SourceTime, actions: [EngineAction]) {
    self.utc = utc
    self.actions = actions
  }
}
public struct EndPayload: Codable, Equatable, Sendable {
  public var utc: SourceTime
  public var exitCode: Int32
  public init(utc: SourceTime, exitCode: Int32) {
    self.utc = utc
    self.exitCode = exitCode
  }
}
public enum EvidenceKind: String, Codable, Sendable {
  case streamAccessible, historyAccessible, effectiveMono, audiblePlayback, acousticLatency,
    lastEar, voluntaryPause, otherApps, otherModels, powerUse
}
/// Independent evidence must be identified and retained outside the diagnostic stream.
/// Durable audio receipts and MediaRemote accepted callbacks never create this payload.
public struct EvidencePayload: Codable, Equatable, Sendable {
  public var utc: SourceTime
  public var kind: EvidenceKind
  public var verified: Bool
  public var evidenceHash: String
  public init(utc: SourceTime, kind: EvidenceKind, verified: Bool, evidenceHash: String) {
    self.utc = utc
    self.kind = kind
    self.verified = verified
    self.evidenceHash = evidenceHash
  }
}
public enum TracePayload: Equatable, Sendable {
  case launch(LaunchPayload)
  case input(InputPayload)
  case actions(ActionsPayload)
  case end(EndPayload)
  case evidence(EvidencePayload)
  public var utc: SourceTime {
    switch self {
    case .launch(let value): value.utc
    case .input(let value): value.utc
    case .actions(let value): value.utc
    case .end(let value): value.utc
    case .evidence(let value): value.utc
    }
  }
}
public struct TraceRecord: Codable, Equatable, Sendable {
  public var v = 1
  public var build: String
  public var run: UInt64
  public var seq: UInt64
  public var m: UInt64
  public var payload: TracePayload
  public init(build: String, run: UInt64, seq: UInt64, m: UInt64, payload: TracePayload) {
    self.build = build
    self.run = run
    self.seq = seq
    self.m = m
    self.payload = payload
  }
  enum CodingKeys: String, CodingKey { case v, build, run, seq, m, event, payload }
  enum Event: String, Codable { case launch, input, actions, end }
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    v = try fields.decode(Int.self, forKey: .v)
    build = try fields.decode(String.self, forKey: .build)
    run = try fields.decode(UInt64.self, forKey: .run)
    seq = try fields.decode(UInt64.self, forKey: .seq)
    m = try fields.decode(UInt64.self, forKey: .m)
    switch try fields.decode(Event.self, forKey: .event) {
    case .launch: payload = .launch(try fields.decode(LaunchPayload.self, forKey: .payload))
    case .actions: payload = .actions(try fields.decode(ActionsPayload.self, forKey: .payload))
    case .end: payload = .end(try fields.decode(EndPayload.self, forKey: .payload))
    case .input:
      let wrapper = try fields.decode(TraceInput.self, forKey: .payload)
      switch wrapper {
      case .engine(let value): payload = .input(value)
      case .evidence(let value): payload = .evidence(value)
      }
    }
  }
  private enum TraceInput: Codable {
    case engine(InputPayload)
    case evidence(EvidencePayload)
  }
  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(v, forKey: .v)
    try fields.encode(build, forKey: .build)
    try fields.encode(run, forKey: .run)
    try fields.encode(seq, forKey: .seq)
    try fields.encode(m, forKey: .m)
    switch payload {
    case .launch(let value):
      try fields.encode(Event.launch, forKey: .event)
      try fields.encode(value, forKey: .payload)
    case .input(let value):
      try fields.encode(Event.input, forKey: .event)
      try fields.encode(TraceInput.engine(value), forKey: .payload)
    case .evidence(let value):
      try fields.encode(Event.input, forKey: .event)
      try fields.encode(TraceInput.evidence(value), forKey: .payload)
    case .actions(let value):
      try fields.encode(Event.actions, forKey: .event)
      try fields.encode(value, forKey: .payload)
    case .end(let value):
      try fields.encode(Event.end, forKey: .event)
      try fields.encode(value, forKey: .payload)
    }
  }
  public static func decode(_ data: Data) throws -> Self {
    let record = try ContractValidation.decode(Self.self, data: data)
    guard record.valid else { throw ContractError.invalid }
    return record
  }
  public var valid: Bool {
    guard v == 1, run > 0, seq > 0, ContractValidation.hash(build) else { return false }
    switch payload {
    case .launch(let value): return ContractValidation.uuid(value.boot)
    case .input(let value): return value.input.valid
    case .actions(let value): return value.actions.allSatisfy(\.valid)
    case .evidence(let value): return ContractValidation.hash(value.evidenceHash)
    case .end: return true
    }
  }
}
