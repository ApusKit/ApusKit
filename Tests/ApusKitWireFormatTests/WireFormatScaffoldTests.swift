// WireFormatScaffoldTests
//
// A real smoke test proving ApusKitWireFormat's target, product, and test
// target are wired correctly, independent of any one kernel's own suite.

import ApusKitWireFormat
import Testing

@Suite("WireFormatScaffold")
struct WireFormatScaffoldTests {
  @Test("SSEParser is reachable and produces a dispatched event")
  func sseParserIsReachable() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array("data: ok\n\n".utf8))
    #expect(events == [SSEEvent(data: "ok")])
  }
}
