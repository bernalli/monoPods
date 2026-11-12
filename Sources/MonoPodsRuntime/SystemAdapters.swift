import AppKit
import CoreAudio
@preconcurrency import CoreBluetooth
import Darwin
import IOBluetooth
import MonoPodsCore
import OSLog

public enum SystemClock {
  public static func now() -> Instant {
    var utc = timespec()
    clock_gettime(CLOCK_REALTIME, &utc)
    var parts = tm()
    var seconds = utc.tv_sec
    gmtime_r(&seconds, &parts)
    let text = String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%09ldZ", parts.tm_year + 1900, parts.tm_mon + 1,
      parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, utc.tv_nsec)
    var scale = mach_timebase_info_data_t()
    mach_timebase_info(&scale)
    let ticks = mach_continuous_time()
    let nanos =
      ticks / UInt64(scale.denom) * UInt64(scale.numer)
      + ticks % UInt64(scale.denom) * UInt64(scale.numer) / UInt64(scale.denom)
    // Generated numeric UTC is always valid; a clock outside SourceTime's supported range is fatal.
    guard let sourceTime = try? SourceTime(text) else { fatalError("Unsupported system clock") }
    return Instant(continuousNanos: nanos, utc: sourceTime)
  }
  public static func bootUUID() throws -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size <= 128
    else { throw RuntimeError.invalid }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
      throw RuntimeError.invalid
    }
    let value = String(
      bytes: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    guard let value, ContractValidation.uuid(value) else { throw RuntimeError.invalid }
    return value
  }
}

struct ObservedSystemRoute {
  let identity: String?
  let name: String?
  let productID: Any?
  let device: IOBluetoothDevice?
}

@MainActor struct RouteObservationAccess {
  var add: (@escaping AudioObjectPropertyListenerBlock) -> Bool
  var remove: (@escaping AudioObjectPropertyListenerBlock) -> Void
  var read: () -> ObservedSystemRoute?

  static var live: Self {
    Self(
      add: { block in
        var property = outputProperty
        return AudioObjectAddPropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &property, .main, block) == noErr
      },
      remove: { block in
        var property = outputProperty
        AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &property, .main, block)
      }, read: readSystemRoute)
  }
  private static var outputProperty: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }
  private static func readSystemRoute() -> ObservedSystemRoute? {
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var property = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &deviceID) == noErr
    else {
      return nil
    }
    var reference: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    property.mSelector = kAudioDevicePropertyDeviceUID
    guard AudioObjectGetPropertyData(deviceID, &property, 0, nil, &size, &reference) == noErr,
      let reference
    else {
      return nil
    }
    let uid = reference.takeRetainedValue()
    property.mSelector = kAudioDevicePropertyTransportType
    var transport: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &property, 0, nil, &size, &transport) == noErr,
      let candidate = RouteIdentity.uidAddress(uid as String),
      let device = IOBluetoothDevice(
        addressString: candidate.replacingOccurrences(of: ":", with: "-"))
    else {
      return nil
    }
    let selector = NSSelectorFromString("productID")
    let product = device.responds(to: selector) ? device.value(forKey: "productID") : nil
    let identity = RouteIdentity.resolve(
      uid: uid as String, address: device.addressString, connected: device.isConnected(),
      paired: device.isPaired(),
      bluetoothTransport: transport == kAudioDeviceTransportTypeBluetooth, productID: product)
    return ObservedSystemRoute(
      identity: identity, name: device.name, productID: product, device: device)
  }
}

@MainActor public final class SystemObservations: NSObject, @preconcurrency CBCentralManagerDelegate
{
  private let driver: ObservationDriver
  private let submit: (EngineInput) -> Void
  private let requestQuit: () -> Void
  private var central: CBCentralManager?
  private var connectionToken: IOBluetoothUserNotification?
  private var disconnectToken: IOBluetoothUserNotification?
  private var tokens: [NSObjectProtocol] = []
  private var listener: AudioObjectPropertyListenerBlock?
  private let routeAccess: RouteObservationAccess
  private var routeListenerReady = false
  private var awake = true
  public private(set) var routeName: String?
  public private(set) var routeModel: AirPodsModel?
  private let heartbeat = Logger(subsystem: "io.github.bernalli.monopods", category: "heartbeat")
  public init(
    driver: ObservationDriver, requestQuit: @escaping () -> Void = {},
    submit: @escaping (EngineInput) -> Void
  ) {
    self.driver = driver
    self.submit = submit
    self.requestQuit = requestQuit
    self.routeAccess = .live
  }
  init(
    driver: ObservationDriver, routeAccess: RouteObservationAccess,
    submit: @escaping (EngineInput) -> Void
  ) {
    self.driver = driver
    self.submit = submit
    self.requestQuit = {}
    self.routeAccess = routeAccess
  }
  public func start() {
    central = CBCentralManager(
      delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    connectionToken = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(connected(_:device:)))
    let center = NSWorkspace.shared.notificationCenter
    for (name, sleeping) in [
      (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
    ] {
      tokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in
            guard let self else { return }
            self.awake = !sleeping
            self.environment()
            self.refreshRoute()
          }
        })
    }
    let powerOff: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in self?.requestQuit() }
    }
    tokens.append(
      center.addObserver(
        forName: NSWorkspace.willPowerOffNotification,
        object: nil, queue: .main, using: powerOff))
    startRouteObservation()
  }
  func startRouteObservation() {
    guard listener == nil else { return }
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor in self?.refreshRoute() }
    }
    listener = block
    routeListenerReady = routeAccess.add(block)
    refreshRoute()
  }
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    environment()
    refreshRoute()
  }
  private func environment() {
    submit(.environment(awake: awake, bluetooth: central?.state == .poweredOn))
  }
  @objc private func connected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    refreshRoute()
    if let address = device.addressString {
      driver.connected(address: address, at: SystemClock.now().utc)
    }
  }
  @objc private func disconnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) { refreshRoute() }
  public func refreshRoute() {
    guard routeListenerReady else {
      clearRoute()
      return
    }
    guard let route = routeAccess.read() else {
      clearRoute()
      return
    }
    let identity = route.identity
    updateRoute(identity: identity, name: route.name, productID: route.productID)
    disconnectToken?.unregister()
    disconnectToken =
      identity == nil
      ? nil
      : route.device?.register(
        forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
  }
  // Display only: the caller resolves identity without looking at the model.
  func updateRoute(identity: String?, name: String?, productID: Any?) {
    routeName = identity == nil ? nil : name
    routeModel = identity == nil ? nil : AirPodsModel.model(productID: productID)
    driver.route(address: identity)
  }
  func clearRoute() {
    updateRoute(identity: nil, name: nil, productID: nil)
  }
  public func emit(nonce: String, sequence: UInt64) {
    heartbeat.notice("HEARTBEAT \(nonce, privacy: .public) \(sequence, privacy: .public)")
  }
  public func stop() {
    let wasReady = routeListenerReady
    routeListenerReady = false
    clearRoute()
    central = nil
    connectionToken?.unregister()
    connectionToken = nil
    disconnectToken?.unregister()
    disconnectToken = nil
    let center = NSWorkspace.shared.notificationCenter
    for token in tokens { center.removeObserver(token) }
    tokens.removeAll()
    if wasReady, let listener { routeAccess.remove(listener) }
    listener = nil
  }
}
