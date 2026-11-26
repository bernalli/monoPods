import AVFoundation
import Darwin
import Foundation
import MediaPlayer
import MonoPodsCore

typealias MediaSend = @convention(c) (UInt32, CFDictionary?) -> Bool

/// Values of the MediaRemote command enumeration.
enum MediaCommand {
  static let play: UInt32 = 0
  static let pause: UInt32 = 1
}

@MainActor public final class MediaAdapter {
  private var engine: AVAudioEngine?
  private var source: AVAudioSourceNode?
  private var configObserver: NSObjectProtocol?
  private(set) var engineGeneration: UInt64 = 0
  private var cancelRestart: (@MainActor () -> Void)?
  private let schedule: OneShotSchedule
  var started = false
  private var targets: [(MPRemoteCommand, Any)] = []
  private var library: UnsafeMutableRawPointer?
  var send: MediaSend?
  var restartEngineForTesting: (@MainActor () -> Bool)?
  static var nowPlayingMetadata: [String: Any] {
    [MPMediaItemPropertyTitle: "MonoPods", MPNowPlayingInfoPropertyPlaybackRate: 0.0]
  }
  public init(schedule: @escaping OneShotSchedule = WaveAnimator.mainQueue) {
    self.schedule = schedule
  }
  /// Symbol resolution alone does not start audio or send a command.
  public func symbolsAvailable() -> Bool {
    if send != nil { return true }
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
      let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
    else { return false }
    library = handle
    send = unsafeBitCast(symbol, to: MediaSend.self)
    return true
  }
  public func start(submit: @escaping @MainActor @Sendable (EngineInput) -> Void) -> Bool {
    guard symbolsAvailable() else { return false }
    stop()
    guard startSilentEngine() else { return false }
    started = true
    let center = MPRemoteCommandCenter.shared()
    for (command, kind) in [
      (center.pauseCommand, 0), (center.playCommand, 1), (center.togglePlayPauseCommand, 2),
    ] {
      command.isEnabled = true
      let target = command.addTarget { _ in
        let time = SystemClock.now().utc
        Task { @MainActor in
          submit(
            kind == 0 ? .pause(time) : (kind == 1 ? .sentinelPlay(time) : .sentinelToggle(time)))
        }
        return .success
      }
      targets.append((command, target))
    }
    let nowPlaying = MPNowPlayingInfoCenter.default()
    nowPlaying.nowPlayingInfo = Self.nowPlayingMetadata
    nowPlaying.playbackState = .paused
    return true
  }
  private func startSilentEngine() -> Bool {
    tearDownSilentEngine()
    if let testRestart = restartEngineForTesting {
      return testRestart()
    }
    let engine = AVAudioEngine()
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
    else { return false }
    let source = AVAudioSourceNode(format: format) { silence, _, _, buffers in
      silence.pointee = true
      for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
      }
      return noErr
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    let generation = engineGeneration
    let observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.configurationChangeObserved(generation: generation) }
    }
    do {
      try engine.start()
    } catch {
      NotificationCenter.default.removeObserver(observer)
      return false
    }
    self.engine = engine
    self.source = source
    self.configObserver = observer
    return true
  }
  private func tearDownSilentEngine() {
    engineGeneration &+= 1
    if let observer = configObserver {
      NotificationCenter.default.removeObserver(observer)
      configObserver = nil
    }
    engine?.stop()
    engine = nil
    source = nil
  }
  func configurationChangeObserved(generation: UInt64, retryDelayNanos: UInt64 = 500_000_000) {
    guard started, engineGeneration == generation else { return }
    handleConfigurationChange(retryDelayNanos: retryDelayNanos)
  }
  /// Core Audio stops `AVAudioEngine` when the output hardware format changes (for example during
  /// a phone call or route switch). Rebuild on the new format, with one bounded retry if HAL is
  /// still settling.
  func handleConfigurationChange(retryDelayNanos: UInt64 = 500_000_000) {
    guard started else { return }
    cancelRestart?()
    cancelRestart = nil
    if startSilentEngine() { return }
    let generation = engineGeneration
    cancelRestart = schedule(retryDelayNanos) { [weak self] in
      guard let self, self.started, self.engineGeneration == generation else { return }
      self.cancelRestart = nil
      _ = self.startSilentEngine()
    }
  }
  public func play() -> Bool { send?(MediaCommand.play, nil) ?? false }
  public func pause() -> Bool { send?(MediaCommand.pause, nil) ?? false }
  public func stop() {
    started = false
    engineGeneration &+= 1
    cancelRestart?()
    cancelRestart = nil
    guard engine != nil || !targets.isEmpty || configObserver != nil else { return }
    for (command, target) in targets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    targets.removeAll()
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    tearDownSilentEngine()
  }
}
