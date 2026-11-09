import CoreServices
import Darwin
import Foundation
import MachO
import MonoPodsCore
import Security

/// One update from the running build to a newer one, within one process.
public struct UpdateTransition: Equatable, Sendable {
  public let id: UInt64
  public let sourceBuild: Int
  public let destinationBuild: Int
  public init(id: UInt64, sourceBuild: Int, destinationBuild: Int) {
    self.id = id
    self.sourceBuild = sourceBuild
    self.destinationBuild = destinationBuild
  }
  /// Bundle versions are positive integers below one billion, and an update only goes up.
  public static let maximumBuild = 999_999_999
  public var valid: Bool {
    id > 0 && sourceBuild > 0 && destinationBuild > sourceBuild
      && destinationBuild <= Self.maximumBuild
  }
}

/// The durable record that an installer may replace the bundle. Schema version 1, closed.
public struct UpdateHandoff: Codable, Equatable, Sendable {
  public static let fileName = "update-handoff.json"
  public enum Phase: String, Codable, Sendable { case armed }
  public let v: Int
  public let id: UInt64
  public let sourceBuild: Int
  public let destinationBuild: Int
  public let sourceManifest: String
  public let outcome: UpdatePreparationResult
  public let phase: Phase
  public init(
    transition: UpdateTransition, sourceManifest: String, outcome: UpdatePreparationResult
  ) {
    v = 1
    id = transition.id
    sourceBuild = transition.sourceBuild
    destinationBuild = transition.destinationBuild
    self.sourceManifest = sourceManifest
    self.outcome = outcome
    phase = .armed
  }
  public var transition: UpdateTransition {
    UpdateTransition(id: id, sourceBuild: sourceBuild, destinationBuild: destinationBuild)
  }
  public static func decode(_ data: Data) throws -> Self {
    let value = try ContractValidation.decode(Self.self, data: data)
    guard value.v == 1, value.transition.valid, ContractValidation.hash(value.sourceManifest),
      value.outcome != .unconfirmed
    else { throw RuntimeError.invalid }
    return value
  }
}

/// Durable user confirmation retained until the source build completes recovery.
public struct UpdateUnlock: Codable, Equatable, Sendable {
  public static let fileName = "update-unlock.json"
  public enum Outcome: String, Codable, Sendable { case userConfirmed }
  public let v: Int
  public let id: UInt64
  public let sourceBuild: Int
  public let confirmedAt: SourceTime
  public let outcome: Outcome
  public init(handoff: UpdateHandoff, confirmedAt: SourceTime) {
    v = 1
    id = handoff.id
    sourceBuild = handoff.sourceBuild
    self.confirmedAt = confirmedAt
    outcome = .userConfirmed
  }
  public static func decode(_ data: Data) throws -> Self {
    let value = try ContractValidation.decode(Self.self, data: data)
    guard value.v == 1, value.id > 0, value.sourceBuild > 0,
      value.sourceBuild <= UpdateTransition.maximumBuild
    else { throw RuntimeError.invalid }
    return value
  }
  func matches(_ handoff: UpdateHandoff) -> Bool {
    id == handoff.id && sourceBuild == handoff.sourceBuild
  }
}

public protocol UpdateUnlockStore: HandoffStore {
  func readUnlock() throws -> Data?
  func writeUnlock(_ data: Data) throws
  func removeUnlock() throws
}

extension AtomicRuntimeFiles: UpdateUnlockStore {
  public func readUnlock() throws -> Data? { try read(UpdateUnlock.fileName) }
  public func writeUnlock(_ data: Data) throws { try write(data, name: UpdateUnlock.fileName) }
  public func removeUnlock() throws {
    // Apply the same ownership, mode and link checks used by reads and replacement.
    _ = try readUnlock()
    if unlinkat(descriptor, UpdateUnlock.fileName, 0) != 0, errno != ENOENT {
      throw RuntimeError.io(errno)
    }
    guard fsync(descriptor) == 0 else { throw RuntimeError.io(errno) }
  }
}

