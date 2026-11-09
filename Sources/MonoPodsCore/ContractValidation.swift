import Foundation

public enum ContractValidation {
  public static func hash(_ value: String) -> Bool {
    value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
  }
  public static func uuid(_ value: String) -> Bool { UUID(uuidString: value) != nil }
  /// Round-trip structure comparison rejects unknown keys at every nesting level,
  /// omitted mandatory nulls, ambiguous numbers, and extra enum discriminators.
  public static func decode<T: Codable>(_ type: T.Type, data: Data) throws -> T {
    let original = try StrictJSON.parse(data)
    let result = try JSONDecoder().decode(type, from: data)
    let canonical = try StrictJSON.parse(JSONEncoder().encode(result))
    guard original == canonical else { throw ContractError.invalid }
    return result
  }
}
extension LifecycleRecord {
  enum CodingKeys: String, CodingKey { case run, build, closedCleanly, exitReason, noticePending }
  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(run, forKey: .run)
    try fields.encode(build, forKey: .build)
    try fields.encode(closedCleanly, forKey: .closedCleanly)
    try fields.encode(exitReason, forKey: .exitReason)
    try fields.encode(noticePending, forKey: .noticePending)
  }
}
extension AudioRecord {
  enum CodingKeys: String, CodingKey {
    case initial, recoveryTarget, nextId, restoreRequired, phase, active, lastCompleted
  }
  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(initial, forKey: .initial)
    try fields.encode(recoveryTarget, forKey: .recoveryTarget)
    try fields.encode(nextId, forKey: .nextId)
    try fields.encode(restoreRequired, forKey: .restoreRequired)
    try fields.encode(phase, forKey: .phase)
    try fields.encode(active, forKey: .active)
    try fields.encode(lastCompleted, forKey: .lastCompleted)
  }
}
extension JournalRecord {
  public var contractValid: Bool {
    valid && ContractValidation.hash(lifecycle.build)
  }
  public static func decode(_ data: Data) throws -> Self {
    let record = try ContractValidation.decode(Self.self, data: data)
    guard record.contractValid else {
      throw ContractError.invalid
    }
    return record
  }
}
extension Observation {
  public var valid: Bool {
    guard context.valid else { return false }
    switch value {
    case .count(let count, let detection):
      return source != .m && (count.map { (0...2).contains($0) } ?? true)
        && (detection != .off || count == nil)
    case .transition: return source == .m
    }
  }
}
extension EngineInput {
  public var valid: Bool {
    switch self {
    case .journalLoaded(.record(let record)): return record.contractValid
    case .persistenceAcknowledged(let run, let id, _), .playCompleted(let run, let id, _):
      return run > 0 && id > 0
    case .route(let route): return route.map { $0.epoch > 0 && $0.deviceOrdinal > 0 } ?? true
    case .connection(let connection): return connection.epoch > 0
    case .streamStarted(let epoch, let nonce): return epoch > 0 && validNonce(nonce)
    case .heartbeat(let epoch, let nonce, let sequence):
      return epoch > 0 && sequence > 0 && validNonce(nonce)
    case .observation(let observation): return observation.valid
    case .history(let id, let context, let observation, _):
      return id > 0 && context.valid && (observation?.valid ?? true)
    case .gap(let epoch, _, _), .streamFinished(let epoch), .nowPlaying(let epoch, _, _):
      return epoch > 0
    case .audioObserved(let reading): return reading.valid
    case .audioWriteSkipped(let command): return command.valid
    case .writerCompleted(let receipt): return receipt.command.valid
    case .ownerAcquired(let run): return run > 0
    case .prepareUpdate(let id), .endUpdateHold(let id): return id > 0
    case .ownerConfirmed(let run, let build, _): return run > 0 && ContractValidation.hash(build)
    default: return true
    }
  }
}
private func validNonce(_ nonce: String) -> Bool {
  nonce.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
}
extension WriterCommand {
  public var valid: Bool {
    run > 0 && id > 0 && (context?.valid ?? recovery) && (!recovery || target == .stereo)
  }
}
extension EngineAction {
  public var valid: Bool {
    switch self {
    case .persist(let request):
      return request.id > 0 && request.record.contractValid
    case .writeTarget(let command): return command.valid
    case .play(let command):
      return command.run > 0 && command.id > 0 && command.episode > 0 && command.context.valid
        && command.command == 0
    case .pause(let context): return context.valid
    case .emitHeartbeat(let epoch, let nonce, let sequence):
      return epoch > 0 && sequence > 0 && validNonce(nonce)
    case .restartStream(let epoch, let delay):
      return epoch > 0 && delay >= 1_000_000_000 && delay <= 30_000_000_000
    case .queryHistory(let id, let context): return id > 0 && context.valid
    case .terminate(let code): return [0, 75].contains(code)
    case .updatePrepared(let id, _): return id > 0
    default: return true
    }
  }
}
