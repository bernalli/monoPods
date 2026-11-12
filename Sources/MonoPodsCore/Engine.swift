import Foundation

/// All policy lives here. Adapters execute actions and return correlated receipts on a FIFO.
public struct Engine: Sendable {
  public let build: String
  public let run: UInt64
  public let boot: String
  private var journal: JournalRecord
  private var audio: AudioReading?
  private var loaded = false
  private var started = false
  private var blocked = false
  private var terminated = false
  private var nextID: UInt64 = 1
  private var pendingPersistence: PendingPersistence?
  private struct PendingPersistence: Equatable, Sendable {
    var request: PersistenceRequest
    var purpose: PersistencePurpose
  }
  private enum PersistencePurpose: Sendable {
    case opening, prepared, cancelled, closing, notice
  }
  private var prepared: WriterCommand?
  private var beforePrepared: AudioRecord?
  private var writer: WriterCommand?
  private var recoveryDue = false
  private var recoveryRequested = false
  private var closing: ExitReason?
  private var quitStarted: UInt64?
  private var quitAttempts = 0
  private var quitRestored = false
  private var correctionAt: UInt64?
  private var lastCorrection: UInt64?
  private var appliedTarget: Target?
  private var decisionVersion: UInt64 = 0
  private var appliedDecision: UInt64?
  private var writerDecision: UInt64 = 0
  private var writerInQuit = false
  /// The update preparation in progress: Stereo is restored with the Quit budget, then held.
  private var updateHold: UpdateHold?
  private struct UpdateHold: Equatable, Sendable {
    var id: UInt64
    var window: UpdatePreparationWindow
    var start: UInt64 { window.start }
    var attempts = 0
    var restored = false
    var reported = false
    var result: UpdatePreparationResult?
  }
  /// Attempts and window of the Quit, reused by the update preparation.
  private static let restoreWindow: UInt64 = 1_500_000_000
  private static let restoreAttempts = 3
  private var writeGeneration: UInt64 = 0
  private var confirmedGeneration: UInt64 = 0
  private var preparedCorrection = false
  private var writerCorrection = false
  private var closureSaved = false
  private var awake = true
  private var bluetooth = true
  private var automation = true
  private var sentinel = false
  private var route: Route?
  private var routeHighWater: UInt64 = 0
  private var connection: Connection?
  private var connectionHighWater: UInt64 = 0
  private var streamEpoch: UInt64 = 0
  private var streamStart: SourceTime?
  private var nonce = ""
  private var streamHealthy = false
  private var streamFailed = false
  private var heartbeatDeadline: UInt64?
  private var heartbeatDue: UInt64?
  private var heartbeatSequence: UInt64 = 0
  private var lastHeartbeat: UInt64 = 0
  private var emitted: [UInt64: UInt64] = [:]
  private var backoff: UInt64 = 1
  private var count: Int?
  private var detection: Detection = .unknown
  private var lastKnownTarget: Target?
  private var lastStateTime: SourceTime?
  private var lastMTime: SourceTime?
  private var lastMStatus: EarStatus?
  private var faultTime: SourceTime?
  private var faultTimeUnknown = false
  private var unreadableAt: SourceTime?
  private var historyQuery: UInt64?
  private var detectionNoticeConnection: UInt64?
  private var retries: [Target: Int] = [:]
  private var retryAt: UInt64?
  private var retryTarget: Target?
  private var blockedTargets: Set<Target> = []
  private var episodes: [Episode] = []
  private var transitions: [Transition] = []
  private var consumed: Set<TransitionIdentity> = []
  private var playInFlight: Set<UInt64> = []
  /// Pairing window of a removal: a Pause pairs with a transition within it, a count of one pairs
  /// with a transition within it, and a Pause episode can send its Play only within it.
  private static let removalWindow: Int64 = 3_000_000_000
  /// How far the first signal of a removal that can still send a Play can trail the newest
  /// applied player row. The Play is sent less than one window after the Pause arrives, so every
  /// row applied until then is less than one window newer than the Pause, which is stamped when
  /// it is received. The transition is less than one window from the Pause and the count less
  /// than one window from the transition: three windows in all. A removal that trails the newest
  /// row by more finds the rows before it dropped, and its player state is unknown.
  private static let playerHistoryWindow = 3 * removalWindow
  /// Applied player rows past the barrier, in source-time order, the first row for a source time
  /// only. Bounded in time, not in number: every row within `playerHistoryWindow` of the newest
  /// one, and the newest row before that window, which stays as the background state.
  private var playerHistory: [PlaybackState] = []
  /// The oldest retained row once older rows were dropped. The history gives the exact state
  /// before a time only for times after it.
  private var playerHistoryFloor: SourceTime?
  private var playbackBarrier: SourceTime?
  private var countRemovals: [Removal] = []
  /// A Not Playing row this close after a removal belongs to that removal: macOS stopped the
  /// player, not the user. Measured delays of that row: 32, 45 and 135 ms.
  private static let removalStopWindow: Int64 = 1_000_000_000
  /// How long after an earbud comes in Playing rows can be resumes of macOS (measured at
  /// 193 ms). A manual Play inside this guard is also put back in Pause.
  static let pauseGuardWindow: Int64 = 1_500_000_000
  /// Chosen, not measured. Each sent Pause expects one echo for 500 ms. A real system Pause
  /// within that interval can be mistaken for the echo; that ambiguity is accepted.
  private static let pauseEchoWindow: UInt64 = 500_000_000
  /// Source times of removals that can still claim a retained or delayed player row.
  private var removalTimes: [SourceTime] = []
  private var pauseGuard: PauseGuard?
  private struct PauseGuard: Equatable, Sendable {
    var transition: SourceTime
    var lastEntry: SourceTime
    var end: UInt64
  }
  /// Entries wait for the same controls as Play, without moving their original deadline.
  private var pendingEntries: [PendingEntry] = []
  private struct PendingEntry: Equatable, Sendable {
    var time: SourceTime
    var end: UInt64
    /// Only the deduction needs capture: newer rows must not erase what preceded the entry.
    var inferredStop: Bool
  }
  /// One expiry per sent Pause. These survive resets: a command already sent can still echo.
  private var pauseEchoes: [UInt64] = []
  /// A removal had its Pause and no row came until the end of its episode: the player was already
  /// stopped. It holds until a new row or a reset.
  private var stoppedAcrossRemoval = false
  private struct Removal: Equatable, Sendable {
    var first: SourceTime
    var playback: PlaybackState?
    /// False when the history had dropped rows before `first`: the player state is unknown.
    var complete: Bool
    /// A Not Playing row at or after `transitionTime` was applied. A count alone cannot prove a
    /// stop. This decides the Play only when the player state is unknown.
    var stopObserved = false
    var countTime: SourceTime?
    var transitionTime: SourceTime?