/// Keeps owner.lock alive across validation and every durable recovery transition.
final class UpdateUnlockSession {
  private let lease: AnyObject
  private let store: any UpdateUnlockStore
  private let verifySource: () -> Bool
  init(
    store: any UpdateUnlockStore, acquireLock: () throws -> AnyObject,
    verifySource: @escaping () -> Bool
  ) throws {
    lease = try acquireLock()
    self.store = store
    self.verifySource = verifySource
  }
  func confirm(_ handoff: UpdateHandoff, at time: SourceTime) throws {
    try withExtendedLifetime(lease) {
      guard verifySource(),
        try store.readHandoff().map(UpdateHandoff.decode) == handoff
      else { throw RuntimeError.invalid }
      if let data = try store.readUnlock() {
        guard try UpdateUnlock.decode(data).matches(handoff) else { throw RuntimeError.invalid }
      } else {
        try store.writeUnlock(
          JSONEncoder().encode(UpdateUnlock(handoff: handoff, confirmedAt: time)))
      }
      try store.removeHandoff()
    }
  }
  /// Called before loading restore.json. Repeating it after a crash preserves the confirmation.
  func resume(_ record: UpdateUnlock) throws {
    try withExtendedLifetime(lease) {
      guard verifySource(), try store.readUnlock().map(UpdateUnlock.decode) == record else {
        throw RuntimeError.invalid
      }
      if let data = try store.readHandoff() {
        guard record.matches(try UpdateHandoff.decode(data)) else { throw RuntimeError.invalid }
      }
      try store.removeHandoff()
    }
  }
  /// Recovery failure retains the evidence; only a successful journal recovery consumes it.
  func finish(_ record: UpdateUnlock, recovered: Bool) throws -> Bool {
    try withExtendedLifetime(lease) {
      guard recovered else { return false }
      guard try store.readHandoff() == nil else { throw RuntimeError.invalid }
      if let data = try store.readUnlock() {
        guard try UpdateUnlock.decode(data) == record else { throw RuntimeError.invalid }
      }
      try store.removeUnlock()
      return true
    }
  }
}

/// What a launch is, given the handoff it finds.
public enum HandoffRole: Equatable, Sendable {
  /// No handoff: an ordinary owner.
  case none
  /// The source build after a crash or a launchd restart: it waits for the replacement.
  case waiting(UpdateHandoff)
  /// The destination build: it activates only after validation and recovery.
  case destination(UpdateHandoff)
  /// A confirmed manual unlock, pending bundle validation and recovery: by the source build, or
  /// by a newer build that the installer put in place after the unlock.
  case recovering(UpdateUnlock)
  /// An unreadable or inconsistent handoff: nothing runs.
  case invalid

  public static func classify(
    _ handoff: Result<UpdateHandoff?, any Error>,
    unlock: Result<UpdateUnlock?, any Error> = .success(nil),
    runningBuild: Int?, runningManifest: String, runningBundleVerified: () -> Bool = { false }
  ) -> Self {
    guard case .success(let value) = handoff, case .success(let confirmation) = unlock else {
      return .invalid
    }
    if let confirmation {
      if runningBuild == confirmation.sourceBuild {
        if let value {
          guard confirmation.matches(value), runningManifest == value.sourceManifest else {
            return .invalid
          }
        }
        return .recovering(confirmation)
      }
      // The installer finished after the unlock: only a newer build, with no handoff left and
      // its own bundle verified, recovers and consumes the record.
      guard value == nil, let runningBuild, runningBuild > confirmation.sourceBuild,
        runningBundleVerified()
      else { return .invalid }
      return .recovering(confirmation)
    }
    guard let value else { return .none }
    if runningBuild == value.sourceBuild, runningManifest == value.sourceManifest {
      return .waiting(value)
    }
    if runningBuild == value.destinationBuild { return .destination(value) }
    return .invalid
  }
}

extension HandoffRole {
  /// The bundle check repeated under owner.lock before a recovery resumes: the source build
  /// checks the source bundle, a newer build checks the bundle it runs from.
  public static func recoveryBundleValid(
    _ record: UpdateUnlock, runningBuild: Int?, source: () -> Bool, running: () -> Bool
  ) -> Bool {
    guard let runningBuild else { return false }
    if runningBuild == record.sourceBuild { return source() }
    return runningBuild > record.sourceBuild && running()
  }
}

