import Foundation
import MediaPlayer
import Testing

@testable import MonoPodsRuntime

private typealias CommandDescription = @convention(c) (UInt32) -> Unmanaged<CFString>?

/// The framework names its own command values. Reading a name sends no command.
private func frameworkName(of command: UInt32) throws -> String {
  let handle = try #require(
    dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY))
  let symbol = try #require(dlsym(handle, "MRMediaRemoteCopyCommandDescription"))
  let describe = unsafeBitCast(symbol, to: CommandDescription.self)
  let name = try #require(describe(command))
  return name.takeRetainedValue() as String
}
@Test func mediaCommandsAreTheFrameworkValues() throws {
  #expect(try frameworkName(of: MediaCommand.play) == "Play")
  #expect(try frameworkName(of: MediaCommand.pause) == "Pause")
}

nonisolated(unsafe) private var sentCommands: [UInt32] = []

@MainActor @Test func theAdapterSendsEachCommandWithItsValue() {
  let adapter = MediaAdapter()
  sentCommands = []
  // No symbol resolved: nothing can be sent.
  #expect(!adapter.pause())
  adapter.send = { command, _ in
    sentCommands.append(command)
    return true
  }
  #expect(adapter.pause())
  #expect(adapter.play())
  #expect(sentCommands == [MediaCommand.pause, MediaCommand.play])
}

@MainActor @Test func mediaMetadataUsesTheVisibleApplicationNameWithoutStartingAudio() {
  #expect(MediaAdapter.nowPlayingMetadata[MPMediaItemPropertyTitle] as? String == "MonoPods")
  #expect(MediaAdapter.nowPlayingMetadata[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
}

@MainActor private final class ManualRetrySchedule {
  var pending: (@MainActor () -> Void)?
  var scheduledDelays: [UInt64] = []
  var cancellations = 0
  func schedule(
    _ delayNanos: UInt64, _ fire: @escaping @MainActor @Sendable () -> Void
  ) -> (@MainActor () -> Void) {
    scheduledDelays.append(delayNanos)
    pending = fire
    return { [weak self] in
      self?.cancellations += 1
      self?.pending = nil
    }
  }
  func fire() {
    let work = pending
    pending = nil
    work?()
  }
}

@MainActor @Test func configurationChangeRebuildsEngineAndRetriesOnceOnTransientFailure() {
  let scheduler = ManualRetrySchedule()
  let adapter = MediaAdapter(schedule: scheduler.schedule)
  var attempts = 0
  adapter.started = true
  adapter.restartEngineForTesting = {
    attempts += 1
    return attempts >= 2
  }
  adapter.handleConfigurationChange(retryDelayNanos: 123_000_000)
  #expect(attempts == 1)
  #expect(scheduler.scheduledDelays == [123_000_000])
  scheduler.fire()
  #expect(attempts == 2)
  #expect(scheduler.pending == nil)
  adapter.stop()
}

@MainActor @Test func configurationChangeStopsAfterOneFailedRetry() {
  let scheduler = ManualRetrySchedule()
  let adapter = MediaAdapter(schedule: scheduler.schedule)
  var attempts = 0
  adapter.started = true
  adapter.restartEngineForTesting = {
    attempts += 1
    return false
  }
  adapter.handleConfigurationChange(retryDelayNanos: 500_000_000)
  #expect(attempts == 1)
  scheduler.fire()
  #expect(attempts == 2)
  #expect(scheduler.pending == nil)
  #expect(scheduler.scheduledDelays == [500_000_000])
  adapter.stop()
}

@MainActor @Test func stopCancelsPendingConfigurationRestartAndBlocksLateCallback() {
  let scheduler = ManualRetrySchedule()
  let adapter = MediaAdapter(schedule: scheduler.schedule)
  var attempts = 0
  adapter.started = true
  adapter.restartEngineForTesting = {
    attempts += 1
    return false
  }
  adapter.handleConfigurationChange(retryDelayNanos: 500_000_000)
  let capturedRetry = scheduler.pending
  #expect(attempts == 1)
  #expect(capturedRetry != nil)
  adapter.stop()
  #expect(scheduler.cancellations == 1)
  #expect(scheduler.pending == nil)
  // Even if a timer callback had already been dispatched, stop() rejects it.
  capturedRetry?()
  #expect(attempts == 1)
}

@MainActor @Test func staleConfigurationChangeNotificationIsIgnoredAfterRebuild() {
  let scheduler = ManualRetrySchedule()
  let adapter = MediaAdapter(schedule: scheduler.schedule)
  var attempts = 0
  adapter.started = true
  adapter.restartEngineForTesting = {
    attempts += 1
    return true
  }
  let initialGeneration = adapter.engineGeneration
  adapter.configurationChangeObserved(generation: initialGeneration)
  #expect(attempts == 1)
  // A second queued notification from the torn-down engine must not rebuild the fresh one.
  adapter.configurationChangeObserved(generation: initialGeneration)
  #expect(attempts == 1)
  adapter.stop()
  adapter.configurationChangeObserved(generation: adapter.engineGeneration)
  #expect(attempts == 1)
}
