import Sparkle
import Testing

@testable import MonoPods

@Test func sparkleLoadsInTheAppTestBundle() {
  let response = SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
  #expect(response.automaticUpdateChecks == false)
}
