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

@MainActor @Test func serviceRestartRearmsRouteListenerAndRestoresRoute() async throws {
  let now = Instant(continuousNanos: 0, utc: try SourceTime("2026-01-01T00:00:00Z"))
  var inputs: [EngineInput] = []
  let driver = ObservationDriver(clock: { now }, submit: { inputs.append($0) })
  var registrationSucceeds = false
  var routeAdds = 0
  var routeRemoves = 0
  var restartAdds = 0
  var restartRemoves = 0
  var restartCallbacks: [AudioObjectPropertyListenerBlock] = []
  let access = RouteObservationAccess(
    add: { _ in
      routeAdds += 1
      return registrationSucceeds
    },
    remove: { _ in routeRemoves += 1 },
    addServiceRestart: { block in
      restartCallbacks.append(block)
      restartAdds += 1
      return true
    },
    removeServiceRestart: { _ in restartRemoves += 1 },
    read: {
      ObservedSystemRoute(
        identity: "00:11:22:33:44:55", name: "Test AirPods", productID: NSNumber(value: 0x2014),
        device: nil)
    })
  var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyServiceRestarted,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  let observations = SystemObservations(driver: driver, routeAccess: access, submit: { _ in })
  observations.startRouteObservation()
  #expect(routeAdds == 1 && restartAdds == 1 && observations.routeName == nil)
  let firstRestartCallback = try #require(restartCallbacks.first)
  // After coreaudiod restarts, the HAL restart callback replaces stale listeners and restores route.
  registrationSucceeds = true
  firstRestartCallback(1, &address)
  for _ in 0..<20 where routeAdds < 2 { await Task.yield() }
  #expect(routeAdds == 2 && routeRemoves == 0 && restartAdds == 2 && restartRemoves == 1)
  #expect(observations.routeName == "Test AirPods")
  #expect(observations.routeModel?.name == "AirPods Pro 2")
  // A stale callback from the replaced generation must not tear down fresh listeners.
  firstRestartCallback(1, &address)
  for _ in 0..<5 { await Task.yield() }
  #expect(routeAdds == 2 && routeRemoves == 0 && restartAdds == 2 && restartRemoves == 1)
  // A second reset from the current callback removes both active listeners before re-adding.
  let secondRestartCallback = try #require(restartCallbacks.last)
  secondRestartCallback(1, &address)
  for _ in 0..<20 where routeAdds < 3 { await Task.yield() }
  #expect(routeAdds == 3 && routeRemoves == 1 && restartAdds == 3 && restartRemoves == 2)
  // A callback queued right before stop() must not resurrect listeners after stop().
  let thirdRestartCallback = try #require(restartCallbacks.last)
  thirdRestartCallback(1, &address)
  observations.stop()
  for _ in 0..<5 { await Task.yield() }
  #expect(routeAdds == 3 && routeRemoves == 2 && restartAdds == 3 && restartRemoves == 3)
  #expect(observations.routeName == nil)
  #expect(inputs.last == .route(nil))
}