/// When the owner may clear a handoff, write audio and start the updater.
public struct UpdateActivation: Equatable, Sendable {
  public var role: HandoffRole
  public var ownsLock: Bool
  public var bundleValid: Bool
  public var engineOperational: Bool
  public var recoveryPending: Bool
  public var handoffCleared: Bool
  public init(
    role: HandoffRole, ownsLock: Bool, bundleValid: Bool, engineOperational: Bool,
    recoveryPending: Bool, handoffCleared: Bool
  ) {
    self.role = role
    self.ownsLock = ownsLock
    self.bundleValid = bundleValid
    self.engineOperational = engineOperational
    self.recoveryPending = recoveryPending
    self.handoffCleared = handoffCleared
  }
  private var recovered: Bool {
    ownsLock && bundleValid && engineOperational && !recoveryPending
  }
  /// The destination build clears the handoff only after journal recovery under the lock.
  public var clearsHandoff: Bool {
    switch role {
    case .destination, .recovering: return recovered && !handoffCleared
    default: return false
    }
  }
  public var automationAllowed: Bool {
    switch role {
    case .none: return ownsLock && bundleValid
    case .destination, .recovering: return recovered && handoffCleared
    case .waiting, .invalid: return false
    }
  }
  public var updatesAllowed: Bool {
    switch role {
    case .none: return recovered
    case .destination, .recovering: return recovered && handoffCleared
    case .waiting, .invalid: return false
    }
  }
}

public enum InstallationState: Equatable, Sendable {
  case idle, preparing, safe, armed, deferred, blocked
}
public enum InstallationEvent: Equatable, Sendable {
  case proposed(UpdateTransition)
  case prepared(id: UInt64, UpdatePreparationResult)
  case deadlineReached(id: UInt64)
  case persisted(id: UInt64, success: Bool)
  /// Sparkle is about to launch the installer for this update (`willExtractUpdate`).
  case installerStarted(id: UInt64)
  case cycleFinished(id: UInt64)
  case cancelled(id: UInt64)
  case removed(id: UInt64, success: Bool)
}
public enum InstallationEffect: Equatable, Sendable {
  case prepareAudio(UpdateTransition)
  case persistHandoff(UpdateHandoff)
  case authorizeInstaller(id: UInt64)
  case refuseInstaller(id: UInt64)
  case releaseAudio(id: UInt64)
  case removeHandoff(id: UInt64)
}

/// `idle → preparing → safe → armed`; the only way to `armed` is a successful persistence after
/// `safe`. Events of another transition, repeated or out of order, authorize nothing.
public struct InstallationGate: Equatable, Sendable {
  public private(set) var state = InstallationState.idle
  public private(set) var transition: UpdateTransition?
  public private(set) var installerStarted = false
  private let sourceManifest: String
  public init(sourceManifest: String) { self.sourceManifest = sourceManifest }

  public func authorizes(id: UInt64) -> Bool { state == .armed && transition?.id == id }

  public mutating func handle(_ event: InstallationEvent) -> [InstallationEffect] {
    if case .proposed(let next) = event {
      guard state == .idle, next.valid else {
        let duplicate = next == transition && [.preparing, .safe, .armed].contains(state)
        return duplicate ? [] : [.refuseInstaller(id: next.id)]
      }
      transition = next
      state = .preparing
      return [.prepareAudio(next)]
    }
    guard let current = transition, event.id == current.id else { return [] }
    switch (state, event) {
    case (.preparing, .prepared(_, let result)):
      guard result != .unconfirmed else { return deferTransition(current) }
      state = .safe
      let handoff = UpdateHandoff(
        transition: current, sourceManifest: sourceManifest, outcome: result)
      return [.persistHandoff(handoff)]
    case (.preparing, .deadlineReached), (.preparing, .cancelled), (.preparing, .cycleFinished):
      return deferTransition(current)
    case (.safe, .persisted(_, let success)):
      guard success else {
        state = .blocked
        return [.refuseInstaller(id: current.id)]
      }
      state = .armed
      return [.authorizeInstaller(id: current.id)]
    case (.armed, .installerStarted):
      installerStarted = true
      return []
    case (.armed, .cycleFinished), (.armed, .cancelled):
      // Proof that this process never launched an installer: the handoff can go.
      guard !installerStarted else { return [] }
      state = .deferred
      return [.removeHandoff(id: current.id)]
    case (.deferred, .removed(_, let success)):
      guard success else {
        state = .blocked
        return []
      }
      return [.releaseAudio(id: current.id)]
    default:
      return []
    }
  }

