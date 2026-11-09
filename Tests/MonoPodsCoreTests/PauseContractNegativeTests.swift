import Foundation
import Testing

@testable import MonoPodsCore

@Test func pauseContractRejectsMalformedFamilies() throws {
  let keys = ["routeEpoch", "streamEpoch", "connectionEpoch", "deviceOrdinal"]
  let fields = keys.map { "\"\($0)\":1" }
  func action(_ fields: [String]) -> String {
    "{\"pause\":{\"context\":{\(fields.joined(separator: ","))}}}"
  }
  func reject(_ text: String) {
    #expect(throws: (any Error).self) {
      let decoded = try ContractValidation.decode(EngineAction.self, data: Data(text.utf8))
      guard decoded.valid else { throw ContractError.invalid }
    }
  }
  let valid = action(fields)
  #expect(try ContractValidation.decode(EngineAction.self, data: Data(valid.utf8)).valid)
  for end in valid.indices { reject(String(valid[..<end])) }
  for index in fields.indices {
    var missing = fields
    missing.remove(at: index)
    reject(action(missing))
    reject(action(fields + [fields[index]]))
    for value in [
      "true", "false", "null", "\"1\"", "[]", "{}", "0", "-1",
      "1.0", "1e0", "18446744073709551616",
    ] {
      var changed = fields
      changed[index] = "\"\(keys[index])\":\(value)"
      reject(action(changed))
    }
  }
  reject(action(fields + ["\"extra\":0"]))
  let context = "{\(fields.joined(separator: ","))}"
  for (key, value) in [("pause", "{\"context\":\(context)}"), ("context", context)] {
    let entry = "\"\(key)\":\(value)"
    reject(valid.replacingOccurrences(of: entry, with: ""))
    reject(valid.replacingOccurrences(of: entry, with: "\(entry),\(entry)"))
    reject(valid.replacingOccurrences(of: entry, with: "\(entry),\"extra\":0"))
    for wrong in ["null", "true", "1", "\"x\"", "[]"] {
      reject(valid.replacingOccurrences(of: entry, with: "\"\(key)\":\(wrong)"))
    }
  }
}
