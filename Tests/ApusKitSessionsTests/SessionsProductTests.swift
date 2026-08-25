// SessionsProductTests
//
// A real smoke test proving ApusKitSessions' target, product, and test
// target are wired correctly. No public API exists yet — this scaffold
// only proves the module imports and the test target builds and runs.

import ApusKitSessions
import Testing

@Suite("SessionsProduct")
struct SessionsProductTests {
  @Test("ApusKitSessions module is reachable")
  func moduleIsReachable() {
    #expect(Bool(true))
  }
}
