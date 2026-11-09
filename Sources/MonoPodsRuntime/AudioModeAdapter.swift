import CoreAudio
import Foundation
import MonoPodsCore

public struct AudioHardwareReading: Sendable {
  public var status: Int32
  public var rawValue: UInt32
  public var byteCount: UInt32
  public init(status: Int32, rawValue: UInt32, byteCount: UInt32) {
    self.status = status
    self.rawValue = rawValue
    self.byteCount = byteCount
  }
}
public struct AudioPropertyCheck: Sendable {
  public var status: Int32
  public var value: Bool
  public init(status: Int32, value: Bool) {
    self.status = status
    self.value = value
  }
}
public enum AudioHardwareProperty: Sendable { case mode, serviceRestarted }
public final class AudioHardwareListener: Sendable {
  public let property: AudioHardwareProperty
  public let callback: @Sendable () -> Void
  public init(property: AudioHardwareProperty, callback: @escaping @Sendable () -> Void) {
    self.property = property
    self.callback = callback
  }
}
public protocol AudioHardware: Sendable {
  func hasMode() -> AudioPropertyCheck
  func modeIsSettable() -> AudioPropertyCheck
  func readMode() -> AudioHardwareReading
  func readSystemMono() -> SystemMono
  func setMode(_ value: UInt32) -> Int32
  func addListener(_ listener: AudioHardwareListener) -> Int32
  func removeListener(_ listener: AudioHardwareListener) -> Int32
}
public protocol AudioAdapterScheduler: Sendable {
  func after(_ delay: TimeInterval, perform: @escaping @Sendable () -> Void)
}
public enum AudioWriteResult: Equatable, Sendable {
  case completed(WriterReceipt)
  case systemMono(WriterCommand)
}
enum SystemMonoPreference {
  static func decode(_ value: Any?, synchronized: Bool) -> SystemMono {
    guard synchronized, let number = value as? NSNumber else { return .unreadable }
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? .on : .off }
    guard CFGetTypeID(number) == CFNumberGetTypeID(),
      !CFNumberIsFloatType(number), number == 0 || number == 1
    else { return .unreadable }
    return number == 1 ? .on : .off
  }
}

private struct DispatchAudioScheduler: AudioAdapterScheduler {
  let queue: DispatchQueue
  func after(_ delay: TimeInterval, perform: @escaping @Sendable () -> Void) {
    queue.asyncAfter(deadline: .now() + delay, execute: perform)
  }
}

/// Invalidated synchronously on the main actor, including deliveries already enqueued there.
private final class AudioDeliveryLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  var isActive: Bool { lock.withLock { active } }
  func invalidate() { lock.withLock { active = false } }
}

private final class AudioRegistration: @unchecked Sendable {
  private let lock = NSLock()
  private var installing = true
  private var resetDuringInstallation = false
  func noteRestart() -> Bool {
    lock.withLock {
      if installing { resetDuringInstallation = true }
      return installing
    }
  }
  func finishInstallation() -> Bool {
    lock.withLock {
      installing = false
      return !resetDuringInstallation
    }
  }
  // Accessed only by the adapter queue.
  var listeners: [AudioHardwareListener] = []
}

@MainActor public final class AudioModeAdapter {
  private let worker: SerialAudioWorker
  private var lifetime: AudioDeliveryLifetime?

  public convenience init() { self.init(hardware: HALAudioHardware()) }

  public convenience init(hardware: any AudioHardware) {
    let queue = DispatchQueue(label: "io.github.bernalli.monopods.audio")
    self.init(hardware: hardware, queue: queue, scheduler: DispatchAudioScheduler(queue: queue))
  }

  init(
    hardware: any AudioHardware, queue: DispatchQueue, scheduler: any AudioAdapterScheduler,
    writeAllowed: @escaping @Sendable (WriterCommand) -> Bool = { _ in true }
  ) {
    worker = SerialAudioWorker(
      hardware: hardware, queue: queue, scheduler: scheduler,
      writeAllowed: writeAllowed)
  }

  public func start(observe: @escaping @MainActor @Sendable (AudioReading) -> Void) {
    lifetime?.invalidate()
    let lifetime = AudioDeliveryLifetime()
    self.lifetime = lifetime
    worker.queue.async { [worker] in worker.start(lifetime: lifetime, observe: observe) }
  }

  public func refresh(rearm: Bool) {
    worker.queue.async { [worker] in worker.refresh(rearm: rearm) }
  }

