import Foundation

public struct Instant: Codable, Equatable, Sendable {
  public let continuousNanos: UInt64
  public let utc: SourceTime
  public init(continuousNanos: UInt64, utc: SourceTime) {
    self.continuousNanos = continuousNanos
    self.utc = utc
  }
}
public enum Source: String, Codable, Sendable { case s1, s3, m }
public enum Provenance: String, Codable, Sendable { case live, history }
public enum Detection: String, Codable, Sendable { case on, off, unknown }
public enum EarStatus: String, Codable, Sendable { case unknown, none, one, both }
public struct ObservationContext: Codable, Equatable, Hashable, Sendable {
  public var routeEpoch: UInt64
  public var streamEpoch: UInt64
  public var connectionEpoch: UInt64
  public var deviceOrdinal: UInt64
  public init(
    routeEpoch: UInt64, streamEpoch: UInt64, connectionEpoch: UInt64, deviceOrdinal: UInt64
  ) {
    self.routeEpoch = routeEpoch
    self.streamEpoch = streamEpoch
    self.connectionEpoch = connectionEpoch
    self.deviceOrdinal = deviceOrdinal
  }
  public var valid: Bool {
    routeEpoch > 0 && streamEpoch > 0 && connectionEpoch > 0 && deviceOrdinal > 0
  }
}
public enum ObservationValue: Codable, Equatable, Sendable {
  case count(Int?, detection: Detection)
  case transition(from: EarStatus, to: EarStatus)
}
public struct Observation: Codable, Equatable, Sendable {
  public var sourceTime: SourceTime
  public var source: Source
  public var provenance: Provenance
  public var context: ObservationContext
  public var receivedContinuousNanos: UInt64
  public var value: ObservationValue
  public init(
    sourceTime: SourceTime, source: Source, provenance: Provenance, context: ObservationContext,
    receivedContinuousNanos: UInt64, value: ObservationValue
  ) {
    self.sourceTime = sourceTime
    self.source = source
    self.provenance = provenance
    self.context = context
    self.receivedContinuousNanos = receivedContinuousNanos
    self.value = value
  }
}
public struct Route: Codable, Equatable, Sendable {
  public var epoch: UInt64
  public var deviceOrdinal: UInt64
  public init(epoch: UInt64, deviceOrdinal: UInt64) {
    self.epoch = epoch
    self.deviceOrdinal = deviceOrdinal
  }
}
public struct Connection: Codable, Equatable, Sendable {
  public var epoch: UInt64
  public var boundary: SourceTime?
  public init(epoch: UInt64, boundary: SourceTime?) {
    self.epoch = epoch
    self.boundary = boundary
  }
}
public enum GapReason: String, Codable, Sendable {
  case transport, sourceUnreadable, clockChanged, finished
}
public enum Notice: String, Codable, Sendable {
  case detectionDisabled, detectionQuitReminder, previousCrash, persistenceFailed, recoveryBlocked,
    stereoNotRestored
  case commandFailed
}
public struct PersistenceRequest: Codable, Equatable, Sendable {
  public var id: UInt64
  public var record: JournalRecord
}
public struct WriterCommand: Codable, Equatable, Sendable {
  public var run: UInt64
  public var id: UInt64
  public var context: ObservationContext?
  public var target: Target
  public var recovery: Bool
}
public struct WriterReceipt: Codable, Equatable, Sendable {
  public var command: WriterCommand
  public var exitCode: Int32
  public var quiescent: Bool
  public var persisted: Bool
  public init(command: WriterCommand, exitCode: Int32, quiescent: Bool, persisted: Bool) {
    self.command = command
    self.exitCode = exitCode
    self.quiescent = quiescent
    self.persisted = persisted
  }
}
public struct PlayCommand: Codable, Equatable, Sendable {
  public var run: UInt64
  public var id: UInt64
  public var episode: UInt64
  public var context: ObservationContext
  public var command = 0
}
public enum EngineInput: Codable, Equatable, Sendable {
  case ownerWaiting
  case ownerAcquired(run: UInt64)
  case journalLoaded(RuntimeLoad)
  case persistenceAcknowledged(run: UInt64, id: UInt64, success: Bool)
  case route(Route?)
  case connection(Connection)
  case streamStarted(epoch: UInt64, nonce: String)
  case heartbeat(epoch: UInt64, nonce: String, sequence: UInt64)
  case observation(Observation)
  case history(
    query: UInt64, context: ObservationContext, observation: Observation?, complete: Bool)
  case gap(epoch: UInt64, reason: GapReason, faultTime: SourceTime?)
  case streamFinished(epoch: UInt64)
  /// The now-playing application changed between playing and not playing, at `sourceTime`.
  case nowPlaying(epoch: UInt64, playing: Bool, sourceTime: SourceTime)
  case pause(SourceTime)
  case sentinelPlay(SourceTime)
  case sentinelToggle(SourceTime)
  case sentinelAvailable(Bool)
  case audioObserved(AudioReading)
  case audioWriteSkipped(WriterCommand)
  case writerCompleted(WriterReceipt)
  case playCompleted(run: UInt64, id: UInt64, accepted: Bool)
  case environment(awake: Bool, bluetooth: Bool)
  case automation(Bool)
  case ownerConfirmed(run: UInt64, build: String, healthy: Bool)
  case reopen
  case noticePresented(Notice, success: Bool)
  case quit(ExitReason)
  /// Restore Stereo as the Quit does, without terminating, before an update may be installed.
  case prepareUpdate(id: UInt64)
  /// The update preparation `id` ended without an installation: ordinary commands resume.
  case endUpdateHold(id: UInt64)
  case tick
  /// Sent after all currently queued inputs have been consumed, including persistence callbacks.
  case drain
}
public enum EngineAction: Codable, Equatable, Sendable {
  case acquireOwner
  case persist(PersistenceRequest)
  case writeTarget(WriterCommand)
  case play(PlayCommand)
  /// Undoes the Play that macOS sends when an earbud goes in. It has no receipt: a Pause on a
  /// stopped player has no effect, and the engine decides nothing from the result.
  case pause(context: ObservationContext)
  case emitHeartbeat(epoch: UInt64, nonce: String, sequence: UInt64)
  case restartStream(epoch: UInt64, afterNanos: UInt64)
  case queryHistory(id: UInt64, context: ObservationContext)
  case showNotice(Notice)
  case restoreIcon
  case terminate(Int32)
  /// The single result of the update preparation `id`.
  case updatePrepared(id: UInt64, result: UpdatePreparationResult)
}
/// What the engine proved before an update: only the first two allow an installation.
public enum UpdatePreparationResult: String, Codable, Equatable, Sendable {
  case stereoConfirmed, nothingToRestore, unconfirmed
}
public struct EngineSnapshot: Equatable, Sendable {
  public var audio: AudioReading?
  public var count: Int?
  public var detection: Detection
  public var desiredTarget: Target?
  public var lastCompleted: CommandReceipt?
  public var blocked: Bool
  public var healthy: Bool
  public var operational: Bool
  public var terminated: Bool
  public var restoreConfirmed: Bool
  /// A journal debt from a previous run is still being restored.
  public var recoveryPending = false
}

/// Absolute preparation boundaries; calculated once from the injected monotonic start.
public struct UpdatePreparationWindow: Equatable, Sendable {
  public let start: UInt64
  public let retryEnd: UInt64
  public let warning: UInt64
  public let end: UInt64
  public init(start: UInt64) {
    self.start = start
    // Saturation closes the window at the clock boundary instead of wrapping it into the past.
    retryEnd = start + min(1_500_000_000, UInt64.max - start)
    warning = retryEnd
    end = start + min(2_000_000_000, UInt64.max - start)
  }
}
