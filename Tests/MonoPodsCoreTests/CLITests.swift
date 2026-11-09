import Foundation
import MonoPodsCore
import MonoPodsReportCLI
import Testing

@Test func hostileCLIArgumentsFailWithoutReadingFiles() {
  let hash = String(repeating: "a", count: 64)
  let cases = [
    [], ["--build", hash], ["--build", hash, "--build", hash],
    ["--build", hash, "--from", "2001-01-01T00:00:01Z", "--to", "2001-01-01T00:00:00Z", "file"],
    [
      "--build", "$(command)", "--from", "2001-01-01T00:00:00Z", "--to", "2001-01-01T00:00:01Z",
      "file",
    ],
  ]
  for arguments in cases {
    var reads = 0
    let result = ReportCommand.run(arguments: arguments) { _ in
      reads += 1
      return Data()
    }
    #expect(result.exitCode == 1)
    #expect(reads == 0)
  }
}
@Test func cliUsesRealExitCodesAndMarksTruncatedInputIncomplete() throws {
  let hash = String(repeating: "a", count: 64)
  let arguments = [
    "--build", hash, "--from", "2001-01-01T00:00:00Z", "--to", "2001-01-01T00:01:00Z", "fixture",
  ]
  let result = ReportCommand.run(arguments: arguments) { _ in Data() }
  #expect(result.exitCode == 2)
  #expect(result.output.contains("INSUFFICIENT"))
  let failed = ReportCommand.run(arguments: arguments) { _ in Data("{}\n".utf8) }
  #expect(failed.exitCode == 1)
  #expect(failed.output.contains("FAIL"))
}
@Test func cliReadsDiagnosticFilesUpToTheRotationSize() {
  #expect(DiagnosticLimits.fileBytes == 16 * 1024 * 1024)
  let hash = String(repeating: "a", count: 64)
  let arguments = [
    "--build", hash, "--from", "2001-01-01T00:00:00Z", "--to", "2001-01-01T00:01:00Z", "fixture",
  ]
  let full = ReportCommand.run(arguments: arguments) { _ in
    Data(repeating: 120, count: DiagnosticLimits.fileBytes)
  }
  #expect(full.exitCode == 2)
  #expect(full.output.contains("incompleteSegment"))
  let over = ReportCommand.run(arguments: arguments) { _ in
    Data(repeating: 120, count: DiagnosticLimits.fileBytes + 1)
  }
  #expect(over.exitCode == 1)
  #expect(over.output.hasPrefix("FAIL: invalid arguments"))
}