  public func stop() {
    lifetime?.invalidate()
    lifetime = nil
    worker.queue.async { [worker] in worker.stop() }
  }

  public func apply(
    _ command: WriterCommand, files: AtomicRuntimeFiles, owner: InstanceLock,
    completion: @escaping @MainActor @Sendable (AudioWriteResult) -> Void
  ) {
    worker.queue.async { [worker] in
      let result = worker.apply(command, files: files, owner: owner)
      DispatchQueue.main.async { completion(result) }
    }
  }

  deinit {
    lifetime?.invalidate()
    worker.queue.async { [worker] in worker.stop() }
  }
}

/// HAL, command persistence and listener processing share this serial queue.
private final class SerialAudioWorker: @unchecked Sendable {
  let queue: DispatchQueue
  private let hardware: any AudioHardware
  private let scheduler: any AudioAdapterScheduler
  private let writeAllowed: @Sendable (WriterCommand) -> Bool
  private var lifetime: AudioDeliveryLifetime?
  private var observe: (@MainActor @Sendable (AudioReading) -> Void)?
  private var registration: AudioRegistration?
  private var listenerStatus: Int32 = 0
  private var nextGeneration: UInt64 = 1

  init(
    hardware: any AudioHardware, queue: DispatchQueue, scheduler: any AudioAdapterScheduler,
    writeAllowed: @escaping @Sendable (WriterCommand) -> Bool
  ) {
    self.writeAllowed = writeAllowed
    self.hardware = hardware
    self.queue = queue
    self.scheduler = scheduler
  }

  func start(
    lifetime: AudioDeliveryLifetime,
    observe: @escaping @MainActor @Sendable (AudioReading) -> Void
  ) {
    removeListeners()
    self.lifetime = lifetime
    self.observe = observe
    guard lifetime.isActive else { return }
    rearm()
    publish()
  }

  func refresh(rearm shouldRearm: Bool) {
    guard lifetime?.isActive == true else { return }
    if shouldRearm { rearm() }
    publish()
  }

  func stop() {
    removeListeners()
    observe = nil
    lifetime = nil
  }

  private func removeListeners() {
    let previous = registration
    registration = nil
    for listener in previous?.listeners ?? [] { _ = hardware.removeListener(listener) }
  }

  private func rearm() {
    // A service reset can discard either listener even when removal reports an error.
    removeListeners()
    listenerStatus = 0
    // Retry one interrupted installation. Repeated resets leave a diagnostic error
    // until the next external rearm, rather than spinning on inline callbacks.
    for _ in 0..<2 {
      if installListeners() { return }
      removeListeners()
      if listenerStatus != 0 { return }
    }
    listenerStatus = kAudioHardwareUnspecifiedError
  }

  private func installListeners() -> Bool {
    let registration = AudioRegistration()
    self.registration = registration
    // Observe resets before installing a mode listener that they could invalidate.
    for property: AudioHardwareProperty in [.serviceRestarted, .mode] {
      let listener = AudioHardwareListener(property: property) { [weak self, weak registration] in
        guard let self, let registration else { return }
        let duringInstallation = property == .serviceRestarted && registration.noteRestart()
        self.queue.async { [self, registration] in
          guard self.registration === registration, self.lifetime?.isActive == true else { return }
          if property == .serviceRestarted {
            // Installation handles resets recorded before its completion atomically.
            guard !duringInstallation else { return }
            self.rearm()
            self.publish()
          } else {
            self.publish()
            let lifetime = self.lifetime
            self.scheduler.after(1) { [weak self] in
              guard let self else { return }
              self.queue.async {
                guard self.lifetime === lifetime, lifetime?.isActive == true else { return }
                self.publish()
              }
            }
          }
        }
      }
      registration.listeners.append(listener)
      let status = hardware.addListener(listener)
      if status != 0 {
        listenerStatus = status
        return false
      }
    }
    return registration.finishInstallation()
  }

  private func readMode() -> (Target?, Int32) {
    let check = hardware.hasMode()
    guard check.status == 0 else { return (nil, check.status) }
    guard check.value else { return (nil, kAudioHardwareUnknownPropertyError) }
    return checked(hardware.readMode())
  }