  private mutating func deferTransition(_ current: UpdateTransition) -> [InstallationEffect] {
    state = .deferred
    return [.refuseInstaller(id: current.id), .releaseAudio(id: current.id)]
  }
}

extension InstallationEvent {
  fileprivate var id: UInt64 {
    switch self {
    case .proposed(let transition): return transition.id
    case .prepared(let id, _), .deadlineReached(let id), .persisted(let id, _),
      .installerStarted(let id), .cycleFinished(let id), .cancelled(let id), .removed(let id, _):
      return id
    }
  }
}

/// The audio side of the preparation; `RuntimeHost` implements it with the engine.
@MainActor public protocol UpdateAudioPort: AnyObject {
  func prepareForUpdate(
    id: UInt64, deadline: UpdatePreparationDeadline,
    result: @escaping @MainActor (UpdatePreparationResult) -> Void)
  func endUpdateHold(id: UInt64)
}

public protocol HandoffStore: AnyObject {
  func writeHandoff(_ data: Data) throws
  func removeHandoff() throws
  func readHandoff() throws -> Data?
}

extension AtomicRuntimeFiles: HandoffStore {
  public func writeHandoff(_ data: Data) throws {
    try write(data, name: UpdateHandoff.fileName)
  }
  /// Unlinks the handoff and syncs the directory; a missing file is already removed.
  public func removeHandoff() throws {
    if unlinkat(descriptor, UpdateHandoff.fileName, 0) != 0, errno != ENOENT {
      throw RuntimeError.io(errno)
    }
    guard fsync(descriptor) == 0 else { throw RuntimeError.io(errno) }
  }
  public func readHandoff() throws -> Data? { try read(UpdateHandoff.fileName) }
}

/// Drives the gate for the manual and the automatic Sparkle paths.
@MainActor public final class UpdateInstaller {
  public typealias Schedule = UpdatePreparationDeadline.Schedule
  /// Makes the one-shot warning of one preparation attempt.
  public typealias WarningFactory = @MainActor () -> @Sendable () -> Void
  /// The Quit limit: a preparation without a result by then is deferred.
  public static let preparationLimit: UInt64 = 2_000_000_000
  public private(set) var gate: InstallationGate
  /// Starts the second automatic check, after the vetoed cycle has finished.
  public var requestBackgroundCheck: (@MainActor () -> Void)?
  public var onChange: (@MainActor () -> Void)?
  private let sourceBuild: Int
  private let audio: any UpdateAudioPort
  private let store: any HandoffStore
  private let clock: @Sendable () -> UInt64
  private let schedule: Schedule
  private let makeWarning: WarningFactory
  private var preparationDeadline: UpdatePreparationDeadline?
  private var nextID: UInt64 = 0
  private var completion: (@MainActor (Bool) -> Void)?
  private enum Mode { case manual, automatic }
  private var mode: Mode?
  private var vetoedCycleFinished = false
  private var secondCheckRequested = false
  private var approvedBuild: Int?
  /// Sparkle received the go-ahead: from here only its installer or the end of its cycle can
  /// close the transition, because no public API stops a transfer it has started.
  private var released = false

  public init(
    sourceBuild: Int, sourceManifest: String, audio: any UpdateAudioPort,
    store: any HandoffStore, clock: @escaping @Sendable () -> UInt64, schedule: @escaping Schedule,
    warn makeWarning: @escaping WarningFactory = { {} }
  ) {
    self.sourceBuild = sourceBuild
    self.audio = audio
    self.store = store
    self.clock = clock
    self.schedule = schedule
    self.makeWarning = makeWarning
    gate = InstallationGate(sourceManifest: sourceManifest)
  }

  /// True while the installer may run: the handoff is on disk and audio stays held.
  public var installsNow: Bool { gate.transition.map { gate.authorizes(id: $0.id) } ?? false }

