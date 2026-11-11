import AppKit
import Combine
import Darwin
import Foundation
import MonoPodsCore

/// Captions under the menu's login toggle.
public enum LoginText {
  public static let nextLogin = "Applies from the next login."
  public static let notInstalled = "Move MonoPods to Applications to launch at login."
  public static let failed = "The login item could not be updated."
  public static let unsupervised = "Automatic restart is not active until the next login."
}

@MainActor public final class RuntimeHost: ObservableObject {
  @Published public var menuVisible = false
  @Published public private(set) var launchAtLogin = true
  @Published public private(set) var loginCaption = LoginText.nextLogin
  @Published public private(set) var status = "Starting"
  @Published public private(set) var count = "unknown"
  @Published public private(set) var detection = "unknown"
  @Published public private(set) var routeName = "No Bluetooth output"
  @Published public private(set) var routeModel: AirPodsModel?
  @Published public private(set) var lastCommand = "unknown"
  @Published public private(set) var snapshot: EngineSnapshot?
  @Published public private(set) var glyph: MenuBarGlyph = .idle
  /// The Stereo frame to draw. Only the ripple's one-shot timer and `publish` change it, never the
  /// scene update.
  @Published public private(set) var waveFrame = StereoRipple.restingFrame
  private var files: AtomicRuntimeFiles?
  private var owner: InstanceLock?
  private var agent: LaunchAgentFile?
  private var fifo: EngineFIFO?
  private var driver: ObservationDriver?
  private var transport: LogTransport?
  private var observations: SystemObservations?
  private let media = MediaAdapter()
  private let presenter = NoticePresenter()
  private var channel: OwnerChannel?
  private var log: DiagnosticLog?
  private var timer: Timer?
  private var alarm: DeadlineAlarm?
  private var activity: NSObjectProtocol?
  private var signals: [DispatchSourceSignal] = []
  private var adaptersStarted = false
  private var reopenSent = false
  private var writerActive = false
  private var audioAdapter: AudioModeAdapter?
  private var audioStarted = false
  private var journalLoaded = false
  private var quitRequested = false
  private let quitDeadline = QuitDeadline()
  private let updateWritePermission = UpdateWritePermission()
  private var traceSequence: UInt64 = 0
  private var previousClock: Instant?
  private var menuVisibilityGeneration: UInt64 = 0
  private var lastSlowPulse: UInt64 = 0
  private var run: UInt64 = 1
  private var build = ""
  private var boot = ""
  private var isolated = false
  private var realAudioAllowed = false
  private var preferencesDirty = false
  private var preferences = ControlPreferences()
  /// Called once, on the owner, when the updater may start.
  public var onUpdatesAllowed: (@MainActor () -> Void)?
  /// The role this launch found in the update handoff.
  public private(set) var handoffRole = HandoffRole.none
  /// The source build waits for Sparkle to replace the bundle; it runs nothing else.
  public private(set) var waitingForUpdate = false
  /// The integer bundle version this process was loaded from.
  public private(set) var bundleVersion: Int?
  private var updateGate = UpdateGate()
  private var bundleIdentifier: String?
  private var infoDictionary: [String: Any]?
  private var role = RuntimeRole.product
  private var bundleURL: URL?
  private var executableURL: URL?
  private var bundleValid = true
  private var unlockSession: UpdateUnlockSession?
  private var handoffCleared = false
  private var updatesSignalled = false
  private var updateReplies: [UInt64: @MainActor (UpdatePreparationResult) -> Void] = [:]
  private var waitTimer: Timer?
  private var waitFiles: AtomicRuntimeFiles?
  /// Last ear side read from a placement row, for the icon only; nil until one is read and after
  /// a route change. It is not published: the next pulse folds it into `glyph`.
  var earSide: EarSide?
  private let wave: WaveAnimator
  public init(waveSchedule: @escaping OneShotSchedule = WaveAnimator.mainQueue) {
    wave = WaveAnimator(schedule: waveSchedule)
    wave.onFrame = { [weak self] frame in self?.update(\.waveFrame, to: frame) }
  }

