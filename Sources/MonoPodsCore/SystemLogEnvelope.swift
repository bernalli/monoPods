import Foundation

/// Observed log-show envelope. Stream compatibility is measured separately at runtime.
public enum SystemLogEnvelope: Sendable {
  case event(LogRecord)
  case finished(UInt64)

  public static func decode(_ data: Data) throws -> Self {
    guard case .object(let fields) = try StrictJSON.parse(data) else { throw ContractError.invalid }
    if fields["finished"] != nil || fields["count"] != nil {
      guard Set(fields.keys) == ["count", "finished"], try fields["finished"]!.uint() == 1 else {
        throw ContractError.invalid
      }
      return .finished(try fields["count"]!.uint())
    }
    let required: Set<String> = [
      "timestamp", "processImagePath", "subsystem", "category", "eventMessage",
    ]
    let strings: Set<String> = [
      "timezoneName", "messageType", "eventType", "launchPersonaName", "formatString",
      "personaName", "senderImagePath",
    ]
    let numbers: Set<String> = [
      "userID", "activityIdentifier", "threadID",
      "launchPersonaID", "personaID", "machTimestamp", "traceID", "processID",
      "senderProgramCounter", "parentActivityIdentifier",
    ]
    let signed: Set<String> = ["personaType", "launchPersonaType"]
    let uuids: Set<String> = ["senderImageUUID", "bootUUID", "processImageUUID"]
    let allowed = required.union(strings).union(numbers).union(signed).union(uuids).union([
      "source", "backtrace",
    ])
    guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: allowed) else {
      throw ContractError.invalid
    }
    for key in required.union(strings).intersection(fields.keys) { _ = try fields[key]!.string() }
    for key in numbers.intersection(fields.keys) { _ = try fields[key]!.uint() }
    for key in signed.intersection(fields.keys) { _ = try fields[key]!.int32() }
    for key in uuids.intersection(fields.keys) {
      let value = try fields[key]!.string()
      // `log stream` writes an empty bootUUID on every row; `log show` writes the real one.
      if key == "bootUUID", value.isEmpty { continue }
      guard ContractValidation.uuid(value) else { throw ContractError.invalid }
    }
    if let source = fields["source"], source != .null { throw ContractError.invalid }
    if let backtrace = fields["backtrace"] {
      let object = try backtrace.object(keys: ["frames"])
      guard case .array(let frames) = object["frames"]! else { throw ContractError.invalid }
      for frame in frames {
        let item = try frame.object(keys: ["imageOffset", "imageUUID"])
        _ = try item["imageOffset"]!.uint()
        guard ContractValidation.uuid(try item["imageUUID"]!.string()) else {
          throw ContractError.invalid
        }
      }
    }
    let time = try fields["timestamp"]!.string()
    _ = try SourceTime(time)
    let path = try fields["processImagePath"]!.string()
    guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\n"), !path.contains("\0")
    else {
      throw ContractError.invalid
    }
    return try .event(
      LogRecord(
        timestamp: time, process: String(path.split(separator: "/").last!),
        subsystem: fields["subsystem"]!.string(), category: fields["category"]!.string(),
        message: fields["eventMessage"]!.string()))
  }
}
