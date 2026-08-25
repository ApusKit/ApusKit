// PartialJSONAccumulatorTests
//
// Coverage for `PartialJSONAccumulator`. The decisive test (R2, R3) feeds
// one realistic tool-call `arguments` JSON payload one byte at a time and
// asserts `JSONSerialization.jsonObject(with:)` succeeds on `snapshot()`
// at EVERY prefix.

import ApusKitWireFormat
import Foundation
import Testing

/// Asserts `text` is accepted by `JSONSerialization` as a complete JSON
/// document.
private func assertWellFormed(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
  guard let data = text.data(using: .utf8) else {
    Issue.record("snapshot was not valid UTF-8: \(text)", sourceLocation: sourceLocation)
    return
  }
  do {
    _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  } catch {
    Issue.record(
      "snapshot \(text.debugDescription) was not well-formed JSON: \(error)",
      sourceLocation: sourceLocation
    )
  }
}

@Suite("PartialJSONAccumulator")
struct PartialJSONAccumulatorTests {
  @Test("an empty accumulator snapshots to well-formed JSON")
  func emptyAccumulatorIsWellFormed() {
    let accumulator = PartialJSONAccumulator()
    assertWellFormed(accumulator.snapshot())
  }

  @Test("a complete object round-trips unchanged in content")
  func completeObjectRoundTrips() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"name":"Anna","age":3}"#)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["name"] as? String == "Anna")
    #expect(object["age"] as? Int == 3)
  }

  @Test("an unclosed string is closed")
  func unclosedStringIsClosed() {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"greeting":"Hello, wor"#)
    assertWellFormed(accumulator.snapshot())
  }

  @Test("a dangling escape inside an unclosed string is dropped")
  func danglingEscapeIsDropped() {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"path":"C:\"#)
    assertWellFormed(accumulator.snapshot())
  }

  @Test(
    "a dangling number component is trimmed",
    arguments: [
      #"{"x":5"#, #"{"x":5."#, #"{"x":5.3e"#, #"{"x":5.3e+"#, #"{"x":-"#,
    ])
  func danglingNumberIsTrimmed(fragment: String) {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(fragment)
    assertWellFormed(accumulator.snapshot())
  }

  @Test(
    "a partial true/false/null literal is completed",
    arguments: [
      "t", "tr", "tru", "f", "fal", "fals", "n", "nu", "nul",
    ])
  func partialLiteralIsCompleted(fragment: String) {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(fragment)
    assertWellFormed(accumulator.snapshot())
  }

  @Test("a trailing key with no colon is dropped")
  func trailingKeyWithNoColonIsDropped() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"a":1,"b"#)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["a"] as? Int == 1)
    #expect(object.count == 1)
  }

  @Test("a trailing colon with no value is dropped")
  func trailingColonWithNoValueIsDropped() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"a":1,"b":"#)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object.count == 1)
  }

  @Test("a trailing comma with nothing after it is dropped")
  func trailingCommaIsDropped() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"["#)
    accumulator.append(#"1,"#)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let array = try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    #expect(array.count == 1)
  }

  @Test("nested unclosed objects and arrays all close")
  func nestedContainersClose() {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"a":[1,2,{"b":3"#)
    assertWellFormed(accumulator.snapshot())
  }

  @Test(
    "every prefix of a realistic streamed arguments payload is well-formed JSON, one byte at a time"
  )
  func everyByteByBytePrefixIsWellFormed() {
    let full = Array(
      #"{"query":"weather in Tokyo","filters":{"units":"metric","days":3},"tags":["forecast","asia"],"limit":null,"precise":true}"#
        .utf8
    )

    var accumulator = PartialJSONAccumulator()
    for byte in full {
      accumulator.append(String(decoding: [byte], as: UTF8.self))
      assertWellFormed(accumulator.snapshot())
    }
  }
}
