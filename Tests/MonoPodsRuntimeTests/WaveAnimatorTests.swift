import Foundation
import MonoPodsCore
import Testing

@testable import MonoPodsRuntime

/// Holds scheduled one-shot calls until the test fires them; no real time passes.
@MainActor final class ManualSchedule {
  private(set) var delays: [UInt64] = []
  private(set) var cancelled = 0
  private var pending: [(id: Int, fire: @MainActor @Sendable () -> Void)] = []
  private var nextID = 0
  var count: Int { pending.count }
  var schedule: OneShotSchedule {
    { [unowned self] delay, fire in
      self.nextID += 1
      let id = self.nextID
      self.delays.append(delay)
      self.pending.append((id, fire))
      return { [unowned self] in
        if self.pending.contains(where: { $0.id == id }) { self.cancelled += 1 }
        self.pending.removeAll { $0.id == id }
      }
    }
  }
  /// Fires the oldest pending call and returns false when none is pending.
  @discardableResult func fireNext() -> Bool {
    guard !pending.isEmpty else { return false }
    pending.removeFirst().fire()
    return true
  }
  /// Takes the pending calls without firing them, to fire them later as stale calls.
  func takeAll() -> [@MainActor @Sendable () -> Void] {
    defer { pending.removeAll() }
    return pending.map(\.fire)
  }
}

@MainActor @Test func waveRunsOnceAndEndsOnTheRestingFrame() {
  let clock = ManualSchedule()
  let wave = WaveAnimator(schedule: clock.schedule)
  var frames: [Int] = []
  wave.onFrame = { frames.append($0) }
  wave.start()
  while clock.fireNext() {}
  #expect(frames == Array(0...StereoRipple.restingFrame))
  #expect(wave.frame == StereoRipple.restingFrame && !wave.running)
  #expect(clock.count == 0)
  #expect(
    clock.delays
      == Array(repeating: StereoRipple.frameIntervalNanos, count: StereoRipple.restingFrame))
  let total = clock.delays.reduce(0, +)
  #expect(total >= 1_400_000_000 && total <= 1_600_000_000)
}

@MainActor @Test func stoppedWaveShowsNoFurtherFrame() {
  let clock = ManualSchedule()
  let wave = WaveAnimator(schedule: clock.schedule)
  var frames: [Int] = []
  wave.onFrame = { frames.append($0) }
  wave.start()
  for _ in 0..<3 { clock.fireNext() }
  let stale = clock.takeAll()
  wave.stop()
  for fire in stale { fire() }
  #expect(frames == [0, 1, 2, 3])
  #expect(clock.count == 0 && !wave.running)
}

@MainActor @Test func restartDropsTheStepOfThePreviousRun() {
  let clock = ManualSchedule()
  let wave = WaveAnimator(schedule: clock.schedule)
  var frames: [Int] = []
  wave.onFrame = { frames.append($0) }
  wave.start()
  clock.fireNext()
  wave.start()
  #expect(clock.cancelled == 1 && clock.count == 1)
  while clock.fireNext() {}
  #expect(frames == [0, 1] + Array(0...StereoRipple.restingFrame))
}

@MainActor @Test func hostRunsTheWaveWhenTheGlyphTurnsStereoAndStopsOnChange() {
  let clock = ManualSchedule()
  let host = RuntimeHost(waveSchedule: clock.schedule)
  var mono = Engine(build: testBuild, run: 1, boot: "boot").snapshot
  mono.lastCompleted = CommandReceipt(id: 1, target: .mono, exitCode: 0)
  var stereo = mono
  stereo.lastCompleted = CommandReceipt(id: 2, target: .stereo, exitCode: 0)
  host.publish(snapshot: mono, routeName: "Route", routeModel: nil)
  #expect(clock.count == 0)
  host.publish(snapshot: stereo, routeName: "Route", routeModel: nil)
  #expect(host.glyph == .stereo && host.waveFrame == 0 && clock.count == 1)
  // A repeated Stereo pulse neither restarts nor speeds up the wave.
  host.publish(snapshot: stereo, routeName: "Route", routeModel: nil)
  #expect(host.waveFrame == 0 && clock.count == 1)
  while clock.fireNext() {}
  #expect(host.waveFrame == StereoRipple.restingFrame)
  host.publish(snapshot: stereo, routeName: "Route", routeModel: nil)
  #expect(clock.count == 0)
  // Back to Mono during a new run: no frame arrives after the glyph change.
  host.publish(snapshot: mono, routeName: "Route", routeModel: nil)
  host.publish(snapshot: stereo, routeName: "Route", routeModel: nil)
  clock.fireNext()
  #expect(host.waveFrame == 1)
  let stale = clock.takeAll()
  host.publish(snapshot: mono, routeName: "Route", routeModel: nil)
  for fire in stale { fire() }
  #expect(host.glyph == .mono(.left) && host.waveFrame == 1 && clock.count == 0)
}

@Test func rippleRunsAtTwelveFramesPerSecondAndRestsOnTheLastFrame() {
  #expect(StereoRipple.frameIntervalNanos == 83_333_333)
  #expect(StereoRipple.frameCount == 19)
  #expect(StereoRipple.restingFrame == 18)
}

@Test(arguments: [-1, 16, 17, 18, 99]) func noRingOutsideTheVisibleRun(frame: Int) {
  #expect(StereoRipple.ring(frame: frame) == nil)
}

@Test func ringIsPresentOnTheFirstAndLastVisibleFrames() {
  #expect(StereoRipple.ring(frame: 0) != nil)
  #expect(StereoRipple.ring(frame: 15) != nil)
}

@Test func ringGrowsOnEveryVisibleFrame() {
  let growth = (0...15).compactMap { StereoRipple.ring(frame: $0)?.growth }
  #expect(growth.count == 16)
  #expect(zip(growth, growth.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func ringOpacityStartsAtZeroAndStaysUnderThePeak() {
  #expect(StereoRipple.ring(frame: 0)?.opacity == 0)
  let opacity = (0...15).compactMap { StereoRipple.ring(frame: $0)?.opacity }
  #expect(opacity.count == 16)
  #expect(opacity.allSatisfy { (0...0.9).contains($0) })
}

/// Expected ripple curves written out independently to catch changes to production constants.
@Test func ringValuesFollowTheApprovedCurves() throws {
  for frame in 0...15 {
    let ring = try #require(StereoRipple.ring(frame: frame))
    let progress = Double(frame) * 0.083_333_333 / 1.3
    let fadeIn = min(progress / 0.15, 1)
    #expect(abs(ring.growth - (1 - pow(1 - progress, 2.4))) < 1e-9)
    let opacity = 0.9 * fadeIn * fadeIn * (3 - 2 * fadeIn) * pow(1 - progress, 1.4)
    #expect(abs(ring.opacity - opacity) < 1e-9)
  }
}