  /// Manual path: the reply to Sparkle waits for `completion`.
  public func propose(destinationBuild: Int, completion: @escaping @MainActor (Bool) -> Void) {
    if let transition = gate.transition, transition.destinationBuild == destinationBuild,
      installsNow
    {
      completion(true)
      return
    }
    guard gate.state == .idle else {
      completion(false)
      return
    }
    mode = .manual
    self.completion = completion
    begin(destinationBuild)
  }

  /// Automatic path: veto the first proposal, prepare, then approve the same item once.
  public func shouldProceed(destinationBuild: Int) -> Bool {
    if let transition = gate.transition, gate.state == .armed {
      guard transition.destinationBuild == destinationBuild, mode == .automatic,
        secondCheckRequested
      else {
        send(.cancelled(id: transition.id))
        return false
      }
      approvedBuild = destinationBuild
      released = true
      return true
    }
    guard gate.state == .idle else { return false }
    mode = .automatic
    begin(destinationBuild)
    return false
  }

  public func installerWillStart() {
    guard let transition = gate.transition else { return }
    send(.installerStarted(id: transition.id))
  }

  public func cycleFinished() {
    guard let transition = gate.transition else { return }
    if mode == .automatic, approvedBuild == nil, !vetoedCycleFinished {
      vetoedCycleFinished = true
      if gate.state == .armed { requestSecondCheck() }
      return
    }
    send(.cycleFinished(id: transition.id))
  }

  /// Switching automatic updates off stops a preparation or an unused handoff, never a
  /// transfer that Sparkle has already been allowed to start.
  public func cancel() {
    guard let transition = gate.transition, !released else { return }
    send(.cancelled(id: transition.id))
  }

  private func begin(_ destinationBuild: Int) {
    nextID += 1
    let transition = UpdateTransition(
      id: nextID, sourceBuild: sourceBuild, destinationBuild: destinationBuild)
    send(.proposed(transition))
  }

  private func requestSecondCheck() {
    guard !secondCheckRequested else { return }
    secondCheckRequested = true
    requestBackgroundCheck?()
  }

  private func send(_ event: InstallationEvent) {
    let effects = gate.handle(event)
    for effect in effects { perform(effect) }
    onChange?()
  }

  private func perform(_ effect: InstallationEffect) {
    switch effect {
    case .prepareAudio(let transition):
      let id = transition.id
      let deadline = UpdatePreparationDeadline(clock: clock, schedule: schedule)
      preparationDeadline = deadline
      deadline.arm(warn: makeWarning()) { [weak self] in
        Task { @MainActor in self?.send(.deadlineReached(id: id)) }
      }
      audio.prepareForUpdate(id: id, deadline: deadline) { [weak self] result in
        self?.send(.prepared(id: id, deadline.resolve(result)))
      }
    case .persistHandoff(let handoff):
      let success: Bool
      do {
        try store.writeHandoff(JSONEncoder().encode(handoff))
        success = true
      } catch { success = false }
      send(.persisted(id: handoff.id, success: success))
    case .authorizeInstaller:
      if mode == .automatic, vetoedCycleFinished { requestSecondCheck() }
      finish(true)
    case .refuseInstaller:
      finish(false)
    case .releaseAudio(let id):
      preparationDeadline?.cancel()
      audio.endUpdateHold(id: id)
    case .removeHandoff(let id):
      let success = (try? store.removeHandoff()) != nil
      send(.removed(id: id, success: success))
    }
  }

  private func finish(_ authorized: Bool) {
    let pending = completion
    completion = nil
    if authorized, pending != nil { released = true }
    pending?(authorized)
  }
}

/// The source build waiting for its replacement: it refuses Sparkle's Quit but not the session's.
public enum WaitingTermination {
  public enum Reply: Equatable, Sendable { case now, cancel }
  public static let sessionReasons: [UInt32] = [
    UInt32(kAELogOut), UInt32(kAEReallyLogOut), UInt32(kAEShowRestartDialog),
    UInt32(kAEShowShutdownDialog), UInt32(kAERestart), UInt32(kAEShutDown),
  ]
  public static func reply(quitReason: UInt32?) -> Reply {
    guard let quitReason, sessionReasons.contains(quitReason) else { return .cancel }
    return .now
  }
  /// The bundle on disk is the destination build: the replacement is complete.
  public static func replaced(onDisk version: String?, destination: Int) -> Bool {
    version == String(destination)
  }
}

