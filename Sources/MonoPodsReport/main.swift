import Darwin
import Foundation
import MonoPodsCore
import MonoPodsReportCLI

let result = ReportCommand.run(arguments: Array(CommandLine.arguments.dropFirst())) { path in
  let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  defer { try? handle.close() }
  var status = stat()
  guard fstat(descriptor, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
    status.st_size >= 0, status.st_size <= DiagnosticLimits.fileBytes
  else { throw CocoaError(.fileReadUnknown) }
  var data = Data()
  while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
    data.append(chunk)
    guard data.count <= DiagnosticLimits.fileBytes else { throw CocoaError(.fileReadTooLarge) }
  }
  return data
}
FileHandle.standardOutput.write(Data(result.output.utf8))
exit(result.exitCode)
