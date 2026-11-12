import CoreFoundation
import Foundation
import MonoPodsCore

public enum RouteIdentity {
  public static func normalize(_ address: String) -> String? {
    guard
      address.range(
        of: #"^([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5})$"#,
        options: .regularExpression) != nil
    else { return nil }
    return address.uppercased().replacingOccurrences(of: "-", with: ":")
  }
  /// CoreAudio names a Bluetooth output `ADDR:output`; only that exact suffix is removed.
  public static func uidAddress(_ uid: String) -> String? {
    let suffix = ":output"
    return normalize(uid.hasSuffix(suffix) ? String(uid.dropLast(suffix.count)) : uid)
  }
  // Each argument is an independent required system observation.
  // swiftlint:disable:next function_parameter_count
  public static func resolve(
    uid: String?, address: String?, connected: Bool, paired: Bool,
    bluetoothTransport: Bool, productID: Any?
  ) -> String? {
    guard connected, paired, bluetoothTransport, let uid, let address,
      let normalized = uidAddress(uid), normalized == normalize(address),
      let number = productID as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
      number.doubleValue >= 0, number.doubleValue <= 65535
    else { return nil }
    return normalized
  }
}

/// Translates identity and provenance. All decisions remain in Engine.
@MainActor public final class ObservationDriver {
  private let clock: () -> Instant
  private let submit: (EngineInput) -> Void
  private var address: String?
  private var ordinals: [String: UInt64] = [:]
  private var routeEpoch: UInt64 = 0
  private var connectionEpoch: UInt64 = 0
  public private(set) var streamEpoch: UInt64 = 0
  private var boundary: SourceTime?
  private var streamLines: UInt64 = 0
  private var streamEvidenceEpoch: UInt64 = 0
  /// Receives diary evidence: the kind and a hash of the bytes that prove it.
  public var evidence: ((EvidenceKind, String) -> Void)?
  /// Receives the ear side for the menu bar icon, and nil when the route changes. It is a channel
  /// beside `submit`, never through it: the engine cannot see the side.
  public var placement: ((EarSide?) -> Void)?
  /// Placement watermark, advanced by accepted rows and route changes. Buffered rows from a
  /// previous route cannot restore its side, even if newer than the last accepted placement.
  private var placementTime: SourceTime?
  /// The only non-JSON line accepted, and only as the first line of a stream.
  public static let streamHeader = Data("Filtering the log data".utf8)
  public init(clock: @escaping () -> Instant, submit: @escaping (EngineInput) -> Void) {
    self.clock = clock
    self.submit = submit
  }
  private func increment(_ value: inout UInt64) throws {
    guard value < UInt64.max else { throw RuntimeError.invalid }
    value += 1
  }
  public func route(address candidate: String?) {
    let value = candidate.flatMap(RouteIdentity.normalize)
    guard value != address else { return }
    address = value
    boundary = nil
    let changedAt = clock().utc
    if placementTime.map({ $0 < changedAt }) ?? true { placementTime = changedAt }
    placement?(nil)
    guard let value else {
      submit(.route(nil))
      return
    }
    do {
      try increment(&routeEpoch)
      try increment(&connectionEpoch)
      if ordinals[value] == nil { ordinals[value] = UInt64(ordinals.count) + 1 }
      submit(.route(Route(epoch: routeEpoch, deviceOrdinal: ordinals[value]!)))
      submit(.connection(Connection(epoch: connectionEpoch, boundary: nil)))
    } catch { submit(.route(nil)) }
  }
  /// Only an observed connection callback may establish this time; never app startup.
  public func connected(address candidate: String, at time: SourceTime) {
    guard RouteIdentity.normalize(candidate) == address, time <= clock().utc else { return }
    do {
      try increment(&connectionEpoch)
      boundary = time
      submit(.connection(Connection(epoch: connectionEpoch, boundary: time)))
    } catch { submit(.route(nil)) }
  }
  public func beginStream(nonce: String) throws -> UInt64 {
    try increment(&streamEpoch)
    streamLines = 0
    submit(.streamStarted(epoch: streamEpoch, nonce: nonce))
    return streamEpoch
  }
  public func consume(_ data: Data, epoch: UInt64) {
    guard epoch == streamEpoch else { return }
    if streamLines < UInt64.max { streamLines += 1 }
    if streamLines == 1, data.starts(with: Self.streamHeader) { return }
    do {
      switch try SystemLogEnvelope.decode(data) {
      case .finished: submit(.gap(epoch: epoch, reason: .finished, faultTime: nil))
      case .event(let record):
        if streamEvidenceEpoch != epoch {
          streamEvidenceEpoch = epoch
          evidence?(.streamAccessible, ArtifactHash.data(data))
        }
        let time = try SourceTime(record.timestamp)
        switch EarLine.parse(record: record) {
        case .heartbeat(let nonce, let sequence):
          submit(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence))
        case .playback(let playing):
          submit(.nowPlaying(epoch: epoch, playing: playing, sourceTime: time))
        case .gap: submit(.gap(epoch: epoch, reason: .sourceUnreadable, faultTime: time))
        case .unrelated: place(record, at: time)
        default:
          if let observation = observation(record, provenance: .live) {
            submit(.observation(observation))
          }
        }
      }
    } catch { submit(.gap(epoch: epoch, reason: .sourceUnreadable, faultTime: nil)) }
  }
  public func transportGap(epoch: UInt64) {
    guard epoch == streamEpoch else { return }
    // An overlong line still occupies a position: a header after it is not the first line.
    if streamLines < UInt64.max { streamLines += 1 }
    submit(.gap(epoch: epoch, reason: .transport, faultTime: nil))
  }
  // The read result, its correlation and its evidence hash arrive together from one child.
  // swiftlint:disable:next function_parameter_count
  public func history(
    _ capture: HistoryCapture, id: UInt64, context: ObservationContext, exitCode: Int32,
    truncated: Bool, evidenceHash: String
  ) {
    let complete = capture.complete(exitCode: exitCode, truncated: truncated)
    if complete { evidence?(.historyAccessible, evidenceHash) }
    let now = clock()
    let result = HistorySnapshot.select(
      records: capture.records,
      context: HistoryContext(
        address: address ?? "", connection: boundary?.raw, readTime: now.utc.raw, complete: complete
      ))
    var selected: Observation?
    if case .known(_, let time) = result {
      // A transition can share the source time of the selected state: only a count answers.
      for record in capture.records.reversed() where record.timestamp == time {
        guard let candidate = observation(record, provenance: .history),
          case .count = candidate.value
        else { continue }
        selected = candidate
        break
      }
    }
    // Context is the query's original context; a late response cannot acquire a new epoch.
    if selected?.context != context { selected = nil }
    submit(.history(query: id, context: context, observation: selected, complete: complete))
  }
  /// The side channel is read here, after the engine parse and only for rows that the parse
  /// leaves `.unrelated`: a row that gives a count, a transition or a gap never reaches it, and a
  /// placement row never produces an engine input. Only the live stream feeds it; history does not.
  private func place(_ record: LogRecord, at time: SourceTime) {
    guard let address, let side = PlacementLine.side(record: record, route: address),
      time <= clock().utc, boundary.map({ time >= $0 }) ?? true,
      placementTime.map({ time >= $0 }) ?? true
    else { return }
    placementTime = time
    placement?(side)
  }
  private func observation(_ record: LogRecord, provenance: Provenance) -> Observation? {
    guard let address, let ordinal = ordinals[address], streamEpoch > 0,
      let time = try? SourceTime(record.timestamp)
    else { return nil }
    let value: ObservationValue
    let source: Source
    switch EarLine.parse(record: record) {
    case .state(let state) where state.address == address:
      source = record.process == "bluetoothd" ? .s1 : .s3
      let detection: Detection =
        state.detectionOff
        ? .off : (state.primary == .unknown || state.secondary == .unknown ? .unknown : .on)
      value = .count(state.count, detection: detection)
    case .transition(let identity, let from, let to) where identity == address:
      guard let old = EarStatus(rawValue: from.lowercased()),
        let new = EarStatus(rawValue: to.lowercased())
      else { return nil }
      source = .m
      value = .transition(from: old, to: new)
    default: return nil
    }
    return Observation(
      sourceTime: time, source: source, provenance: provenance,
      context: ObservationContext(
        routeEpoch: routeEpoch, streamEpoch: streamEpoch, connectionEpoch: connectionEpoch,
        deviceOrdinal: ordinal),
      receivedContinuousNanos: clock().continuousNanos, value: value)
  }
}
