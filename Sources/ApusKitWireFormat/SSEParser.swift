internal import Foundation

/// A single Server-Sent Event reconstructed by ``SSEParser``.
public struct SSEEvent: Sendable, Equatable {
  /// The `event:` field value, if any field of that name was present.
  public var event: String?

  /// The `data:` field value, with multiple `data:` lines joined by `"\n"`.
  public var data: String

  /// The `id:` field value, if any field of that name was present.
  public var id: String?

  /// Creates an event.
  public init(event: String? = nil, data: String, id: String? = nil) {
    self.event = event
    self.data = data
    self.id = id
  }
}

/// A typed error thrown by ``SSEParser`` when it cannot decode its input.
///
/// Per `WIRE-1`, `ApusKitWireFormat` is the only target where typed
/// `throws` is permitted; per `ERR-2` the error is still a struct wrapping
/// a `@nonexhaustive` `Code` enum, not a public enum of its own.
public struct SSEParseError: Sendable, Equatable, Error {
  /// The category of failure an ``SSEParseError`` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// A line's bytes could not be decoded as UTF-8.
    case invalidUTF8
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates a parse error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

/// Incrementally parses Server-Sent Events from arbitrary byte chunks.
///
/// Feed bytes as they arrive via ``feed(_:)``; complete events are
/// returned as soon as their terminating blank line is seen. Raw bytes
/// are buffered across calls, so a chunk boundary may fall anywhere —
/// mid-UTF-8 sequence, mid-field name, mid-value, or mid-line-terminator —
/// without losing data or misparsing.
///
/// Recognized line terminators are `LF`, `CRLF`, and bare `CR`. A line
/// beginning with `:` is a comment and is ignored. A blank line dispatches
/// the event accumulated so far, if it had any content.
public struct SSEParser: Sendable {
  private var buffer: [UInt8] = []
  private var consumed = 0
  private var searchIndex = 0

  private var eventType: String?
  private var eventID: String?
  private var dataLines: [String] = []
  private var sawContent = false
  private var pendingEvents: [SSEEvent] = []

  /// Creates a parser with no buffered state.
  public init() {}

  /// Feeds a chunk of bytes, returning any complete events it produced.
  ///
  /// A malformed line is consumed and skipped before the error is thrown,
  /// so the parser always makes progress: the next call resumes at the
  /// line after the bad one rather than re-reporting it forever. Events
  /// completed before the failure are not lost either — they are held and
  /// returned by the next successful call.
  ///
  /// - Parameter bytes: The next chunk of the response body, in the order
  ///   it was received. Chunk boundaries may fall anywhere.
  /// - Throws: `SSEParseError` if a complete line cannot be decoded as
  ///   UTF-8.
  /// - Complexity: O(*n*) in the number of bytes fed so far across all
  ///   calls, amortized.
  public mutating func feed(_ bytes: some Sequence<UInt8>) throws(SSEParseError) -> [SSEEvent] {
    buffer.append(contentsOf: bytes)

    // Lines are retired by advancing `consumed`, and the buffer is drained
    // exactly once per call. Removing each line's bytes as it was parsed
    // shifted the whole remaining buffer per line, making one `feed` call
    // O(bytes x lines) — measurably quadratic on a many-line chunk, against
    // both the complexity documented above and WIRE-2's "allocation-conscious".
    // The `defer` also runs on the throwing path, so a malformed line cannot
    // wedge the parser (R1).
    defer {
      if consumed > 0 {
        buffer.removeFirst(consumed)
        searchIndex -= consumed
        consumed = 0
      }
    }

    while let bounds = nextLineBounds() {
      let lineStart = consumed
      consumed = bounds.nextStart
      searchIndex = consumed
      if let event = try processLine(buffer[lineStart..<bounds.lineEnd]) {
        pendingEvents.append(event)
      }
    }

    let events = pendingEvents
    pendingEvents = []
    return events
  }

  /// Finds the bounds of the next complete line in `buffer`, if any.
  ///
  /// Indices are absolute into `buffer`; the line starts at `consumed`,
  /// which `feed(_:)` advances. On a hit `searchIndex` is left to the
  /// caller, which sets it to the new `consumed`.
  ///
  /// Returns `(lineEnd, nextStart)`, where `lineEnd` is the index just
  /// past the line's content (terminator excluded) and `nextStart` is the
  /// index where the following line begins (terminator included). A
  /// trailing bare `CR` with no byte after it yet is treated as
  /// incomplete, since it may turn out to be the first half of a `CRLF`.
  private mutating func nextLineBounds() -> (lineEnd: Int, nextStart: Int)? {
    var i = searchIndex
    while i < buffer.count {
      let byte = buffer[i]
      if byte == 0x0A {
        return (i, i + 1)
      }
      if byte == 0x0D {
        let next = i + 1
        if next < buffer.count {
          if buffer[next] == 0x0A {
            return (i, next + 1)
          }
          return (i, next)
        }
        searchIndex = i
        return nil
      }
      i += 1
    }
    searchIndex = i
    return nil
  }

  /// Processes one complete line (terminator excluded), updating the
  /// in-progress event and returning a dispatched event if the line was
  /// blank and there was content to dispatch.
  private mutating func processLine(_ lineBytes: ArraySlice<UInt8>) throws(SSEParseError)
    -> SSEEvent?
  {
    if lineBytes.isEmpty {
      defer {
        eventType = nil
        eventID = nil
        dataLines = []
        sawContent = false
      }
      guard sawContent else { return nil }
      return SSEEvent(event: eventType, data: dataLines.joined(separator: "\n"), id: eventID)
    }

    guard let line = String(bytes: lineBytes, encoding: .utf8) else {
      throw SSEParseError(code: .invalidUTF8, message: "SSE line is not valid UTF-8")
    }

    if line.hasPrefix(":") {
      return nil
    }

    let field: Substring
    let value: Substring
    if let colonIndex = line.firstIndex(of: ":") {
      field = line[line.startIndex..<colonIndex]
      var rest = line[line.index(after: colonIndex)...]
      if rest.hasPrefix(" ") {
        rest = rest.dropFirst()
      }
      value = rest
    } else {
      field = line[...]
      value = ""
    }

    switch field {
    case "event":
      eventType = String(value)
      sawContent = true
    case "data":
      dataLines.append(String(value))
      sawContent = true
    case "id":
      eventID = String(value)
      sawContent = true
    default:
      break
    }
    return nil
  }
}
