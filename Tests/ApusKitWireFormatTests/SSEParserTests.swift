// SSEParserTests
//
// Coverage for `SSEParser`, including replaying the same input split at
// every byte offset (R3): a chunk boundary must be able to fall mid-UTF-8,
// mid-field-name, mid-value, or mid-line-terminator without changing the
// events produced.

import ApusKitWireFormat
import Testing

@Suite("SSEParser")
struct SSEParserTests {
  @Test("a single data-only event dispatches on the blank line")
  func singleDataEvent() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array("data: hello\n\n".utf8))
    #expect(events == [SSEEvent(data: "hello")])
  }

  @Test("event, id, and data fields are all captured")
  func allFields() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array("event: greeting\nid: 1\ndata: hi\n\n".utf8))
    #expect(events == [SSEEvent(event: "greeting", data: "hi", id: "1")])
  }

  @Test("multiple data lines join with a newline")
  func multiLineData() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array("data: line1\ndata: line2\n\n".utf8))
    #expect(events == [SSEEvent(data: "line1\nline2")])
  }

  @Test("comment lines are ignored")
  func commentLinesIgnored() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array(": this is a comment\ndata: x\n\n".utf8))
    #expect(events == [SSEEvent(data: "x")])
  }

  @Test("a blank line with no content dispatches nothing")
  func blankLineWithNoContentDispatchesNothing() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array(": just a comment\n\n".utf8))
    #expect(events.isEmpty)
  }

  @Test("CRLF line terminators are recognized")
  func crlfTerminators() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array("data: hi\r\n\r\n".utf8))
    #expect(events == [SSEEvent(data: "hi")])
  }

  @Test("bare CR line terminators are recognized")
  func bareCRTerminators() throws {
    var parser = SSEParser()
    // A CR at the very end of a chunk is ambiguous (it might be the first
    // half of a CRLF), so the blank-line CR only resolves once a
    // following chunk proves it is not followed by LF.
    var events = try parser.feed(Array("data: hi\r\r".utf8))
    events += try parser.feed(Array(":done\n".utf8))
    #expect(events == [SSEEvent(data: "hi")])
  }

  @Test("state resets between events")
  func stateResetsBetweenEvents() throws {
    var parser = SSEParser()
    let events = try parser.feed(Array("event: first\ndata: a\n\ndata: b\n\n".utf8))
    #expect(events == [SSEEvent(event: "first", data: "a"), SSEEvent(data: "b")])
  }

  @Test("invalid UTF-8 in a complete line throws a typed parse error")
  func invalidUTF8Throws() {
    var parser = SSEParser()
    let malformed: [UInt8] = Array("data: ".utf8) + [0xFF] + Array("\n\n".utf8)
    #expect(throws: SSEParseError(code: .invalidUTF8, message: "SSE line is not valid UTF-8")) {
      try parser.feed(malformed)
    }
  }

  @Test("the parser makes progress after an invalid UTF-8 line")
  func recoversAfterInvalidUTF8() throws {
    var parser = SSEParser()
    let malformed: [UInt8] = Array("data: bad ".utf8) + [0xFF] + Array("\n\n".utf8)
    #expect(throws: SSEParseError(code: .invalidUTF8, message: "SSE line is not valid UTF-8")) {
      try parser.feed(malformed)
    }
    // The offending bytes must not stay buffered: a clean chunk after the
    // failure parses normally instead of re-throwing the same error.
    let events = try parser.feed(Array("data: after\n\n".utf8))
    #expect(events == [SSEEvent(data: "after")])
  }

  @Test("events completed before an invalid UTF-8 line are not lost")
  func eventsBeforeInvalidUTF8SurviveTheThrow() throws {
    var parser = SSEParser()
    let chunk: [UInt8] =
      Array("data: good\n\ndata: ".utf8) + [0xFF] + Array("\n\n".utf8)
    #expect(throws: SSEParseError(code: .invalidUTF8, message: "SSE line is not valid UTF-8")) {
      try parser.feed(chunk)
    }
    // `good` completed before the bad line, so it is held and delivered by
    // the next successful call rather than discarded with the error.
    let events = try parser.feed(Array("data: after\n\n".utf8))
    #expect(events == [SSEEvent(data: "good"), SSEEvent(data: "after")])
  }

  /// The full reference stream used by ``splitAtEveryByteOffset(splitOffset:)``:
  /// two events, mixing CRLF and LF terminators, a comment line, and
  /// multi-line data — replayed split at every possible byte boundary.
  private static let fullStream = Array(
    "event: greeting\r\nid: 1\r\n: a comment\r\ndata: hello\r\ndata: world\r\n\r\ndata: second\n\n"
      .utf8
  )

  @Test(
    "splitting the same input at every byte offset produces the same events",
    arguments: 0...fullStream.count)
  func splitAtEveryByteOffset(splitOffset: Int) throws {
    var referenceParser = SSEParser()
    let expected = try referenceParser.feed(Self.fullStream)

    var parser = SSEParser()
    let first = Self.fullStream[..<splitOffset]
    let second = Self.fullStream[splitOffset...]

    var events = try parser.feed(first)
    events += try parser.feed(second)

    #expect(events == expected)
  }
}