  private func checked(_ reading: AudioHardwareReading) -> (Target?, Int32) {
    guard reading.status == 0 else { return (nil, reading.status) }
    guard reading.byteCount == MemoryLayout<UInt32>.size else {
      return (nil, kAudioHardwareBadPropertySizeError)
    }
    return (reading.rawValue == 0 ? .stereo : .mono, 0)
  }

  private func publish(systemMono: SystemMono? = nil) {
    guard let lifetime, lifetime.isActive, let observe, nextGeneration > 0 else { return }
    let systemMono = systemMono ?? hardware.readSystemMono()
    let (mode, status) = readMode()
    let reading = AudioReading(
      generation: nextGeneration, mode: listenerStatus == 0 ? mode : nil,
      status: listenerStatus == 0 ? status : listenerStatus, systemMono: systemMono)
    nextGeneration = nextGeneration == UInt64.max ? 0 : nextGeneration + 1
    DispatchQueue.main.async {
      guard lifetime.isActive else { return }
      observe(reading)
    }
  }

  func apply(_ command: WriterCommand, files: AtomicRuntimeFiles, owner: InstanceLock)
    -> AudioWriteResult
  {
    guard lifetime?.isActive == true else {
      return .completed(
        WriterReceipt(command: command, exitCode: -1, quiescent: false, persisted: false))
    }
    if hardware.readSystemMono() == .on {
      publish(systemMono: .on)
      return .systemMono(command)
    }
    let invoke: (Target) -> AudioInvocationResult = { [self] target in
      let property = hardware.hasMode()
      guard property.status == 0 else { return .completed(property.status) }
      guard property.value else { return .completed(kAudioHardwareUnknownPropertyError) }
      let settable = hardware.modeIsSettable()
      guard settable.status == 0 else { return .completed(settable.status) }
      guard settable.value else { return .completed(kAudioHardwareIllegalOperationError) }
      let (_, status) = checked(hardware.readMode())
      guard status == 0 else { return .completed(status) }
      // Running is durable now. Recheck the preference immediately before the set.
      guard hardware.readSystemMono() != .on else { return .systemMono }
      guard writeAllowed(command) else { return .completed(kAudioHardwareIllegalOperationError) }
      let setStatus = hardware.setMode(target == .mono ? 1 : 0)
      let (mode, getStatus) = checked(hardware.readMode())
      if setStatus != 0 { return .completed(setStatus) }
      if getStatus != 0 { return .completed(getStatus) }
      return .completed(mode == target ? 0 : kAudioHardwareUnspecifiedError)
    }
    let result = DurableWriter.executeAudio(
      command: command, files: files, owner: owner, invoke: invoke)
    if case .systemMono = result { publish(systemMono: .on) }
    return result
  }
}

/// The only implementation that calls Core Audio. Construction performs no HAL access.
private final class HALAudioHardware: AudioHardware, @unchecked Sendable {
  private let object = AudioObjectID(kAudioObjectSystemObject)
  private var blocks: [ObjectIdentifier: AudioObjectPropertyListenerBlock] = [:]

