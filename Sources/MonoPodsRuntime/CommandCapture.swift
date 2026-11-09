import Foundation

@MainActor public enum CommandCapture {
  public static func run(executable: String, arguments: [String], seconds: UInt64 = 30) async -> (
    Data, Int32
  ) {
    let child = LogProcess()
    var bytes = Data()
    var overflow = false
    let code: Int32 = await withCheckedContinuation { continuation in
      do {
        try child.start(
          executable: executable, arguments: arguments, timeoutSeconds: seconds,
          chunk: { data in
            if bytes.count + data.count > 65536 {
              overflow = true
              child.stop()
            } else {
              bytes.append(data)
            }
          }, finished: { continuation.resume(returning: $0) })
      } catch { continuation.resume(returning: -1) }
    }
    return (bytes, overflow ? -1 : code)
  }
}
