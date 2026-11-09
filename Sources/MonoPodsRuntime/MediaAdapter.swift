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
  private var targets: [(MPRemoteCommand, Any)] = []
  private var library: UnsafeMutableRawPointer?
  var send: MediaSend?
  static var nowPlayingMetadata: [String: Any] {
    [MPMediaItemPropertyTitle: "MonoPods", MPNowPlayingInfoPropertyPlaybackRate: 0.0]
  }
  public init() {}
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
    do { try engine.start() } catch { return false }
    self.engine = engine
    self.source = source
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
  public func play() -> Bool { send?(MediaCommand.play, nil) ?? false }
  public func pause() -> Bool { send?(MediaCommand.pause, nil) ?? false }
  public func stop() {
    guard engine != nil else { return }
    for (command, target) in targets { command.removeTarget(target) }
    targets.removeAll()
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    engine?.stop()
    engine = nil
    source = nil
  }
}
