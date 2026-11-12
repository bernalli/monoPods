import CoreAudio
import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

@MainActor @Test func failedRouteListenerStaysUnavailableUntilObservationsRestart() throws {
  let now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:00Z"))
  var inputs: [EngineInput] = []
  let driver = ObservationDriver(clock: { now }, submit: { inputs.append($0) })
  var registrationSucceeds = false
  var registrations = 0
  var removals = 0
  var reads = 0
  var callback: AudioObjectPropertyListenerBlock?
  let access = RouteObservationAccess(
    add: { block in
      callback = block
      registrations += 1
      return registrationSucceeds
    },
    remove: { _ in removals += 1 },
    read: {
      reads += 1
      return ObservedSystemRoute(
        identity: "00:11:22:33:44:55", name: "Test AirPods", productID: NSNumber(value: 123),
        device: nil)
    })
  let observations = SystemObservations(driver: driver, routeAccess: access, submit: { _ in })
  // A previously known route must be revoked as soon as registration fails.
  observations.updateRoute(identity: "00:11:22:33:44:55", name: "Old", productID: 123)
  observations.startRouteObservation()
  #expect(inputs.last == .route(nil))
  #expect(observations.routeName == nil)
  #expect(reads == 0)
  registrationSucceeds = true
  for _ in 0..<5 { observations.refreshRoute() }
  observations.startRouteObservation()
  #expect(registrations == 1)
  #expect(reads == 0)
  observations.stop()
  #expect(removals == 0)
  observations.startRouteObservation()
  #expect(registrations == 2)
  #expect(reads == 1)
  #expect(observations.routeName == "Test AirPods")
  observations.stop()
  #expect(removals == 1)
  observations.refreshRoute()
  #expect(observations.routeName == nil)
  #expect(reads == 1)
  #expect(callback != nil)
}
