import Foundation
import MonoPodsCore

public struct CLIResult: Sendable {
  public var exitCode: Int32
  public var output: String
}
public enum ReportCommand {
  public static let usage = "monopods-report --build <hash> --from <UTC> --to <UTC> <log.1> [<log>]"
  public static func run(arguments: [String], load: (String) throws -> Data) -> CLIResult {
    if arguments == ["--help"] { return CLIResult(exitCode: 0, output: usage + "\n") }
    do {
      let parsed = try parse(arguments)
      var records: [TraceRecord] = []
      var complete = true
      var malformed = false
      for file in parsed.files {
        let data = try load(file)
        guard data.count <= DiagnosticLimits.fileBytes else { throw ContractError.invalid }
        let decoded = LogReport.decodeJSONL(data)
        records += decoded.records
        complete = complete && decoded.complete
        malformed = malformed || decoded.malformed
      }
      var report = LogReport.evaluate(records: records, selection: parsed.selection)
      if malformed {
        report.verdict = .fail
        report.issues.append(.malformedRecord)
      } else if !complete {
        if report.verdict != .fail { report.verdict = .insufficient }
        report.issues.append(.incompleteSegment)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let output = try encoder.encode(report)
      guard let text = String(data: output, encoding: .utf8) else { throw ContractError.invalid }
      return CLIResult(exitCode: report.exitCode, output: text + "\n")
    } catch {
      // Never echo untrusted arguments, file paths, or underlying errors.
      return CLIResult(
        exitCode: 1, output: "FAIL: invalid arguments or unreadable input\n" + usage + "\n")
    }
  }
  private static func parse(_ arguments: [String]) throws -> (
    selection: AcceptanceSelection, files: [String]
  ) {
    guard arguments.count == 7 || arguments.count == 8,
      arguments[0] == "--build", arguments[2] == "--from", arguments[4] == "--to",
      ContractValidation.hash(arguments[1]), arguments[3].hasSuffix("Z"),
      arguments[5].hasSuffix("Z")
    else {
      throw ContractError.invalid
    }
    let from = try SourceTime(arguments[3])
    let to = try SourceTime(arguments[5])
    let files = Array(arguments.dropFirst(6))
    guard from < to, Set(files).count == files.count,
      files.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") })
    else {
      throw ContractError.invalid
    }
    return (AcceptanceSelection(build: arguments[1], from: from, to: to), files)
  }
}