    var stateUnknown: Bool { !complete || playback == nil }

    /// Rows can prove a stop only from the transition onward. Independently, the newest row
    /// before the first signal refines the captured player state, as long as it is complete.
    mutating func refine(with state: PlaybackState) {
      if let transitionTime, state.stopEligible, !state.playing, state.time >= transitionTime {
        stopObserved = true
      }
      guard complete, state.time < first, playback.map({ state.time > $0.time }) ?? true else {
        return
      }
      playback = state
    }
    /// An earlier signal moves `first`. Its own capture read the history at its own time, so its
    /// evidence and completeness hold for the new `first`. Annulled evidence is checked against
    /// the transition; moving `first` back cannot turn an earlier manual pause into a stop.
    mutating func include(_ other: Removal) {
      countTime = countTime ?? other.countTime
      transitionTime = transitionTime ?? other.transitionTime
      if other.first < first {
        first = other.first
        complete = other.complete
        if let state = playback, state.time >= first {
          playback = nil
          refine(with: state)
        }
        if !complete { playback = nil }
      } else if other.first == first {
        complete = complete || other.complete
      }
      stopObserved = stopObserved || other.stopObserved
      if let state = other.playback { refine(with: state) }
    }
  }
  private struct PlaybackState: Equatable, Sendable {
    var time: SourceTime
    var playing: Bool
    /// Below the retained history, a row cannot prove that it is the first at its source time.
    var stopEligible = true
  }
  private struct Episode: Equatable, Sendable {
    var id: UInt64
    var time: SourceTime
    var start: UInt64
    var end: UInt64
    var due: UInt64?
    var removal: Removal?

    /// Paired, with an unknown player state and no stop: nothing is due until a row settles it,
    /// and only `end` remains as a deadline.
    var awaitsStop: Bool {
      guard due != nil, let removal else { return false }
      return removal.stateUnknown && !removal.stopObserved
    }
  }
  private struct TransitionIdentity: Hashable, Sendable {
    var connection: UInt64
    var device: UInt64
    var time: SourceTime
    var from: EarStatus
    var to: EarStatus
  }
  private struct Transition: Equatable, Sendable {
    var id: UInt64
    var identity: TransitionIdentity
    var arrival: UInt64
    var removal: Removal
  }
  private var ownerDeadline: UInt64?
  /// The crash notice request currently in flight with the presenter.
  private var noticeShown = false
  /// The presenter confirmed the crash notice; the journal clear waits for a free persistence slot.
  private var noticeConfirmed = false
  private var noticeRetryAt: UInt64?