  private func address(_ property: AudioHardwareProperty = .mode) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: property == .mode
        ? kAudioHardwarePropertyMixStereoToMono : kAudioHardwarePropertyServiceRestarted,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }

  func hasMode() -> AudioPropertyCheck {
    var address = address()
    return AudioPropertyCheck(status: 0, value: AudioObjectHasProperty(object, &address))
  }

  func modeIsSettable() -> AudioPropertyCheck {
    var address = address()
    var settable = DarwinBoolean(false)
    let status = AudioObjectIsPropertySettable(object, &address, &settable)
    return AudioPropertyCheck(status: status, value: settable.boolValue)
  }

  func readMode() -> AudioHardwareReading {
    var address = address()
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard sizeStatus == 0 else {
      return AudioHardwareReading(status: sizeStatus, rawValue: 0, byteCount: size)
    }
    guard size == MemoryLayout<UInt32>.size else {
      return AudioHardwareReading(
        status: kAudioHardwareBadPropertySizeError, rawValue: 0, byteCount: size)
    }
    var value: UInt32 = 0
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return AudioHardwareReading(
      status: status == 0 && size != MemoryLayout<UInt32>.size
        ? kAudioHardwareBadPropertySizeError : status,
      rawValue: value, byteCount: size)
  }

  func setMode(_ value: UInt32) -> Int32 {
    var address = address()
    var value = value
    return AudioObjectSetPropertyData(
      object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  }

  func readSystemMono() -> SystemMono {
    let domain = "com.apple.universalaccess" as CFString
    let synchronized = CFPreferencesSynchronize(
      domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    guard synchronized else { return .unreadable }
    let value = CFPreferencesCopyValue(
      "stereoAsMono" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return SystemMonoPreference.decode(value, synchronized: synchronized)
  }

  func addListener(_ listener: AudioHardwareListener) -> Int32 {
    var address = address(listener.property)
    let block: AudioObjectPropertyListenerBlock = { _, _ in listener.callback() }
    let status = AudioObjectAddPropertyListenerBlock(object, &address, nil, block)
    if status == 0 { blocks[ObjectIdentifier(listener)] = block }
    return status
  }

  func removeListener(_ listener: AudioHardwareListener) -> Int32 {
    guard let block = blocks.removeValue(forKey: ObjectIdentifier(listener)) else { return 0 }
    var address = address(listener.property)
    return AudioObjectRemovePropertyListenerBlock(object, &address, nil, block)
  }
}

extension AudioModeAdapter {
  /// The existing isolated bundle gate selects a backend incapable of reaching HAL.
  static func runtime(
    isolated: Bool, writeAllowed: @escaping @Sendable (WriterCommand) -> Bool = { _ in true }
  )
    -> AudioModeAdapter
  {
    let queue = DispatchQueue(label: "io.github.bernalli.monopods.audio")
    return AudioModeAdapter(
      hardware: isolated ? InertAudioHardware() : HALAudioHardware(),
      queue: queue, scheduler: DispatchAudioScheduler(queue: queue),
      writeAllowed: writeAllowed)
  }
  public static func checkReadiness() async -> Bool {
    await checkReadiness(hardware: HALAudioHardware())
  }
  static func checkReadiness(hardware: any AudioHardware) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let property = hardware.hasMode()
        let settable = hardware.modeIsSettable()
        let reading = hardware.readMode()
        continuation.resume(
          returning: property.status == 0 && property.value
            && settable.status == 0 && settable.value && reading.status == 0
            && reading.byteCount == MemoryLayout<UInt32>.size)
      }
    }
  }
}

/// Used only for copies that may not reach real audio, never as a product mode. It reports the
/// system override, so the engine attempts no write and Quit closes cleanly without a Stereo set.
struct InertAudioHardware: AudioHardware {
  func hasMode() -> AudioPropertyCheck { AudioPropertyCheck(status: 0, value: false) }
  func modeIsSettable() -> AudioPropertyCheck { AudioPropertyCheck(status: 0, value: false) }
  func readMode() -> AudioHardwareReading {
    AudioHardwareReading(status: kAudioHardwareUnknownPropertyError, rawValue: 0, byteCount: 0)
  }
  func readSystemMono() -> SystemMono { .on }
  func setMode(_ value: UInt32) -> Int32 { kAudioHardwareIllegalOperationError }
  func addListener(_ listener: AudioHardwareListener) -> Int32 { 0 }
  func removeListener(_ listener: AudioHardwareListener) -> Int32 { 0 }
}

struct AudioDiagnosticReading: Sendable {
  let status: Int32
  let rawValue: UInt32?
  let mode: Target?
  let systemMono: SystemMono
}

extension AudioModeAdapter {
  static func diagnostics() async -> AudioDiagnosticReading {
    await diagnostics(hardware: HALAudioHardware())
  }

  /// A single read on a worker queue; no listeners, owner lock, journal or set operation.
  static func diagnostics(hardware: any AudioHardware) async -> AudioDiagnosticReading {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let property = hardware.hasMode()
        let settable = hardware.modeIsSettable()
        let reading = hardware.readMode()
        let preference = hardware.readSystemMono()
        let status: Int32
        if property.status != 0 {
          status = property.status
        } else if !property.value {
          status = kAudioHardwareUnknownPropertyError
        } else if settable.status != 0 {
          status = settable.status
        } else if !settable.value {
          status = kAudioHardwareIllegalOperationError
        } else if reading.status != 0 {
          status = reading.status
        } else if reading.byteCount != MemoryLayout<UInt32>.size {
          status = kAudioHardwareBadPropertySizeError
        } else {
          status = 0
        }
        continuation.resume(
          returning: AudioDiagnosticReading(
            status: status, rawValue: status == 0 ? reading.rawValue : nil,
            mode: status == 0 ? (reading.rawValue == 0 ? .stereo : .mono) : nil,
            systemMono: preference))
      }
    }
  }
}
