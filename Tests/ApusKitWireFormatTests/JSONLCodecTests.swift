// JSONLCodecTests
//
// Coverage for `JSONLCodec`, the generic line-level kernel: splitting a
// byte buffer into complete JSONL lines while tolerating a trailing
// partial line (R2), and round-tripping losslessly.

import ApusKitWireFormat
import Testing

@Suite("JSONLCodec")
struct JSONLCodecTests {
  @Test("decoding an empty buffer yields no lines and no trailing bytes")
  func emptyBufferDecodesToNothing() throws {
    let result = try JSONLCodec.decode([UInt8]())
    #expect(result.lines.isEmpty)
    #expect(result.trailing.isEmpty)
  }

  @Test("complete LF-terminated lines are all decoded, in order")
  func completeLinesAreDecodedInOrder() throws {
    let bytes = Array("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".utf8)
    let result = try JSONLCodec.decode(bytes)
    #expect(result.lines == [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
    #expect(result.trailing.isEmpty)
  }

  @Test("a trailing partial line with no terminator is returned unconsumed, not decoded")
  func trailingPartialLineIsReturnedUnconsumed() throws {
    let bytes = Array("{\"a\":1}\n{\"b\":2".utf8)
    let result = try JSONLCodec.decode(bytes)
    #expect(result.lines == [#"{"a":1}"#])
    #expect(result.trailing == Array("{\"b\":2".utf8))
  }

  @Test("a buffer with no terminator at all is entirely trailing")
  func bufferWithNoTerminatorIsEntirelyTrailing() throws {
    let bytes = Array(#"{"a":1}"#.utf8)
    let result = try JSONLCodec.decode(bytes)
    #expect(result.lines.isEmpty)
    #expect(result.trailing == bytes)
  }

  @Test("an empty line between two terminators decodes to an empty string")
  func emptyLineDecodesToEmptyString() throws {
    let bytes = Array("{\"a\":1}\n\n{\"b\":2}\n".utf8)
    let result = try JSONLCodec.decode(bytes)
    #expect(result.lines == [#"{"a":1}"#, "", #"{"b":2}"#])
  }

  @Test("invalid UTF-8 in a complete line throws, not the trailing partial line")
  func invalidUTF8InCompleteLineThrows() throws {
    var bytes = Array("{\"a\":1}\n".utf8)
    bytes.append(0xFF)
    bytes.append(0x0A)
    #expect(throws: JSONLDecodeError.self) {
      try JSONLCodec.decode(bytes)
    }
  }

  @Test("invalid UTF-8 confined to a trailing partial line does not throw")
  func invalidUTF8InTrailingLineDoesNotThrow() throws {
    var bytes = Array("{\"a\":1}\n".utf8)
    bytes.append(0xFF)
    let result = try JSONLCodec.decode(bytes)
    #expect(result.lines == [#"{"a":1}"#])
    #expect(result.trailing == [0xFF])
  }

  @Test("an invalid-UTF-8 error carries the expected code")
  func invalidUTF8ErrorHasExpectedCode() throws {
    var bytes: [UInt8] = [0xFF]
    bytes.append(0x0A)
    do {
      _ = try JSONLCodec.decode(bytes)
      Issue.record("expected decode to throw")
    } catch {
      #expect(error.code == .invalidUTF8)
    }
  }

  @Test("encoding terminates every line, including the last, with a single LF")
  func encodeTerminatesEveryLine() {
    let bytes = JSONLCodec.encode([#"{"a":1}"#, #"{"b":2}"#])
    #expect(bytes == Array("{\"a\":1}\n{\"b\":2}\n".utf8))
  }

  @Test("encoding no lines produces no bytes")
  func encodingNoLinesProducesNoBytes() {
    #expect(JSONLCodec.encode([]).isEmpty)
  }

  @Test("decode then encode round-trips a full JSONL buffer losslessly")
  func decodeThenEncodeRoundTripsLosslessly() throws {
    let original = Array("{\"type\":\"header\"}\n{\"type\":\"entry\",\"n\":1}\n".utf8)
    let result = try JSONLCodec.decode(original)
    let reencoded = JSONLCodec.encode(result.lines)
    #expect(reencoded == original)
  }

  @Test(
    "decode then encode of a buffer with a trailing partial line reproduces only the complete part"
  )
  func decodeThenEncodeOfPartialBufferReproducesCompletePart() throws {
    let complete = Array("{\"a\":1}\n{\"b\":2}\n".utf8)
    let partial = Array(#"{"c":3"#.utf8)
    let result = try JSONLCodec.decode(complete + partial)
    #expect(JSONLCodec.encode(result.lines) == complete)
    #expect(result.trailing == partial)
  }

  @Test("a chunk boundary that splits a line is recoverable by decoding trailing + next chunk")
  func chunkBoundarySplitLineIsRecoverable() throws {
    let firstChunk = Array("{\"a\":1}\n{\"b\":2".utf8)
    let secondChunk = Array("}\n{\"c\":3}\n".utf8)

    let firstResult = try JSONLCodec.decode(firstChunk)
    #expect(firstResult.lines == [#"{"a":1}"#])

    let secondResult = try JSONLCodec.decode(firstResult.trailing + secondChunk)
    #expect(secondResult.lines == [#"{"b":2}"#, #"{"c":3}"#])
    #expect(secondResult.trailing.isEmpty)
  }
}