  public init(build: String, run: UInt64, boot: String) {
    self.build = build
    self.run = run
    self.boot = boot
    journal = JournalRecord(run: run, build: build)
    blocked = run == 0 || build.isEmpty || boot.isEmpty
  }
  private var context: ObservationContext? {
    guard let route, let connection, streamEpoch > 0 else { return nil }
    return ObservationContext(
      routeEpoch: route.epoch, streamEpoch: streamEpoch,
      connectionEpoch: connection.epoch, deviceOrdinal: route.deviceOrdinal)
  }
  private var operational: Bool {
    started && !blocked && !terminated && closing == nil
  }
  private var base: Bool {
    operational && closing == nil && updateHold == nil && automation && awake && bluetooth
      && route != nil
      && connection != nil
      && streamHealthy && count != nil && detection != .off
  }
  private var desired: Target? {
    guard started, !blocked, !terminated else { return nil }
    guard audio != nil, audio?.systemMono != .on else { return nil }
    if closing != nil { return quitRestored ? nil : .stereo }
    if let updateHold {
      guard !updateHold.restored, updateHold.result == nil, journal.audio.restoreRequired else {
        return nil
      }
      return .stereo
    }
    if recoveryDue || recoveryRequested { return journal.audio.restoreRequired ? .stereo : nil }
    guard base else { return nil }
    return count == 1 ? .mono : .stereo
  }
  public var snapshot: EngineSnapshot {
    EngineSnapshot(
      audio: audio, count: count, detection: detection, desiredTarget: desired,
      lastCompleted: journal.audio.lastCompleted,
      blocked: blocked, healthy: streamHealthy, operational: operational, terminated: terminated,
      restoreConfirmed: !blocked && (audio?.systemMono == .on || quitRestored),
      recoveryPending: recoveryDue || recoveryRequested)
  }
  public var nextDeadline: UInt64? {
    guard !terminated else { return nil }
    let deadlines =
      [
        heartbeatDeadline, heartbeatDue, retryAt, correctionAt, ownerDeadline, noticeRetryAt,
        pauseGuard?.end, updateHold.flatMap { $0.reported ? nil : $0.window.end },
      ]
      + pendingEntries.map { Optional($0.end) } + pauseEchoes.map { Optional($0) }
      + episodes.flatMap { [$0.end, $0.awaitsStop ? nil : $0.due] }
    return deadlines.compactMap { $0 }.min()
  }
  private mutating func identifier() -> UInt64? {
    guard nextID > 0, nextID < UInt64.max else {
      blocked = true
      return nil
    }
    defer { nextID += 1 }
    return nextID
  }
  private mutating func deadline(_ start: UInt64, _ delay: UInt64) -> UInt64? {
    let (result, overflow) = start.addingReportingOverflow(delay)
    if overflow {
      blocked = true
      return nil
    }
    return result
  }
  private mutating func persist(
    _ record: JournalRecord, purpose: PersistencePurpose, actions: inout [EngineAction]
  ) {
    guard pendingPersistence == nil, writer == nil, let id = identifier() else { return }
    var record = record
    record.audio.nextId = nextID
    let request = PersistenceRequest(id: id, record: record)
    pendingPersistence = PendingPersistence(request: request, purpose: purpose)
    actions.append(.persist(request))
  }
  private mutating func invalidate() {
    count = nil
    countRemovals.removeAll()
    episodes.removeAll()
    transitions.removeAll()
    pauseGuard = nil
    pendingEntries.removeAll()
    stoppedAcrossRemoval = false
  }
  private mutating func resetRetries() {
    // Quit retries keep their absolute boundaries; beginClose clears the old budget first.
    guard closing == nil, updateHold == nil else { return }
    retries.removeAll()
    blockedTargets.removeAll()
    retryAt = nil
    retryTarget = nil
  }
  private mutating func failStream(at now: Instant, actions: inout [EngineAction]) {
    guard streamEpoch > 0, !streamFailed else { return }
    streamFailed = true
    streamHealthy = false
    heartbeatDeadline = nil
    heartbeatDue = nil
    emitted.removeAll()
    invalidate()
    resetPlayback(at: now.utc)
    actions.append(.restartStream(epoch: streamEpoch, afterNanos: backoff * 1_000_000_000))
    backoff = min(backoff * 2, 30)
  }
  private mutating func expire(at now: Instant, actions: inout [EngineAction]) {
    let time = now.continuousNanos
    if let end = heartbeatDeadline, time >= end { failStream(at: now, actions: &actions) }
    if let due = heartbeatDue, time >= due, !streamFailed {
      emitHeartbeat(at: now, actions: &actions)
    }
    if playerHistory.isEmpty, episodes.contains(where: { time >= $0.end && $0.awaitsStop }) {
      stoppedAcrossRemoval = true
    }
    episodes.removeAll { time >= $0.end }
    if let end = pauseGuard?.end, time >= end { pauseGuard = nil }
    pendingEntries.removeAll { time >= $0.end }
    pauseEchoes.removeAll { time >= $0 }
    if let end = ownerDeadline, time >= end {
      // Neither the lock nor a live owner: a writer that survived a crash may still hold it.
      ownerDeadline = nil
      terminated = true
      actions.append(.terminate(75))
    }
    if let due = retryAt, time >= due { retryAt = nil }
    if let due = noticeRetryAt, time >= due {
      noticeRetryAt = nil
      if journal.lifecycle.noticePending, !noticeShown, !noticeConfirmed {
        noticeShown = true
        actions.append(.showNotice(.previousCrash))
      }
    }
  }
  private mutating func emitHeartbeat(at now: Instant, actions: inout [EngineAction]) {
    guard heartbeatSequence < UInt64.max else {
      blocked = true
      return
    }
    heartbeatSequence += 1
    emitted[heartbeatSequence] = now.continuousNanos
    // Entries outside the latency window cannot become valid again.
    emitted = emitted.filter {
      now.continuousNanos >= $0.value && now.continuousNanos - $0.value < 25_000_000_000
    }
    actions.append(.emitHeartbeat(epoch: streamEpoch, nonce: nonce, sequence: heartbeatSequence))
    heartbeatDue = deadline(now.continuousNanos, 10_000_000_000)
  }
  public mutating func handle(input: EngineInput, at now: Instant) -> [EngineAction] {
    guard !terminated else { return [] }
    // Foreign callbacks are inert even when their timestamps would expire other deadlines.
    switch input {
    case .writerCompleted(let receipt):
      guard receipt.command == writer, receipt.command.run == run else { return [] }
    case .audioWriteSkipped(let command):
      guard command == writer, command.run == run else { return [] }
    case .audioObserved(let reading):
      guard reading.valid, reading.generation > (audio?.generation ?? 0) else { return [] }
      if !loaded {
        audio = reading
        return []
      }
    default: break
    }
    if let quitStarted, now.continuousNanos >= quitStarted,
      now.continuousNanos - quitStarted >= 2_000_000_000
    {
      return []
    }
    var actions: [EngineAction] = []
    expire(at: now, actions: &actions)
    guard !terminated else { return actions }
    if !loaded, case .ownerWaiting = input {
      if ownerDeadline == nil {
        ownerDeadline = deadline(now.continuousNanos, 60_000_000_000)
        actions.append(.acquireOwner)
      }
      return actions
    }
    if !loaded, case .ownerAcquired(let callbackRun) = input {
      if callbackRun == run { ownerDeadline = nil }
      return actions
    }
    if !loaded, case .ownerConfirmed = input {
      // Another process owns the lock and is alive: this instance ends without writing.
      terminated = true
      actions.append(.terminate(0))
      return actions
    }
    if case .journalLoaded(let load) = input {
      guard !loaded else { return actions }
      loaded = true
      ownerDeadline = nil
      switch load {
      case .blocked: blocked = true
      case .missing: break
      case .record(let previous):
        guard previous.contractValid else {
          blocked = true
          actions.append(.showNotice(.recoveryBlocked))
          return actions
        }
        journal = previous
        nextID = previous.audio.nextId
        if !previous.lifecycle.closedCleanly { journal.lifecycle.noticePending = true }
        if previous.audio.restoreRequired {
          journal.audio.active = nil
          journal.audio.phase = .uncertain
          recoveryDue = true
          resetRetries()
        }
      }
      if blocked {
        if journal.lifecycle.noticePending {
          actions.append(.showNotice(.previousCrash))
          noticeShown = true
        }
        actions.append(.showNotice(.recoveryBlocked))
        return actions
      }
      journal.lifecycle.run = run
      journal.lifecycle.build = build
      journal.lifecycle.closedCleanly = false
      journal.lifecycle.exitReason = nil
      persist(journal, purpose: .opening, actions: &actions)
      return actions
    }
    if case .prepareUpdate(let id) = input {
      beginUpdateHold(id, now: now, actions: &actions)
      return actions
    }
    guard loaded else { return actions }
    switch input {
    case .persistenceAcknowledged(let callbackRun, let id, let success):
      guard callbackRun == run, let pending = pendingPersistence, pending.request.id == id else {
        return actions
      }
      let request = pending.request
      let purpose = pending.purpose
      pendingPersistence = nil
      guard success else {
        blocked = true
        prepared = nil
        actions.append(.showNotice(.persistenceFailed))
        return actions
      }
      journal = request.record
      switch purpose {
      case .opening:
        started = true
        if journal.lifecycle.noticePending {
          actions.append(.showNotice(.previousCrash))
          noticeShown = true
        }
      case .prepared: break
      case .cancelled:
        beforePrepared = nil
        if !journal.audio.restoreRequired {
          recoveryDue = false
          recoveryRequested = false
        }
      case .notice: noticeConfirmed = false
      case .closing:
        closureSaved = true
        terminated = true
        actions.append(.terminate(0))
      }
    case .route(let value):
      if value == route { break }
      if let value {
        guard value.epoch > routeHighWater, value.deviceOrdinal > 0 else { break }
        routeHighWater = value.epoch
      }
      route = value
      connection = nil
      detection = .unknown
      lastStateTime = nil
      lastMTime = nil
      lastMStatus = nil
      unreadableAt = nil
      invalidate()
      resetPlayback(at: now.utc)
      if !recoveryDue && !recoveryRequested { resetRetries() }
      requestRecovery()
    case .connection(let value):
      guard route != nil, value.epoch > connectionHighWater,
        value.boundary.map({ $0 <= now.utc }) ?? true
      else { break }
      connectionHighWater = value.epoch
      connection = value
      lastStateTime = nil
      lastMTime = nil
      lastMStatus = nil
      detection = .unknown
      invalidate()
      if !recoveryDue && !recoveryRequested { resetRetries() }
      faultTime = nil
      faultTimeUnknown = false
      unreadableAt = nil
      query(actions: &actions)
    case .streamStarted(let epoch, let newNonce):
      guard epoch > streamEpoch, epoch > 0, !newNonce.isEmpty else { break }
      streamEpoch = epoch
      nonce = newNonce
      streamStart = now.utc
      streamHealthy = false
      streamFailed = false
      lastStateTime = nil
      lastMTime = nil
      unreadableAt = nil
      heartbeatSequence = 0
      lastHeartbeat = 0
      emitted.removeAll()
      invalidate()
      resetPlayback(at: now.utc)
      heartbeatDeadline = deadline(now.continuousNanos, 25_000_000_000)
      emitHeartbeat(at: now, actions: &actions)
      query(actions: &actions)
    case .heartbeat(let epoch, let receivedNonce, let sequence):
      guard epoch == streamEpoch, receivedNonce == nonce, !streamFailed, sequence > lastHeartbeat,
        let sent = emitted[sequence], now.continuousNanos >= sent,
        now.continuousNanos - sent < 25_000_000_000
      else { break }
      lastHeartbeat = sequence
      emitted = emitted.filter { $0.key > sequence }
      streamHealthy = true
      backoff = 1
      heartbeatDeadline = deadline(now.continuousNanos, 25_000_000_000)
    case .observation(let observation):
      if observation.provenance == .live { observe(observation, now: now, actions: &actions) }
    case .history(let id, let candidate, let observation, let complete):
      guard id == historyQuery, candidate == context else { break }
      historyQuery = nil
      guard complete, !faultTimeUnknown, let observation, observation.provenance == .history,
        let boundary = connection?.boundary, observation.sourceTime > boundary,
        faultTime.map({ observation.sourceTime > $0 }) ?? true
      else { break }
      observe(observation, now: now, actions: &actions)
    case .gap(let epoch, let reason, let time):
      guard epoch == streamEpoch else { break }
      invalidate()
      resetPlayback(at: now.utc)
      if reason == .clockChanged {
        faultTime = time
        faultTimeUnknown = time == nil
        lastStateTime = nil
      }
      if reason == .sourceUnreadable {
        if let time {
          if faultTime.map({ time > $0 }) ?? true { faultTime = time }
          if unreadableAt.map({ time > $0 }) ?? true { unreadableAt = time }
        } else {
          faultTimeUnknown = true
        }
        query(actions: &actions)
      } else {
        failStream(at: now, actions: &actions)
      }
    case .streamFinished(let epoch):
      if epoch == streamEpoch { failStream(at: now, actions: &actions) }
    case .nowPlaying(let epoch, let playing, let sourceTime):
      guard epoch == streamEpoch, !streamFailed, sourceTime <= now.utc,
        streamStart.map({ sourceTime >= $0 }) ?? false,
        playbackBarrier.map({ sourceTime > $0 }) ?? true
      else { break }
      let state = PlaybackState(
        time: sourceTime, playing: playing,
        stopEligible: playerHistoryFloor.map({ sourceTime > $0 }) ?? true)
      // Only the first row for a source time is applied, whether a removal reads it from the
      // history at its capture or receives it here.
      if playerHistory.contains(where: { $0.time == sourceTime }) { break }
      // Pending removals keep their own evidence: later rows cannot evict it from the history.
      for index in countRemovals.indices { countRemovals[index].refine(with: state) }
      for index in transitions.indices { transitions[index].removal.refine(with: state) }
      for index in episodes.indices { episodes[index].removal?.refine(with: state) }
      record(state)
      pruneRemovalTimes()
      stoppedAcrossRemoval = false
      answerResume(state, now: now, actions: &actions)
    case .environment(let isAwake, let available):
      awake = isAwake
      bluetooth = available
      if !awake || !bluetooth { invalidate() }
      if !bluetooth { requestRecovery() }
    case .automation(let enabled):
      automation = enabled
      if !enabled {
        invalidate()
        requestRecovery()
      }
    case .sentinelAvailable(let available):
      sentinel = available
      if !available {
        episodes.removeAll()
        transitions.removeAll()
      }
    case .pause(let sourceTime):
      guard sourceTime <= now.utc else { break }
      if !pauseEchoes.isEmpty {
        pauseEchoes.removeFirst()
        break
      }
      guard operational, closing == nil, sentinel,
        let id = identifier(), let end = deadline(now.continuousNanos, UInt64(Self.removalWindow))
      else { break }
      episodes.append(Episode(id: id, time: sourceTime, start: now.continuousNanos, end: end))
    case .playCompleted(let callbackRun, let id, let accepted):
      guard callbackRun == run, playInFlight.remove(id) != nil else { break }
      if !accepted {
        sentinel = false
        episodes.removeAll()
        transitions.removeAll()
      }
    case .audioObserved(let reading):
      let wasOn = audio?.systemMono == .on
      audio = reading
      if wasOn || reading.systemMono == .on { requestRecovery() }
    case .audioWriteSkipped:
      writer = nil
      writerCorrection = false
      cancelPrepared(actions: &actions)
    case .writerCompleted(let receipt): completeWriter(receipt, now: now, actions: &actions)
    case .noticePresented(let notice, let success):
      guard notice == .previousCrash, noticeShown else { break }
      noticeShown = false
      if success {
        noticeConfirmed = true
      } else {
        // One request at a time: a failed presentation is offered again after 60 s continuous.
        noticeRetryAt = deadline(now.continuousNanos, 60_000_000_000)
      }
    case .quit(let reason): beginClose(reason, now: now, actions: &actions)
    case .endUpdateHold(let id):
      if updateHold?.id == id, closing == nil { updateHold = nil }
    case .reopen: actions.append(.restoreIcon)
    case .drain, .tick, .journalLoaded, .ownerWaiting, .ownerAcquired, .ownerConfirmed,
      .sentinelPlay, .sentinelToggle, .prepareUpdate:
      break
    }
    guard !terminated else { return actions }
    applyPendingEntries(now: now, actions: &actions)
    persistConfirmedNotice(actions: &actions)
    reconcileAudio(now: now)
    if case .drain = input {
      matchEpisodes()
      dispatchPlay(now: now, actions: &actions)
      dispatchWriter(now: now, actions: &actions)
    } else if case .tick = input {
      dispatchPlay(now: now, actions: &actions)
    }
    finishClose(now: now, actions: &actions)
    finishUpdateHold(now: now, actions: &actions)
    return actions
  }
  private mutating func query(actions: inout [EngineAction]) {
    guard let context, let id = identifier() else { return }
    historyQuery = id
    actions.append(.queryHistory(id: id, context: context))
  }
  private mutating func observe(
    _ observation: Observation, now: Instant, actions: inout [EngineAction]
  ) {
    guard context == observation.context, observation.context.valid,
      observation.sourceTime <= now.utc,
      observation.receivedContinuousNanos <= now.continuousNanos, !streamFailed
    else { return }
    if let boundary = connection?.boundary, observation.sourceTime <= boundary { return }
    if observation.provenance == .live {
      guard let streamStart, observation.sourceTime >= streamStart else { return }
    }
    switch observation.value {
    case .count(let value, let earDetection):
      guard observation.source != .m, value.map({ (0...2).contains($0) }) ?? true,
        lastStateTime.map({ observation.sourceTime > $0 }) ?? true,
        unreadableAt.map({ observation.sourceTime > $0 }) ?? true
      else { return }
      if observation.provenance == .history && faultTimeUnknown { return }
      let previousTarget = lastKnownTarget
      lastStateTime = observation.sourceTime
      detection = earDetection
      if earDetection == .off {
        invalidate()
        requestRecovery()
        if detectionNoticeConnection != connection?.epoch {
          detectionNoticeConnection = connection?.epoch
          actions.append(.showNotice(.detectionDisabled))
        }
      } else {
        if count == 2 && value == 1 { recordCountRemoval(at: observation.sourceTime) }
        count = value
        if value == nil || value == 0 {
          episodes.removeAll()
          transitions.removeAll()
          countRemovals.removeAll()
        }
        if value == nil { invalidate() }
        if let value {
          let target: Target = value == 1 ? .mono : .stereo
          if previousTarget != target {
            guard decisionVersion < UInt64.max else {
              blocked = true
              return
            }
            decisionVersion += 1
            if !recoveryDue && !recoveryRequested { resetRetries() }
          }
          lastKnownTarget = target
        }
        if observation.provenance == .live {
          faultTimeUnknown = false
          faultTime = nil
          unreadableAt = nil
        }
      }
    case .transition(let from, let to):
      guard observation.source == .m, observation.provenance == .live,
        lastMTime.map({ observation.sourceTime > $0 }) ?? true
      else { return }
      lastMTime = observation.sourceTime
      // Later transitions must have a greater source time. Only then is older count evidence
      // provably outside their matching window, regardless of transport delay.
      countRemovals.removeAll {
        observation.sourceTime.nanos - $0.first.nanos >= Self.removalWindow
      }
      guard lastMStatus != to else { return }
      lastMStatus = to
      if (from == .both && (to == .one || to == .none)) || (from == .one && to == .none) {
        removalTimes.append(observation.sourceTime)
        pruneRemovalTimes()
      }
      if (from == .one && to == .both) || (from == .none && (to == .one || to == .both)) {
        undoSystemResume(after: observation.sourceTime, now: now, actions: &actions)
        return
      }
      if to == .none || to == .unknown {
        episodes.removeAll()
        transitions.removeAll()
        countRemovals.removeAll()
        return
      }
      guard from == .both, to == .one, let connection else { return }
      let identity = TransitionIdentity(
        connection: connection.epoch, device: observation.context.deviceOrdinal,
        time: observation.sourceTime, from: from, to: to)
      guard !consumed.contains(identity), !transitions.contains(where: { $0.identity == identity }),
        let id = identifier()
      else { return }
      var removal = captureRemoval(at: observation.sourceTime, isTransition: true)
      if let index = countRemovals.indices.filter({
        abs(countRemovals[$0].first.nanos - observation.sourceTime.nanos) < Self.removalWindow
      }).min(by: {
        let lhs = countRemovals[$0].first.nanos - observation.sourceTime.nanos
        let rhs = countRemovals[$1].first.nanos - observation.sourceTime.nanos
        return (abs(lhs), $0) < (abs(rhs), $1)
      }) {
        removal.include(countRemovals.remove(at: index))
      }
      transitions.append(
        Transition(id: id, identity: identity, arrival: now.continuousNanos, removal: removal))
    }
  }
  private mutating func matchEpisodes() {
    // Pick the globally closest remaining pair, with deterministic IDs for ties.
    while true {
      var pairs: [(Int64, UInt64, UInt64, Int, Int)] = []
      for (i, episode) in episodes.enumerated() where episode.due == nil {
        for (j, transition) in transitions.enumerated() {
          let delta = transition.identity.time.nanos - episode.time.nanos
          if delta >= -Self.removalWindow && delta < Self.removalWindow {
            pairs.append((abs(delta), episode.id, transition.id, i, j))
          }
        }
      }
      guard let pair = pairs.min(by: { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }) else { break }
      let transition = transitions.remove(at: pair.4)
      consumed.insert(transition.identity)
      if let earliest = deadline(episodes[pair.3].start, 100_000_000) {
        episodes[pair.3].due = max(earliest, transition.arrival)
        episodes[pair.3].removal = transition.removal
      }
    }
  }
  private mutating func dispatchPlay(now: Instant, actions: inout [EngineAction]) {
    let ready = episodes.filter {
      !$0.awaitsStop && ($0.due.map({ now.continuousNanos >= $0 }) ?? false)
    }
    guard !ready.isEmpty else { return }
    // A due episode is consumed even without a base, so nextDeadline never repeats it. An episode
    // that awaits a stop is not due and stays until its end.
    let ids = Set(ready.map(\.id))
    episodes.removeAll { ids.contains($0.id) }
    guard let context = mediaContext else { return }
    for episode in ready where now.continuousNanos < episode.end && !pausedByUser(episode) {
      guard let id = identifier() else { break }
      playInFlight.insert(id)
      actions.append(.play(PlayCommand(run: run, id: id, episode: episode.id, context: context)))
    }
  }
  /// The context of a media command, when one can be sent at all.
  private var mediaContext: ObservationContext? {
    guard base, sentinel, count == 1 || count == 2 else { return nil }
    return context
  }
  /// Keep the entry even if its count or other controls have not arrived yet. Source time,
  /// rather than transport delay or a later control update, fixes the end of its protection.
  private mutating func undoSystemResume(
    after time: SourceTime, now: Instant, actions: inout [EngineAction]
  ) {
    let age = now.utc.nanos - time.nanos
    guard age >= 0, age < Self.pauseGuardWindow,
      let end = deadline(now.continuousNanos, UInt64(Self.pauseGuardWindow - age))
    else { return }
    pendingEntries.append(PendingEntry(time: time, end: end, inferredStop: stoppedAcrossRemoval))
    applyPendingEntries(now: now, actions: &actions)
  }
  private mutating func applyPendingEntries(now: Instant, actions: inout [EngineAction]) {
    guard let context = mediaContext else { return }
    let entries = pendingEntries
    pendingEntries.removeAll()
    for entry in entries where now.continuousNanos < entry.end {
      guard stoppedByUser(before: entry.time, inferredStop: entry.inferredStop) else { continue }
      // Settled removals cannot claim the stop that answers this Pause, or release a waiting Play.
      removalTimes.removeAll()
      episodes.removeAll()
      transitions.removeAll()
      countRemovals.removeAll()
      if var current = pauseGuard {
        current.transition = min(current.transition, entry.time)
        current.lastEntry = max(current.lastEntry, entry.time)
        current.end = max(current.end, entry.end)
        pauseGuard = current
      } else {
        pauseGuard = PauseGuard(transition: entry.time, lastEntry: entry.time, end: entry.end)
      }
      sendPause(context: context, now: now, actions: &actions)
    }
  }
  private mutating func sendPause(
    context: ObservationContext, now: Instant, actions: inout [EngineAction]
  ) {
    guard let end = deadline(now.continuousNanos, Self.pauseEchoWindow) else { return }
    pauseEchoes.append(end)
    actions.append(.pause(context: context))
  }
  private mutating func answerResume(
    _ state: PlaybackState, now: Instant, actions: inout [EngineAction]
  ) {
    guard let guardWindow = pauseGuard, Self.isResume(state, inside: guardWindow),
      let context = mediaContext
    else { return }
    sendPause(context: context, now: now, actions: &actions)
  }
  private static func isResume(_ state: PlaybackState, inside guardWindow: PauseGuard) -> Bool {
    state.playing && state.time >= guardWindow.transition
      && state.time.nanos - guardWindow.lastEntry.nanos < pauseGuardWindow
  }
  /// Read only rows before the entry, including rows delivered while its controls were pending.
  /// A Playing row already inside an open guard is a resume being corrected, until expiry.
  private func stoppedByUser(before time: SourceTime, inferredStop: Bool) -> Bool {
    guard let last = playerHistory.last(where: { $0.time < time }) else { return inferredStop }
    if last.playing {
      return pauseGuard.map { Self.isResume(last, inside: $0) } ?? false
    }
    return !removalTimes.contains { Self.claims($0, last.time) }
  }
  private static func claims(_ removal: SourceTime, _ row: SourceTime) -> Bool {
    removal <= row && row.nanos - removal.nanos < removalStopWindow
  }
  private mutating func pruneRemovalTimes() {
    guard let newest = playerHistory.last?.time else {
      return
    }
    removalTimes.removeAll { removal in
      newest.nanos - removal.nanos >= Self.playerHistoryWindow
        && !playerHistory.contains { Self.claims(removal, $0.time) }
    }
  }
  private func pausedByUser(_ episode: Episode) -> Bool {
    guard let removal = episode.removal, removal.complete else { return false }
    return removal.playback?.playing == false
  }
  private mutating func resetPlayback(at time: SourceTime) {
    pauseGuard = nil
    pendingEntries.removeAll()
    stoppedAcrossRemoval = false
    playerHistory.removeAll()
    playerHistoryFloor = nil
    playbackBarrier = time
  }
  /// Inserts an applied row in source-time order and drops the rows that no removal that can
  /// still send a Play can need.
  private mutating func record(_ state: PlaybackState) {
    // Below the floor a row can be the state only before a time the history no longer covers.
    if let floor = playerHistoryFloor, state.time <= floor { return }
    let index = playerHistory.firstIndex { $0.time >= state.time } ?? playerHistory.endIndex
    if index < playerHistory.endIndex, playerHistory[index].time == state.time { return }
    playerHistory.insert(state, at: index)
    guard let newest = playerHistory.last else { return }
    let cutoff = newest.time.nanos - Self.playerHistoryWindow
    let older = playerHistory.prefix { $0.time.nanos < cutoff }.count
    // Of the rows before the window only the newest can still be the state before a signal.
    if older > 1 {
      playerHistory.removeFirst(older - 1)
      playerHistoryFloor = playerHistory.first?.time
    }
  }
  /// The newest applied row strictly before this signal, and any stop from this transition
  /// onward. A count captures player evidence only; it cannot establish a stop by itself.
  private func captureRemoval(at time: SourceTime, isTransition: Bool = false) -> Removal {
    let transitionTime = isTransition ? time : nil
    let stopped = isTransition && playerHistory.contains { !$0.playing && $0.time >= time }
    if let floor = playerHistoryFloor, time <= floor {
      return Removal(
        first: time, playback: nil, complete: false, stopObserved: stopped,
        transitionTime: transitionTime)
    }
    return Removal(
      first: time, playback: playerHistory.last { $0.time < time }, complete: true,
      stopObserved: stopped, transitionTime: transitionTime)
  }
  /// Count and transition signals are paired once. Their first source time and player evidence
  /// then belong to that removal, including after a count of two returns during the Play delay.
  private mutating func recordCountRemoval(at time: SourceTime) {
    var removal = captureRemoval(at: time)
    removal.countTime = time
    var candidates: [(distance: Int64, id: UInt64, transition: Int?, episode: Int?)] = []
    for (index, transition) in transitions.enumerated() where transition.removal.countTime == nil {
      let distance = abs(transition.identity.time.nanos - time.nanos)
      if distance < Self.removalWindow {
        candidates.append((distance, transition.id, index, nil))
      }
    }
    for (index, episode) in episodes.enumerated() {
      guard let snapshot = episode.removal, snapshot.countTime == nil,
        let transition = snapshot.transitionTime
      else { continue }
      let distance = abs(transition.nanos - time.nanos)
      if distance < Self.removalWindow { candidates.append((distance, episode.id, nil, index)) }
    }
    if let closest = candidates.min(by: { ($0.distance, $0.id) < ($1.distance, $1.id) }) {
      if let index = closest.transition { transitions[index].removal.include(removal) }
      if let index = closest.episode { episodes[index].removal?.include(removal) }
    } else {
      if lastMTime.map({ $0.nanos - time.nanos < Self.removalWindow }) ?? true {
        countRemovals.append(removal)
      }
    }
  }
  /// Entering recovery grants one finite budget, regardless of repeated off/route events.
  private mutating func requestRecovery() {
    guard journal.audio.restoreRequired, !recoveryDue, !recoveryRequested else { return }
    recoveryRequested = true
    resetRetries()
  }
  private mutating func cancelPrepared(actions: inout [EngineAction]) {
    prepared = nil
    preparedCorrection = false
    var record = journal
    if let previous = beforePrepared { record.audio = previous }
    persist(record, purpose: .cancelled, actions: &actions)
  }
  private mutating func reconcileAudio(now: Instant) {
    guard closing == nil, updateHold == nil, !recoveryDue, !recoveryRequested, let target = desired,
      appliedTarget == target, appliedDecision == decisionVersion, let audio, audio.status == 0,
      audio.mode != target,
      audio.generation > confirmedGeneration || writerCorrection
    else {
      correctionAt = nil
      return
    }
    guard correctionAt == nil else { return }
    let observationDue = deadline(now.continuousNanos, 1_000_000_000)
    let cooldown = lastCorrection.flatMap { deadline($0, 10_000_000_000) }
    if let observationDue { correctionAt = max(observationDue, cooldown ?? 0) }
  }
  private mutating func dispatchWriter(now: Instant, actions: inout [EngineAction]) {
    guard operational || (started && !blocked && closing != nil), writer == nil,
      pendingPersistence == nil
    else { return }
    let restoring = closing != nil || updateHold != nil
    if let command = prepared {
      let withinQuit =
        quitStarted.map {
          now.continuousNanos >= $0 && now.continuousNanos - $0 < Self.restoreWindow
        } ?? updateHold.map {
          now.continuousNanos >= $0.start && now.continuousNanos < $0.window.retryEnd
        } ?? true
      if desired == command.target, command.recovery || context == command.context,
        !restoring || command.recovery, withinQuit
      {
        prepared = nil
        writer = command
        writerCorrection = preparedCorrection
        preparedCorrection = false
        writeGeneration = audio?.generation ?? 0
        writerDecision = decisionVersion
        writerInQuit = restoring
        if writerCorrection {
          lastCorrection = now.continuousNanos
          correctionAt = nil
        }
        if closing != nil {
          quitAttempts += 1
        } else if updateHold != nil {
          updateHold?.attempts += 1
        }
        journal.audio.phase = .running
        actions.append(.writeTarget(command))
      } else {
        cancelPrepared(actions: &actions)
      }
      return
    }
    guard let target = desired else { return }
    let recovery = restoring || recoveryDue || recoveryRequested
    if let start = quitStarted {
      guard now.continuousNanos >= start, now.continuousNanos - start < Self.restoreWindow,
        quitAttempts < Self.restoreAttempts
      else { return }
    } else if let hold = updateHold {
      guard now.continuousNanos >= hold.start,
        now.continuousNanos < hold.window.retryEnd,
        hold.attempts < Self.restoreAttempts
      else { return }
    } else if blockedTargets.contains(target) {
      return
    }
    guard retryAt == nil else { return }
    if !recovery, retryTarget != nil, !base { return }
    let correction = !recovery && appliedTarget == target && appliedDecision == decisionVersion
    if correction {
      guard let due = correctionAt, now.continuousNanos >= due else { return }
    }
    guard let id = identifier() else { return }
    beforePrepared = journal.audio
    preparedCorrection = correction
    prepared = WriterCommand(run: run, id: id, context: context, target: target, recovery: recovery)
    var record = journal
    record.audio.phase = .prepared
    record.audio.restoreRequired = true
    record.audio.active = AudioCommand(id: id, target: target)
    persist(record, purpose: .prepared, actions: &actions)
  }
  private mutating func completeWriter(
    _ receipt: WriterReceipt, now: Instant, actions: inout [EngineAction]
  ) {
    guard let command = writer, receipt.command == command, command.run == run else { return }
    writer = nil
    let correction = writerCorrection
    writerCorrection = false
    beforePrepared = nil
    guard receipt.quiescent, receipt.persisted else {
      journal.audio.phase = .uncertain
      blocked = true
      actions.append(.showNotice(.recoveryBlocked))
      return
    }
    journal.audio.active = nil
    journal.audio.lastCompleted = CommandReceipt(
      id: command.id, target: command.target, exitCode: receipt.exitCode)
    let restored = command.recovery && command.target == .stereo && receipt.exitCode == 0
    journal.audio.phase = restored ? .restoreCommandCompleted : .completed
    journal.audio.restoreRequired = !restored
    if restored {
      recoveryDue = false
      recoveryRequested = false
    }
    if receipt.exitCode == 0 {
      appliedTarget = command.target
      appliedDecision = writerDecision
      confirmedGeneration = writeGeneration
      retries[command.target] = 0
      retryAt = nil
      retryTarget = nil
      if closing != nil, writerInQuit, command.recovery {
        quitRestored = true
      } else if updateHold != nil, writerInQuit, command.recovery, command.target == .stereo {
        updateHold?.restored = true
      }
    } else if let start = quitStarted ?? updateHold?.start {
      let attempts = closing != nil ? quitAttempts : updateHold?.attempts ?? 0
      if !writerInQuit {
        retryAt = nil
        retryTarget = nil
      } else if attempts < Self.restoreAttempts {
        let delay: UInt64 = attempts == 1 ? 200_000_000 : 600_000_000
        retryAt = deadline(start, delay)
        if retryAt.map({ $0 <= now.continuousNanos }) == true { retryAt = nil }
      }
    } else if correction {
      // A correction never spends the decision/recovery budget or produces a popup.
      correctionAt = lastCorrection.flatMap { deadline($0, 10_000_000_000) }
    } else if base || command.recovery {
      let failures = (retries[command.target] ?? 0) + 1
      retries[command.target] = failures
      if failures > 3 {
        blockedTargets.insert(command.target)
        actions.append(.showNotice(.commandFailed))
      } else if desired == command.target {
        let delays: [UInt64] = [5, 30, 120]
        retryTarget = command.target
        retryAt = deadline(now.continuousNanos, delays[failures - 1] * 1_000_000_000)
      }
    }
  }
  private mutating func beginClose(
    _ reason: ExitReason, now: Instant, actions: inout [EngineAction]
  ) {
    guard closing == nil else { return }
    if reason == .user && detection == .on { actions.append(.showNotice(.detectionQuitReminder)) }
    resetRetries()
    // A confirmed preparation already restored Stereo, or proved that nothing needs it.
    if let result = updateHold?.result, result != .unconfirmed { quitRestored = true }
    updateHold = nil
    closing = reason
    quitStarted = now.continuousNanos
    invalidate()
    correctionAt = nil
  }
  private mutating func finishClose(now: Instant, actions: inout [EngineAction]) {
    guard let closing, !closureSaved, writer == nil, prepared == nil, pendingPersistence == nil
    else { return }
    let attemptsOver =
      quitStarted.map {
        now.continuousNanos >= $0 && now.continuousNanos - $0 >= 1_500_000_000
      } ?? false
    if blocked || (!snapshot.restoreConfirmed && (quitAttempts >= 3 || attemptsOver)) {
      // Failed/uncertain exits retain the unclean marker and debt.
      terminated = true
      actions.append(.terminate(0))
      return
    }
    guard snapshot.restoreConfirmed else { return }
    var record = journal
    record.lifecycle.closedCleanly = true
    record.lifecycle.exitReason = closing
    if noticeConfirmed { record.lifecycle.noticePending = false }
    persist(record, purpose: .closing, actions: &actions)
  }
  private mutating func beginUpdateHold(
    _ id: UInt64, now: Instant, actions: inout [EngineAction]
  ) {
    guard updateHold == nil, closing == nil else { return }
    guard loaded, started, !blocked else {
      // Missing or invalid evidence is never a no-op.
      actions.append(.updatePrepared(id: id, result: .unconfirmed))
      return
    }
    resetRetries()
    updateHold = UpdateHold(id: id, window: UpdatePreparationWindow(start: now.continuousNanos))
    // Pending Play work would fire after the hold; the count stays for the resumed automation.
    countRemovals.removeAll()
    episodes.removeAll()
    transitions.removeAll()
    pauseGuard = nil
    pendingEntries.removeAll()
    correctionAt = nil
    finishUpdateHold(now: now, actions: &actions)
  }
  /// Reports once: a late receipt after the window cannot turn the result into a confirmation.
  private mutating func finishUpdateHold(now: Instant, actions: inout [EngineAction]) {
    guard var hold = updateHold, !hold.reported, closing == nil else { return }
    let idle = writer == nil && prepared == nil && pendingPersistence == nil
    let result: UpdatePreparationResult
    if blocked || now.continuousNanos < hold.start || now.continuousNanos >= hold.window.end {
      result = .unconfirmed
    } else if !idle {
      return
    } else if hold.restored {
      result = .stereoConfirmed
    } else if audio?.systemMono == .on {
      result = .nothingToRestore
    } else if !journal.audio.restoreRequired, !recoveryDue, !recoveryRequested {
      result = .nothingToRestore
    } else if hold.attempts >= Self.restoreAttempts {
      result = .unconfirmed
    } else {
      return
    }
    hold.reported = true
    hold.result = result
    updateHold = hold
    actions.append(.updatePrepared(id: hold.id, result: result))
  }
  private mutating func persistConfirmedNotice(actions: inout [EngineAction]) {
    guard noticeConfirmed, journal.lifecycle.noticePending, !blocked, closing == nil,
      prepared == nil, pendingPersistence == nil, writer == nil
    else { return }
    var record = journal
    record.lifecycle.noticePending = false
    persist(record, purpose: .notice, actions: &actions)
  }
}

/// Equality covers every stored field, private ones included: the runtime compares the engine
/// before and after an input to leave inputs without any effect out of the diary.
extension Engine: Equatable {}