/// Validation of the destination build against the bundle it was loaded from.
public enum LoadedBundle {
  /// The ad hoc signature of the whole bundle verifies, nested code included.
  public static func signatureValid(_ bundle: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
      return false
    }
    let flags = SecCSFlags(
      rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)
        | UInt32(kSecCSStrictValidate))
    return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
  }

  /// Every listed file is a Mach-O whose image in this process has the same UUID.
  public static func imagesMatch(_ files: [URL]) -> Bool {
    var loaded: [String: [UInt8]] = [:]
    for index in 0..<_dyld_image_count() {
      guard let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index)
      else { continue }
      let path = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path
      if let uuid = uuid(of: header) { loaded[path] = uuid }
    }
    return files.allSatisfy { file in
      let path = file.resolvingSymlinksInPath().path
      guard let image = loaded[path], let disk = diskUUID(file) else { return false }
      return image == disk
    }
  }

  private static let uuidCommand: UInt32 = 0x1b
  private static let arm64: UInt32 = 0x0100_000c
  private static func uuid(of header: UnsafePointer<mach_header>) -> [UInt8]? {
    guard header.pointee.magic == MH_MAGIC_64 else { return nil }
    var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
      let command = cursor.load(as: load_command.self)
      if command.cmd == uuidCommand {
        let value = cursor.load(as: uuid_command.self).uuid
        return withUnsafeBytes(of: value) { Array($0) }
      }
      cursor = cursor.advanced(by: Int(command.cmdsize))
    }
    return nil
  }

  /// The LC_UUID of a thin 64-bit file, or of its arm64 slice in a universal file.
  static func diskUUID(_ file: URL) -> [UInt8]? {
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
    return LoadedBundle.uuid(in: data)
  }

  static func uuid(in data: Data) -> [UInt8]? {
    let bytes = Array(data)
    func word(_ offset: Int, big: Bool = false) -> UInt32? {
      guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 4 else {
        return nil
      }
      let value = bytes[offset..<offset + 4].reversed().reduce(UInt32(0)) {
        ($0 << 8) | UInt32($1)
      }
      return big ? value.byteSwapped : value
    }

    guard let magic = word(0) else { return nil }
    var base = 0
    var limit = bytes.count
    if magic == 0xbeba_feca {
      guard let count = word(4, big: true), count > 0, count <= 16 else {
        return nil
      }
      let tableEnd = 8 + Int(count) * 20
      guard tableEnd <= bytes.count else { return nil }
      var selected: (Int, Int)?
      var ranges: [Range<Int>] = []
      for index in 0..<Int(count) {
        let entry = 8 + index * 20
        guard let cpu = word(entry, big: true),
          let offset = word(entry + 8, big: true),
          let size = word(entry + 12, big: true),
          let alignment = word(entry + 16, big: true),
          alignment <= 31
        else { return nil }
        let start = Int(offset)
        let length = Int(size)
        guard start >= tableEnd, start <= bytes.count,
          length >= 32, length <= bytes.count - start,
          start % (1 << Int(alignment)) == 0
        else { return nil }
        let range = start..<start + length
        guard !ranges.contains(where: { $0.overlaps(range) }) else { return nil }
        ranges.append(range)
        if cpu == arm64 {
          guard selected == nil else { return nil }
          selected = (start, range.upperBound)
        }
      }
      guard let selected else { return nil }
      (base, limit) = selected
    }

    guard limit - base >= 32, word(base) == MH_MAGIC_64,
      word(base + 4) == arm64,
      let count = word(base + 16), let commandBytes = word(base + 20),
      Int(commandBytes) <= limit - base - 32,
      Int(count) <= Int(commandBytes) / 8
    else { return nil }
    var cursor = base + 32
    let end = cursor + Int(commandBytes)
    var result: [UInt8]?
    for _ in 0..<count {
      guard end - cursor >= 8,
        let kind = word(cursor), let size = word(cursor + 4),
        size >= 8, size % 8 == 0, Int(size) <= end - cursor
      else { return nil }
      if kind == uuidCommand {
        guard size == 24, result == nil else { return nil }
        result = Array(bytes[cursor + 8..<cursor + 24])
      }
      cursor += Int(size)
    }
    guard cursor == end else { return nil }
    return result
  }
}