  public func start(bundle: Bundle = .main, environment: RuntimeEnvironment? = nil) {
    do {
      let environment = try environment ?? RuntimeEnvironment.current()
      let location = try RuntimeLocation.resolve(bundle: bundle, environment: environment)
      guard let manifestURL = bundle.url(forResource: "Manifest", withExtension: "json")
      else { throw RuntimeError.invalid }
      let manifest = try ContractValidation.decode(
        BundleManifest.self, data: Data(contentsOf: manifestURL))
      bundleIdentifier = bundle.bundleIdentifier
      infoDictionary = bundle.infoDictionary
      role = location.role
      bundleURL = bundle.bundleURL
      executableURL = bundle.executableURL
      bundleVersion = Self.integerVersion(bundle.infoDictionary?["CFBundleVersion"])
      // Classify the update handoff after manifest decoding, before normal startup.
      let handoffFiles = try RuntimeDirectory.ensure(location)
      handoffRole = Self.classify(handoffFiles, version: bundleVersion, manifest: manifest.build) {
        Self.runningBundleValid(
          bundle.bundleURL, executable: bundle.executableURL, version: bundleVersion,
          manifest: manifest.build)
      }
      switch handoffRole {
      case .waiting(let handoff):
        enterWaiting(handoff, files: handoffFiles, manifest: manifest.build)
        return
      case .invalid: throw RuntimeError.invalid
      case .none, .destination, .recovering: break
      }
      try manifest.verify(bundle: bundle.bundleURL)
      build = manifest.build
      boot = try SystemClock.bootUUID()
      isolated = location.role == .isolatedHarness
      realAudioAllowed = RuntimeConfiguration.mayUseRealAudio(identifier: bundle.bundleIdentifier)
      let files = handoffFiles
      self.files = files
      if let data = try files.read("preferences.json") {
        let saved = try ControlPreferences.decode(data)
        preferences = saved.migrated()
        // A file of 1.0.0 with automatic switching off is written again with it on.
        preferencesDirty = preferences != saved
      }
      menuVisible = preferences.menuBarVisible
      launchAtLogin = preferences.launchAtLogin
      agent = LaunchAgentFile.installed(bundle, location: location)
      if agent == nil { loginCaption = LoginText.notInstalled }
      // An instance not started by its job hands over to launchd while the lock is free.
      if let agent, preferences.launchAtLogin,
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != agent.label,
        (try? InstanceLock(files: files, name: "owner.lock")) != nil
      {
        Task { @MainActor [weak self] in
          if await Self.handOver(agent) { exit(0) }
          self?.loginCaption = LoginText.unsupervised
          self?.begin(location)
        }
        return
      }
      begin(location)
    } catch {
      menuVisible = true
      glyph = .attention
      status = "Configuration, manifest or runtime evidence is invalid. Automation is blocked."
      _ = presenter.present(.recoveryBlocked)
    }
  }
  static func integerVersion(_ value: Any?) -> Int? {
    guard let text = value as? String, let number = Int(text), String(number) == text, number > 0,
      number <= UpdateTransition.maximumBuild
    else { return nil }
    return number
  }
  static func classify(
    _ files: AtomicRuntimeFiles, version: Int?, manifest: String,
    verifyRunning: () -> Bool = { false }
  ) -> HandoffRole {
    let handoff = Result<UpdateHandoff?, any Error> {
      try files.readHandoff().map { try UpdateHandoff.decode($0) }
    }
    let unlock = Result<UpdateUnlock?, any Error> {
      try files.readUnlock().map(UpdateUnlock.decode)
    }
    return HandoffRole.classify(
      handoff, unlock: unlock, runningBuild: version, runningManifest: manifest,
      runningBundleVerified: verifyRunning)
  }
  /// The source build after a crash: no engine, audio, journal, plist or updater. It leaves when
  /// the bundle on disk is the destination, so launchd starts the new build.
  private func enterWaiting(_ handoff: UpdateHandoff, files: AtomicRuntimeFiles, manifest: String) {
    waitingForUpdate = true
    waitFiles = files
    menuVisible = true
    status = UpdateText.installing
    // Recheck under the lock, then release it at once: this process never becomes the owner.
    if let lock = try? InstanceLock(files: files, name: "owner.lock") {
      let current = Self.classify(files, version: bundleVersion, manifest: manifest)
      withExtendedLifetime(lock) {}
      guard current == .waiting(handoff) else { exit(75) }
    }
    let infoURL = bundleURL?.appendingPathComponent("Contents/Info.plist")
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
      let onDisk = infoURL.flatMap { NSDictionary(contentsOf: $0)?["CFBundleVersion"] as? String }
      if WaitingTermination.replaced(onDisk: onDisk, destination: handoff.destinationBuild) {
        // A failure status makes launchd start the replaced bundle.
        exit(75)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    waitTimer = timer
  }
  /// The user resumes the old build after a failed installation. Sparkle reports no
  /// end of its installer, so only this explicit choice, with the source bundle intact and the
  /// lock held, removes the handoff. The relaunch then recovers the journal after the unclean exit.
  public func resumeWithoutUpdate() -> Bool {
    guard waitingForUpdate, case .waiting(let handoff) = handoffRole, let files = waitFiles,
      let bundleURL
    else { return false }
    do {
      let session = try UpdateUnlockSession(
        store: files, acquireLock: { try InstanceLock(files: files, name: "owner.lock") },
        verifySource: {
          Self.sourceBundleValid(
            bundleURL, version: handoff.sourceBuild, manifest: handoff.sourceManifest)
        })
      try session.confirm(handoff, at: SystemClock.now().utc)
      withExtendedLifetime(session) { exit(75) }
    } catch { return false }
  }
  private static func sourceBundleValid(
    _ bundle: URL, version: Int, manifest identity: String,
    signatureValid: (URL) -> Bool = LoadedBundle.signatureValid
  ) -> Bool {
    let manifestURL = bundle.appendingPathComponent("Contents/Resources/Manifest.json")
    let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: manifestURL),
      let manifest = try? ContractValidation.decode(BundleManifest.self, data: data),
      manifest.build == identity, (try? manifest.verify(bundle: bundle)) != nil,
      integerVersion(NSDictionary(contentsOf: infoURL)?["CFBundleVersion"]) == version
    else { return false }
    return signatureValid(bundle)
  }
  /// For a build newer than an unlock record: its own manifest, version and signature,
  /// and the images this process loaded from that bundle.
  static func runningBundleValid(
    _ bundle: URL?, executable: URL?, version: Int?, manifest identity: String,
    signatureValid: (URL) -> Bool = LoadedBundle.signatureValid,
    imagesMatch: ([URL]) -> Bool = LoadedBundle.imagesMatch
  ) -> Bool {
    guard let bundle, let executable, let version else { return false }
    let framework = bundle.appendingPathComponent(
      "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")
    return sourceBundleValid(
      bundle, version: version, manifest: identity, signatureValid: signatureValid)
      && imagesMatch([executable, framework])
  }
  /// Writes the plist, then loads the job; an already loaded job is started instead.
  private static func handOver(_ agent: LaunchAgentFile) async -> Bool {
    guard (try? agent.apply(enabled: true)) != nil else { return false }
    let domain = "gui/\(getuid())"
    let (_, loaded) = await CommandCapture.run(
      executable: "/bin/launchctl", arguments: ["bootstrap", domain, agent.path])
    if loaded == 0 { return true }
    let (_, started) = await CommandCapture.run(
      executable: "/bin/launchctl", arguments: ["kickstart", domain + "/" + agent.label])
    return started == 0
  }
  private func begin(_ location: RuntimeLocation) {
    channel = OwnerChannel(directory: location.runtimeDirectory)
    channel?.command = { [weak self] in self?.controlMessage($0) }
    channel?.confirmation = { [weak self] run, build, healthy in
      // A confirmation counts only while another process holds the lock.
      guard let self, self.owner == nil, self.ownerIsBusy() else { return }
      self.fifo?.enqueue(.ownerConfirmed(run: run, build: build, healthy: healthy))
    }
    // Run identifiers are advanced under owner.lock.
    run = max(1, SystemClock.now().continuousNanos)
    // App Nap defers timers of an app with no window: held for the app's lifetime, this keeps the
    // pulse and the deadline alarm on time when a Pause opens a Play episode. The episode itself is
    // engine state that the host cannot see, so a per-episode activity would need a new engine
    // output. `.userInitiated` would also disable idle system sleep for as long as the app runs,
    // so the variant that allows idle sleep is used.
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "Resume playback on time after an AirPod is removed")
    alarm = DeadlineAlarm(clock: SystemClock.now) { [weak self] in self?.deadlineReached() }
    configureFIFO()
    fifo?.enqueue(.ownerWaiting)
    // The pulse stays for the heartbeat, ownership and the menu state. In the common modes it also
    // runs while the menu is open, which the default mode alone does not.
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pulse() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in
        Task { @MainActor in self?.requestQuit(reason: .signal) }
      }
      source.resume()
      signals.append(source)
    }
  }
  private func configureFIFO() {
    fifo = EngineFIFO(
      engine: Engine(build: build, run: run, boot: boot), clock: SystemClock.now,
      execute: { [weak self] action, reply in self?.execute(action, reply: reply) })
    fifo?.observe = { [weak self] input, now, actions in
      self?.observe(input, now: now, actions: actions)
    }
    fifo?.flushed = { [weak self] in
      guard let self else { return }
      self.alarm?.arm(self.fifo?.nextDeadline)
      if self.quitRequested {
        self.quitDeadline.confirmRestore(self.fifo?.snapshot.restoreConfirmed == true)
      }
    }
  }
  /// The alarm reached the engine's deadline: tick now instead of at the next pulse.
  private func deadlineReached() {
    guard let fifo, fifo.tickIfDue() else { return }
    fifo.flush()
  }
  private func ownerIsBusy() -> Bool {
    guard let files else { return false }
    do {
      _ = try InstanceLock(files: files, name: "owner.lock")
      return false
    } catch RuntimeError.busy { return true } catch { return false }
  }
  private func acquireOwner() {
    guard owner == nil, let files else { return }
    do {
      owner = try InstanceLock(files: files, name: "owner.lock")
      // The handoff is checked again under the lock, before any operational role.
      let (bundle, executable, version, identity) = (bundleURL, executableURL, bundleVersion, build)
      let current = Self.classify(files, version: version, manifest: identity) {
        Self.runningBundleValid(
          bundle, executable: executable, version: version, manifest: identity)
      }
      guard current == handoffRole else {
        owner = nil
        if case .waiting(let handoff) = current {
          stopForWaiting()
          enterWaiting(handoff, files: files, manifest: build)
          return
        }
        throw RuntimeError.invalid
      }
      if case .destination = handoffRole { bundleValid = destinationBundleValid() }
      if case .recovering(let record) = handoffRole {
        guard let owner, let bundleURL else { throw RuntimeError.invalid }
        let session = try UpdateUnlockSession(
          store: files, acquireLock: { owner },
          verifySource: {
            HandoffRole.recoveryBundleValid(
              record, runningBuild: version,
              source: {
                Self.sourceBundleValid(bundleURL, version: record.sourceBuild, manifest: identity)
              },
              running: {
                Self.runningBundleValid(
                  bundleURL, executable: executable, version: version, manifest: identity)
              })
          })
        try session.resume(record)
        unlockSession = session
      }
      let loaded = files.load()
      if case .record(let record) = loaded {
        guard record.lifecycle.run < UInt64.max else { throw RuntimeError.invalid }
        let nextRun = max(run, record.lifecycle.run + 1)
        if nextRun != run {
          run = nextRun
          configureFIFO()
        }
      }
      log = DiagnosticLog(files: files)
      append(.launch(LaunchPayload(utc: SystemClock.now().utc, boot: boot)), at: SystemClock.now())
      fifo?.enqueue(.ownerAcquired(run: run))
      startAudioAdapter()
      journalLoaded = true
      fifo?.enqueue(.journalLoaded(bundleValid ? loaded : .blocked))
      fifo?.enqueue(.automation(effectiveAutomation))
      savePreferences()
      // Under the lock, the plist follows the saved choice.
      if let agent, (try? agent.apply(enabled: preferences.launchAtLogin)) == nil {
        loginCaption = LoginText.failed
      }
    } catch RuntimeError.busy {
      status = "Waiting for the command owner"
      // The owner shows its icon once; a confirmation from it ends this instance.
      if !reopenSent {
        reopenSent = true
        channel?.send("reopen")
      }
    } catch {
      journalLoaded = true
      fifo?.enqueue(.journalLoaded(.blocked))
    }
  }
  /// Automatic switching has no user setting: it runs while the app runs. Ordinary commands wait
  /// while a destination build has not yet cleared its handoff.
  private var effectiveAutomation: Bool {
    switch handoffRole {
    case .destination, .recovering: return handoffCleared
    default: return true
    }
  }
  private var activation: UpdateActivation {
    let snapshot = fifo?.snapshot
    return UpdateActivation(
      role: handoffRole, ownsLock: owner != nil, bundleValid: bundleValid,
      engineOperational: snapshot?.operational == true,
      recoveryPending: snapshot?.recoveryPending ?? true, handoffCleared: handoffCleared)
  }
  /// The destination build verifies its signature, its version and the images loaded.
  private func destinationBundleValid() -> Bool {
    guard case .destination(let handoff) = handoffRole, bundleVersion == handoff.destinationBuild,
      let bundleURL, let executable = Bundle.main.executableURL
    else { return false }
    let framework = bundleURL.appendingPathComponent(
      "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")
    return LoadedBundle.signatureValid(bundleURL)
      && LoadedBundle.imagesMatch([executable, framework])
  }
  /// After journal recovery: clear the handoff, then resume commands, then allow the updater once.
  private func activateUpdates() {
    var state = activation
    if state.clearsHandoff, let files {
      if case .recovering(let record) = handoffRole {
        guard (try? unlockSession?.finish(record, recovered: true)) == true else { return }
        unlockSession = nil
      } else {
        guard (try? files.removeHandoff()) != nil else { return }
      }
      handoffCleared = true
      fifo?.enqueue(.automation(effectiveAutomation))
      state = activation
    }
    guard !updatesSignalled, state.updatesAllowed else { return }
    updatesSignalled = true
    let allowed = UpdatePolicy.allows(
      identifier: bundleIdentifier, role: role, info: infoDictionary)
    if updateGate.ownerAcquired(allowed: allowed) { onUpdatesAllowed?() }
  }
  private func stopForWaiting() {
    timer?.invalidate()
    timer = nil
    alarm?.arm(nil)
    channel?.stop()
    fifo = nil
  }
  private func pulse() {
    guard let fifo else { return }
    if owner == nil, !fifo.snapshot.terminated {
      acquireOwner()
    }
    let now = SystemClock.now()
    if let previousClock {
      let wall = Double(now.utc.nanos) - Double(previousClock.utc.nanos)
      let continuous = Double(now.continuousNanos) - Double(previousClock.continuousNanos)
      if abs(wall - continuous) > 1_000_000_000, let driver {
        fifo.enqueue(.gap(epoch: driver.streamEpoch, reason: .clockChanged, faultTime: nil))
      }
    }
    previousClock = now
    fifo.tickIfDue()
    let slow = now.continuousNanos &- lastSlowPulse >= 1_000_000_000
    if slow { lastSlowPulse = now.continuousNanos }
    let operational = fifo.snapshot.operational
    if operational, owner != nil, !adaptersStarted { startAdapters() }
    if owner != nil, !fifo.snapshot.terminated { activateUpdates() }
    if slow, owner != nil {
      channel?.confirm(
        run: run, build: build, healthy: fifo.snapshot.healthy && fifo.snapshot.operational)
    }
    publish(
      snapshot: fifo.snapshot, routeName: observations?.routeName ?? "No Bluetooth output",
      routeModel: observations?.routeModel)
  }
  /// Publishes the pulse state. Unchanged values are not reassigned: every @Published write
  /// invalidates the menu bar scene, and the pulse runs every 100 ms.
  func publish(
    snapshot next: EngineSnapshot, routeName nextRoute: String, routeModel nextModel: AirPodsModel?
  ) {
    update(\.snapshot, to: next)
    let nextGlyph = MenuBarGlyph.glyph(for: next, side: earSide)
    // The ripple runs once when the glyph turns Stereo and stops when the glyph changes again; an
    // unchanged Stereo pulse leaves it alone.
    if nextGlyph != glyph {
      if nextGlyph == .stereo { wave.start() } else { wave.stop() }
    }
    update(\.glyph, to: nextGlyph)
    update(\.count, to: next.count.map(String.init) ?? "unknown")
    update(\.detection, to: next.detection.rawValue)
    update(
      \.lastCommand,
      to: next.lastCompleted.map { "\($0.target.rawValue), exit \($0.exitCode)" } ?? "unknown")
    update(\.routeName, to: nextRoute)
    update(\.routeModel, to: nextModel)
    update(
      \.status,
      to: next.blocked
        ? "Automation blocked; recovery evidence needs review"
        : (next.healthy ? "Observing" : "Waiting for verified stream transport"))
  }
  private func update<Value: Equatable>(
    _ property: ReferenceWritableKeyPath<RuntimeHost, Value>, to value: Value
  ) {
    if self[keyPath: property] != value { self[keyPath: property] = value }
  }
  private func startAdapters() {
    adaptersStarted = true
    if isolated {
      fifo?.enqueue(.sentinelAvailable(false))
      fifo?.enqueue(.streamStarted(epoch: 1, nonce: "isolated"))
      return
    }
    let driver = ObservationDriver(clock: SystemClock.now) { [weak self] in self?.fifo?.enqueue($0)
    }
    driver.evidence = { [weak self] kind, hash in self?.recordEvidence(kind, hash: hash) }
    driver.placement = { [weak self] side in self?.earSide = side }
    self.driver = driver
    let transport = LogTransport(driver: driver, boot: boot) { [weak self] in
      self?.fifo?.enqueue($0)
    }
    self.transport = transport
    // Open stream before querying history or subscribing to other observations.
    transport.start()
    let observations = SystemObservations(
      driver: driver, requestQuit: { [weak self] in self?.requestQuit(reason: .logout) },
      submit: { [weak self] in self?.fifo?.enqueue($0) })
    self.observations = observations
    observations.start()
    fifo?.enqueue(.sentinelAvailable(media.start { [weak self] in self?.fifo?.enqueue($0) }))
  }
  private func startAudioAdapter() {
    guard !audioStarted, owner != nil else { return }
    audioStarted = true
    let adapter = AudioModeAdapter.runtime(
      isolated: !realAudioAllowed,
      writeAllowed: { [quitDeadline, updateWritePermission] command in
        quitDeadline.allowsWrite(recovery: command.recovery)
          && updateWritePermission.allowsWrite(recovery: command.recovery)
      })
    audioAdapter = adapter
    adapter.start { [weak self] reading in self?.fifo?.enqueue(.audioObserved(reading)) }
  }
  private func execute(_ action: EngineAction, reply: @escaping EngineFIFO.Reply) {
    guard let files else { return }
    switch action {
    case .acquireOwner: acquireOwner()
    case .persist(let request):
      do {
        guard owner != nil, !writerActive, !quitDeadline.expired else { throw RuntimeError.busy }
        try files.persist(record: request.record)
        reply(.persistenceAcknowledged(run: run, id: request.id, success: true))
      } catch { reply(.persistenceAcknowledged(run: run, id: request.id, success: false)) }
    case .writeTarget(let command): applyAudio(command, reply: reply)
    case .play(let command):
      reply(.playCompleted(run: run, id: command.id, accepted: !isolated && media.play()))
    case .pause: if !isolated { _ = media.pause() }
    case .emitHeartbeat(let epoch, let nonce, let sequence):
      if isolated {
        reply(.heartbeat(epoch: epoch, nonce: nonce, sequence: sequence))
      } else {
        observations?.emit(nonce: nonce, sequence: sequence)
      }
    case .restartStream(let epoch, let delay): transport?.restart(epoch: epoch, afterNanos: delay)
    case .queryHistory(let id, let context): transport?.history(id: id, context: context)
    case .restoreIcon: setMenuVisible(true)
    case .showNotice(let notice): reply(.noticePresented(notice, success: show(notice)))
    case .updatePrepared(let id, let result): updateReplies.removeValue(forKey: id)?(result)
    case .terminate(let code):
      if quitRequested {
        let confirmed = fifo?.snapshot.restoreConfirmed == true
        if confirmed {
          let now = SystemClock.now()
          append(.end(EndPayload(utc: now.utc, exitCode: code)), at: now)
        }
        quitDeadline.finish(confirmed: confirmed)
        return
      }
      append(.end(EndPayload(utc: SystemClock.now().utc, exitCode: code)), at: SystemClock.now())
      stopAdapters()
      timer?.invalidate()
      timer = nil
      alarm?.arm(nil)
      if let activity { ProcessInfo.processInfo.endActivity(activity) }
      activity = nil
      channel?.stop()
      owner = nil
      exit(code)
    }
  }
  private func applyAudio(_ command: WriterCommand, reply: @escaping EngineFIFO.Reply) {
    startAudioAdapter()
    guard !writerActive, quitDeadline.canStartAttempt, let owner, let files, let audioAdapter else {
      reply(
        .writerCompleted(
          WriterReceipt(command: command, exitCode: -1, quiescent: false, persisted: false)))
      return
    }
    writerActive = true
    audioAdapter.apply(command, files: files, owner: owner) { [weak self] result in
      guard let self, !self.quitDeadline.expired else { return }
      self.writerActive = false
      switch result {
      case .completed(let receipt): reply(.writerCompleted(receipt))
      case .systemMono(let command): reply(.audioWriteSkipped(command))
      }
    }
  }
  private func observe(_ input: EngineInput, now: Instant, actions: [EngineAction]) {
    if quitRequested { quitDeadline.confirmRestore(fifo?.snapshot.restoreConfirmed == true) }
    switch input {
    case .observation(let observation):
      if case .count = observation.value {
        audioAdapter?.refresh(rearm: fifo?.snapshot.audio?.status != 0)
      }
    case .environment(let awake, _):
      if awake { audioAdapter?.refresh(rearm: true) }
    case .reopen: audioAdapter?.refresh(rearm: true)
    default: break
    }
    append(.input(InputPayload(utc: now.utc, input: input)), at: now)
    append(.actions(ActionsPayload(utc: now.utc, actions: actions)), at: now)
  }
  private func append(_ payload: TracePayload, at now: Instant) {
    guard log != nil, traceSequence < UInt64.max else { return }
    traceSequence += 1
    do {
      try log?.append(
        TraceRecord(
          build: build, run: run, seq: traceSequence, m: now.continuousNanos, payload: payload))
    } catch { status = "Diagnostic persistence failed" }
  }
  private func recordEvidence(_ kind: EvidenceKind, hash: String) {
    let now = SystemClock.now()
    append(
      .evidence(EvidencePayload(utc: now.utc, kind: kind, verified: true, evidenceHash: hash)),
      at: now)
  }
  private func stopAdapters() {
    audioAdapter?.stop()
    transport?.stop()
    observations?.stop()
    media.stop()
  }
  private func show(_ notice: Notice) -> Bool {
    status = NoticePresenter.message(notice)
    if notice == .detectionQuitReminder,
      let executable = Bundle.main.executableURL?.path,
      (try? DetachedProcess.spawn(executable: executable, arguments: ["--notice", notice.rawValue]))
        != nil
    {
      return true
    }
    return presenter.present(notice)
  }
  private func controlMessage(_ message: String) {
    guard owner != nil else { return }
    switch message {
    case "reopen": fifo?.enqueue(.reopen)
    case "quit" where isolated: requestQuit(reason: .user)
    case "off" where isolated: setLaunchAtLogin(false)
    case "crash" where isolated: abort()
    default: break
    }
  }
  public func reopen() {
    if owner != nil { fifo?.enqueue(.reopen) } else { channel?.send("reopen") }
  }
  public func requestMenuVisible(_ visible: Bool) {
    menuVisibilityGeneration &+= 1
    let generation = menuVisibilityGeneration
    guard visible != menuVisible else { return }
    Task { @MainActor [weak self] in
      guard let self, self.menuVisibilityGeneration == generation else { return }
      self.setMenuVisible(visible)
    }
  }
  public func setMenuVisible(_ visible: Bool) {
    menuVisibilityGeneration &+= 1
    guard visible != menuVisible else { return }
    menuVisible = visible
    preferences.menuBarVisible = visible
    preferencesDirty = true
    savePreferences()
  }
  public func quit() { requestQuit(reason: .user) }
  /// The sole entry for menu, delegate, signals, power-off and the isolated control channel.
  public func requestQuit(reason: ExitReason) {
    // The waiting process owns no audio and no journal: it ends at once.
    if waitingForUpdate { exit(0) }
    guard !quitRequested else { return }
    guard let fifo, owner != nil, journalLoaded else { exit(0) }
    quitRequested = true
    updateWritePermission.hold(nil)
    startAudioAdapter()
    let warning = stereoRestoreWarning()
    quitDeadline.arm(warn: { warning.warn() }, terminate: { _exit(0) })
    fifo.enqueue(.quit(reason))
    fifo.flush()
  }
  /// Both update preparation and Quit use the same detached warning and fallback panel.
  public func stereoRestoreWarning() -> StereoRestoreWarning {
    let executable = Bundle.main.executableURL?.path
    let presenter = self.presenter
    return StereoRestoreWarning(
      spawn: {
        guard let executable else { return false }
        return
          (try? DetachedProcess.spawn(
            executable: executable, arguments: ["--notice", Notice.stereoNotRestored.rawValue]))
          != nil
      },
      fallback: {
        DispatchQueue.main.async { _ = presenter.present(.stereoNotRestored) }
      })
  }
  /// The choice is saved first; the plist changes now, the job from the next login.
  public func setLaunchAtLogin(_ enabled: Bool) {
    guard enabled != launchAtLogin, owner != nil else { return }
    launchAtLogin = enabled
    preferences.launchAtLogin = enabled
    preferencesDirty = true
    guard savePreferences() else {
      loginCaption = LoginText.failed
      return
    }
    guard let agent else { return }
    loginCaption =
      (try? agent.apply(enabled: enabled)) == nil ? LoginText.failed : LoginText.nextLogin
  }
  @discardableResult private func savePreferences() -> Bool {
    guard preferencesDirty else { return true }
    guard let files, owner != nil else { return false }
    do {
      try files.write(JSONEncoder().encode(preferences), name: "preferences.json")
      preferencesDirty = false
      return true
    } catch {
      _ = presenter.present(.persistenceFailed)
      return false
    }
  }
}

extension RuntimeHost: UpdateAudioPort {
  /// The files of the owner, where the update handoff lives.
  public var handoffStore: (any HandoffStore)? { owner == nil ? nil : files }
  /// The manifest identity of the running build.
  public var manifestBuild: String { build }
  public func prepareForUpdate(
    id: UInt64, deadline: UpdatePreparationDeadline,
    result: @escaping @MainActor (UpdatePreparationResult) -> Void
  ) {
    guard owner != nil, let fifo, !quitRequested, let start = deadline.startedAt else {
      result(.unconfirmed)
      return
    }
    updateWritePermission.hold(deadline)
    updateReplies[id] = result
    fifo.enqueue(
      .prepareUpdate(id: id), at: Instant(continuousNanos: start, utc: SystemClock.now().utc))
    fifo.flush()
  }
  public func endUpdateHold(id: UInt64) {
    updateReplies.removeValue(forKey: id)
    updateWritePermission.hold(nil)
    fifo?.enqueue(.endUpdateHold(id: id))
  }
}
