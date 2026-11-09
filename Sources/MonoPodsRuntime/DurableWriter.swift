import Foundation
import MonoPodsCore

public enum AudioInvocationResult: Sendable {
  case completed(Int32)
  case systemMono
}

public enum DurableWriter {
  /// The caller holds owner.lock. Only this worker writes the journal until its receipt is saved.
  public static func execute(
    command: WriterCommand, files: AtomicRuntimeFiles, owner: InstanceLock,
    invoke: (Target) throws -> Int32
  ) -> WriterReceipt {
    let result = executeAudio(command: command, files: files, owner: owner) { target in
      .completed(try invoke(target))
    }
    guard case .completed(let receipt) = result else {
      return WriterReceipt(command: command, exitCode: -1, quiescent: false, persisted: false)
    }
    return receipt
  }

  /// A system override returns the still-running command without inventing a receipt.
  public static func executeAudio(
    command: WriterCommand, files: AtomicRuntimeFiles, owner: InstanceLock,
    invoke: (Target) throws -> AudioInvocationResult
  ) -> AudioWriteResult {
    defer { withExtendedLifetime(owner) {} }
    var receipt = WriterReceipt(command: command, exitCode: -1, quiescent: false, persisted: false)
    guard command.valid, case .record(var record) = files.load(),
      record.lifecycle.run == command.run, record.audio.phase == .prepared,
      record.audio.active == AudioCommand(id: command.id, target: command.target)
    else { return .completed(receipt) }
    do {
      record.audio.phase = .running
      try files.persist(record: record)
    } catch { return .completed(receipt) }
    do {
      switch try invoke(command.target) {
      case .completed(let status): receipt.exitCode = status
      case .systemMono: return .systemMono(command)
      }
      // Quiescence records the end of the invocation, not an acoustic measurement.
      receipt.quiescent = true
      record.audio.active = nil
      record.audio.lastCompleted = CommandReceipt(
        id: command.id, target: command.target, exitCode: receipt.exitCode)
      let restored = command.recovery && command.target == .stereo && receipt.exitCode == 0
      record.audio.restoreRequired = !restored
      record.audio.phase = restored ? .restoreCommandCompleted : .completed
      try files.persist(record: record)
      receipt.persisted = true
    } catch {
      record.audio.phase = .uncertain
      record.audio.restoreRequired = true
      try? files.persist(record: record)
    }
    return .completed(receipt)
  }
}
