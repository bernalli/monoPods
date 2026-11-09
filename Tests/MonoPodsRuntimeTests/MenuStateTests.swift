import Combine
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

/// Counts objectWillChange emissions of a host while `body` runs.
@MainActor private func emissions(of host: RuntimeHost, during body: () -> Void) -> Int {
  var total = 0
  let subscription = host.objectWillChange.sink { total += 1 }
  body()
  subscription.cancel()
  return total
}

@MainActor @Test func unchangedMenuVisibilityDoesNotPublish() {
  let host = RuntimeHost()
  #expect(emissions(of: host) { host.setMenuVisible(host.menuVisible) } == 0)
  #expect(emissions(of: host) { host.setMenuVisible(!host.menuVisible) } == 1)
}

@MainActor @Test func unchangedAutomationDoesNotPublish() {
  let host = RuntimeHost()
  #expect(emissions(of: host) { host.setAutomation(host.automation) } == 0)
  #expect(emissions(of: host) { host.setAutomation(!host.automation) } == 1)
}

@MainActor @Test func repeatedPulseStateDoesNotPublish() {
  let host = RuntimeHost()
  let base = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  host.publish(snapshot: base, routeName: "Route", routeModel: nil)
  #expect(
    emissions(of: host) { host.publish(snapshot: base, routeName: "Route", routeModel: nil) } == 0)
  var changed = base
  changed.count = (base.count ?? 0) + 1
  #expect(
    emissions(of: host) { host.publish(snapshot: changed, routeName: "Route", routeModel: nil) } > 0
  )
  #expect(host.count == String((base.count ?? 0) + 1))
  #expect(
    emissions(of: host) { host.publish(snapshot: changed, routeName: "Other", routeModel: nil) } > 0
  )
  #expect(host.routeName == "Other")
}

@MainActor @Test func glyphFollowsPublishedSnapshot() {
  let host = RuntimeHost()
  #expect(host.glyph == .idle)
  var mono = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  mono.lastCompleted = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  host.publish(snapshot: mono, routeName: "Route", routeModel: nil)
  #expect(host.glyph == .mono(.left))
  #expect(
    emissions(of: host) { host.publish(snapshot: mono, routeName: "Route", routeModel: nil) } == 0)
  var stereo = mono
  stereo.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 0)
  host.publish(snapshot: stereo, routeName: "Route", routeModel: nil)
  #expect(host.glyph == .stereo)
  var blocked = stereo
  blocked.blocked = true
  host.publish(snapshot: blocked, routeName: "Route", routeModel: nil)
  #expect(host.glyph == .attention)
}

@MainActor @Test func monoGlyphFollowsTheLastEarSide() {
  let host = RuntimeHost()
  var mono = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  mono.lastCompleted = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  host.earSide = .right
  host.publish(snapshot: mono, routeName: "Route", routeModel: nil)
  #expect(host.glyph == .mono(.right))
  host.earSide = nil
  host.publish(snapshot: mono, routeName: "Route", routeModel: nil)
  #expect(host.glyph == .mono(.left))
  host.earSide = .right
  var stereo = mono
  stereo.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 0)
  host.publish(snapshot: stereo, routeName: "Route", routeModel: nil)
  #expect(host.glyph == .stereo)
}

@MainActor @Test func routeModelIsPublishedBesideTheRouteName() throws {
  let host = RuntimeHost()
  #expect(host.routeModel == nil)
  let base = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  let pro = AirPodsModel.model(productID: 0x2014)
  host.publish(snapshot: base, routeName: "Route", routeModel: pro)
  #expect(host.routeModel == pro)
  #expect(
    emissions(of: host) { host.publish(snapshot: base, routeName: "Route", routeModel: pro) } == 0)
  let max = AirPodsModel.model(productID: 0x200A)
  #expect(
    emissions(of: host) { host.publish(snapshot: base, routeName: "Route", routeModel: max) } > 0)
  #expect(host.routeModel == max)
  host.publish(snapshot: base, routeName: "No Bluetooth output", routeModel: nil)
  #expect(host.routeModel == nil)

  let now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:00Z"))
  let driver = ObservationDriver(clock: { now }, submit: { _ in })
  let observations = SystemObservations(driver: driver, submit: { _ in })
  let address = "00:11:22:33:44:55"
  let candidates: [Any?] =
    AirPodsModel.known.map { $0.productID as Any? }
    + [0x2028, nil, true, false, 8194.5, -1, 65536, Double.nan, Double.infinity, "8194"]
  for previous in AirPodsModel.known {
    for product in candidates {
      observations.updateRoute(identity: address, name: "Route", productID: previous.productID)
      #expect(observations.routeModel == previous)
      let identity = RouteIdentity.resolve(
        uid: address, address: address, connected: true, paired: true,
        bluetoothTransport: true, productID: product)
      for _ in 0..<2 {
        observations.updateRoute(identity: identity, name: "Route", productID: product)
        #expect(observations.routeName == (identity == nil ? nil : "Route"))
        #expect(
          observations.routeModel
            == (identity == nil ? nil : AirPodsModel.model(productID: product)))
        host.publish(
          snapshot: base, routeName: observations.routeName ?? "No Bluetooth output",
          routeModel: observations.routeModel)
        #expect(host.routeModel == observations.routeModel)
      }
    }
    observations.updateRoute(identity: address, name: "Route", productID: previous.productID)
    observations.updateRoute(identity: nil, name: "Route", productID: previous.productID)
    #expect(observations.routeName == nil && observations.routeModel == nil)
    observations.updateRoute(identity: address, name: "Route", productID: previous.productID)
    for _ in 0..<2 {
      observations.clearRoute()
      #expect(observations.routeName == nil && observations.routeModel == nil)
    }
  }
}
