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
    "a truncated \\uXXXX escape is dropped, and its leftover bytes never leak out as JSON",
    arguments: [
      #"{"u":"a\"#, #"{"u":"a\u"#, #"{"u":"a\u0"#, #"{"u":"a\u00"#, #"{"u":"a\u000"#,
    ])
  func truncatedUnicodeEscapeIsDropped(fragment: String) throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(fragment)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["u"] as? String == "a")
  }

  @Test("a split surrogate pair does not leave a lone half behind")
  func splitSurrogatePairIsDropped() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"emoji":"ok\ud83d"#)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["emoji"] as? String == "ok")
  }

  @Test("a complete escaped surrogate pair survives in an unclosed string")
  func completeSurrogatePairIsKept() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append("{\"emoji\":\"\\ud83d\\ude00")
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["emoji"] as? String == "\u{1F600}")
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

  @Test(
    "a malformed value before the end of the buffer is repaired, not copied through",
    arguments: [
      #"{"a":tru,"b":1}"#, #"{"a":1.2.3,"b":4}"#, #"{"a":1e,"b":2}"#, #"{"a":-,"b":1}"#,
      "[tru, 1]", "[1.2.3,true]",
      "{\"a\":\"x\u{01}y\",\"b\":1}", #"{"a":"x\qy","b":1}"#, #"{"a":"x\udc00y","b":1}"#,
      #"{"a":"x\ud83dy","b":1}"#, #"{"a":"x\u00zzy","b":1}"#,
    ])
  func malformedInteriorValueIsRepaired(document: String) {
    var accumulator = PartialJSONAccumulator()
    assertWellFormed(accumulator.snapshot())
    for byte in Array(document.utf8) {
      accumulator.append(String(decoding: [byte], as: UTF8.self))
      assertWellFormed(accumulator.snapshot())
    }
  }

  @Test("an interior partial literal is completed rather than passed through")
  func interiorPartialLiteralIsCompleted() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"a":tru,"b":1}"#)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["a"] as? Bool == true)
    #expect(object["b"] as? Int == 1)
  }

  @Test("an interior malformed number is trimmed rather than passed through")
  func interiorMalformedNumberIsTrimmed() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append(#"{"a":1e,"b":2}"#)
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["a"] as? Int == 1)
    #expect(object["b"] as? Int == 2)
  }

  @Test("a string body a JSON parser would reject is cut short, and what follows survives")
  func invalidStringContentIsCutShort() throws {
    var accumulator = PartialJSONAccumulator()
    accumulator.append("{\"a\":\"x\u{01}y\",\"b\":1}")
    let snapshot = accumulator.snapshot()
    assertWellFormed(snapshot)

    let data = try #require(snapshot.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["a"] as? String == "x")
    #expect(object["b"] as? Int == 1)
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
    "every prefix of an escape-bearing payload is well-formed JSON, one byte at a time",
    arguments: [
      ###"{"note":"line\u000abreak","ok":true}"###,
      ###"{"name":"caf\u00e9","id":7}"###,
      ###"{"emoji":"\ud83d\ude00","n":1}"###,
      ###"{"path":"C:\\tmp\"q\"","n":[1,2]}"###,
    ])
  func everyByteByBytePrefixOfEscapedPayloadIsWellFormed(document: String) {
    var accumulator = PartialJSONAccumulator()
    for byte in Array(document.utf8) {
      accumulator.append(String(decoding: [byte], as: UTF8.self))
      assertWellFormed(accumulator.snapshot())
    }
    #expect(accumulator.snapshot() == document)
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
