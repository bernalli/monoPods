import Darwin
import Foundation

/// Closing a copy never explicitly unlocks the shared open-file description.
public final class InstanceLock: @unchecked Sendable {
  public let descriptor: Int32
  public init(files: AtomicRuntimeFiles, name: String) throws {
    guard name == "owner.lock" else { throw RuntimeError.invalid }
    let fd = try files.checkedFile(name, flags: O_RDWR, create: true)
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw RuntimeError.busy
    }
    descriptor = fd
  }
  deinit { close(descriptor) }
}

/// Notice presenter that must outlive the agent's launchd job; inherits no descriptors.
public enum DetachedProcess {
  public static func spawn(executable: String, arguments: [String]) throws {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0
    else { throw RuntimeError.child }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    guard
      posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP)) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else { throw RuntimeError.child }
    let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
    guard null >= 0 else { throw RuntimeError.child }
    defer { close(null) }
    for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_adddup2(&actions, null, fd) }
    let strings = ([executable] + arguments).map { strdup($0) }
    defer { for string in strings { free(string) } }
    var argv = strings + [nil]
    var child: pid_t = 0
    let result = posix_spawn(&child, executable, &actions, &attributes, &argv, environ)
    guard result == 0 else { throw RuntimeError.io(result) }
    let pid = child
    Thread.detachNewThread {
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 {
        if errno != EINTR { break }
      }
    }
  }
}
