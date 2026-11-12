import Foundation

public struct HistoryContext: Sendable {
  public var address: String
  public var connection: String?
  public var readTime: String
  public var complete: Bool
  public var faultTime: String?
  public var faultTimeUnknown: Bool = false
  public init(
    address: String, connection: String?, readTime: String, complete: Bool,
    faultTime: String? = nil, faultTimeUnknown: Bool = false
  ) {
    self.address = address
    self.connection = connection
    self.readTime = readTime
    self.complete = complete
    self.faultTime = faultTime
    self.faultTimeUnknown = faultTimeUnknown
  }
}
public enum SnapshotResult: Equatable, Sendable {
  case known(EarState, String)
  case unknown
  case incomplete
}
public enum HistorySnapshot {
  public static func select(records: [LogRecord], context: HistoryContext) -> SnapshotResult {
    guard context.complete else { return .incomplete }
    guard !context.faultTimeUnknown, let boundaryRaw = context.connection,
      let boundary = try? SourceTime(boundaryRaw), let read = try? SourceTime(context.readTime),
      boundary <= read
    else { return .unknown }
    let fault = context.faultTime.flatMap { try? SourceTime($0) }
    if context.faultTime != nil && fault == nil { return .unknown }
    var latest: (EarState, SourceTime)?
    var latestConflicted = false
    var latestUnreadable = fault
    for record in records {
      guard let time = try? SourceTime(record.timestamp) else { return .incomplete }
      guard time > boundary, time <= read else { continue }
      switch EarLine.parse(record: record) {
      case .gap:
        if latestUnreadable == nil || time > latestUnreadable! { latestUnreadable = time }
      case .state(let state) where state.address == context.address:
        if latest == nil || time > latest!.1 {
          latest = (state, time)
          latestConflicted = false
        } else if time == latest!.1 && state != latest!.0 {
          latestConflicted = true
        }
      default: break
      }
    }
    guard !latestConflicted, let (state, time) = latest, state.count != nil || state.detectionOff,
      latestUnreadable == nil || time > latestUnreadable!
    else {
      return .unknown
    }
    return .known(state, time.raw)
  }
}
