/// Runs the host's reopen action and prevents AppKit from opening a default window.
public enum ApplicationReopen {
  @MainActor public static func handle(_ reopen: () -> Void) -> Bool {
    reopen()
    return false
  }
}
