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
