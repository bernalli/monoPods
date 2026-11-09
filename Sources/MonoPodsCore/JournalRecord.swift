import Foundation

public enum Target: String, Codable, Sendable { case mono, stereo }
public enum ExitReason: String, Codable, Sendable {
  case user, logout, signal
}
public enum JournalPhase: String, Codable, Sendable {
  case idle, prepared, running, completed, restoreCommandCompleted, uncertain
}
public struct AudioCommand: Codable, Equatable, Sendable {
  public var id: UInt64
  public var target: Target
  public init(id: UInt64, target: Target) {
    self.id = id
    self.target = target
  }
}
public struct CommandReceipt: Codable, Equatable, Sendable {
  public var id: UInt64
  public var target: Target
  public var exitCode: Int32
  public init(id: UInt64, target: Target, exitCode: Int32) {
    self.id = id
    self.target = target
    self.exitCode = exitCode
  }
}
public struct LifecycleRecord: Codable, Equatable, Sendable {
  public var run: UInt64
  public var build: String
  public var closedCleanly: Bool
  public var exitReason: ExitReason?
  public var noticePending: Bool
}
public struct AudioRecord: Codable, Equatable, Sendable {
  public var initial = "unknown"
  public var recoveryTarget: Target = .stereo
  public var nextId: UInt64 = 1
  public var restoreRequired = false
  public var phase: JournalPhase = .idle
  public var active: AudioCommand?
  public var lastCompleted: CommandReceipt?
}
public struct JournalRecord: Codable, Equatable, Sendable {
  public var v = 1
  public var lifecycle: LifecycleRecord
  public var audio = AudioRecord()
  public init(run: UInt64, build: String) {
    lifecycle = LifecycleRecord(
      run: run, build: build, closedCleanly: true, exitReason: nil, noticePending: false)
  }
  public var valid: Bool {
    guard v == 1, lifecycle.run > 0, !lifecycle.build.isEmpty, audio.initial == "unknown",
      audio.recoveryTarget == .stereo,
      audio.nextId > 0, audio.active.map({ $0.id > 0 && $0.id < audio.nextId }) ?? true,
      audio.lastCompleted.map({ $0.id > 0 && $0.id < audio.nextId }) ?? true
    else { return false }
    switch audio.phase {
    case .idle: return audio.active == nil && !audio.restoreRequired
    case .restoreCommandCompleted:
      return audio.active == nil && !audio.restoreRequired && audio.lastCompleted?.target == .stereo
        && audio.lastCompleted?.exitCode == 0
    case .prepared, .running: return audio.active != nil && audio.restoreRequired
    case .completed:
      return audio.active == nil && audio.lastCompleted != nil && audio.restoreRequired
    case .uncertain: return audio.restoreRequired
    }
  }
}
public enum RuntimeLoad: Codable, Equatable, Sendable {
  case missing
  case record(JournalRecord)
  case blocked
}
public protocol RuntimeFiles: Sendable {
  func load() -> RuntimeLoad
  func persist(record: JournalRecord) throws
}
