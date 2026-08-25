/// Incrementally repairs a stream of JSON fragments into a snapshot that
/// is always valid, well-formed JSON.
///
/// Feed fragments as they arrive from a streamed tool-call `arguments`
/// payload via ``append(_:)``; call ``snapshot()`` at any point to get a
/// syntactically valid JSON string representing what has been received so
/// far: a string is closed and cut short of anything a JSON string may not
/// carry (a dangling or unrecognized escape, a truncated `\uXXXX`, the lone
/// half of a split surrogate pair, a raw control character), a dangling or
/// malformed number or `true`/`false`/`null` literal is completed or
/// dropped, a trailing key with no value or a trailing comma with nothing
/// after it is dropped, and every open object or array is closed.
///
/// `PartialJSONAccumulator` deliberately returns a `String`, not a parsed
/// value: a JSON value type belongs to `swift-json-schema`, which is
/// unreachable from this target under `PKG-6`, and decoding the result is
/// the caller's job.
public struct PartialJSONAccumulator: Sendable {
  private var bytes: [UInt8] = []

  /// Creates an empty accumulator.
  public init() {}

  /// Appends a streamed fragment of JSON text.
  public mutating func append(_ fragment: String) {
    bytes.append(contentsOf: fragment.utf8)
  }

  /// Returns the accumulated text repaired into valid, well-formed JSON.
  ///
  /// - Complexity: O(*n*) in the number of bytes accumulated so far.
  public func snapshot() -> String {
    String(decoding: PartialJSONAccumulator.repair(bytes), as: UTF8.self)
  }

  // MARK: - Tokenizing

  private enum TokenKind {
    case openBrace, closeBrace, openBracket, closeBracket, comma, colon
    case string, number, literal
  }

  private struct RawToken {
    var kind: TokenKind
    var start: Int
    var end: Int
    /// Only meaningful for `.string`: whether a closing `"` was found
    /// before the buffer ran out.
    var stringWasClosed = true
  }

  private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
  private static func isLowercaseLetter(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) }

  /// Splits `bytes` into structural tokens. At most the LAST token may be
  /// incomplete (a string with no closing quote, or a number/literal that
  /// simply ran out of bytes) — every earlier token was necessarily
  /// terminated by a delimiter already present in `bytes`.
  private static func tokenize(_ bytes: [UInt8]) -> [RawToken] {
    var tokens: [RawToken] = []
    var i = 0
    let n = bytes.count
    while i < n {
      switch bytes[i] {
      case 0x20, 0x09, 0x0A, 0x0D:  // space, tab, LF, CR
        i += 1
      case 0x7B:  // {
        tokens.append(RawToken(kind: .openBrace, start: i, end: i + 1))
        i += 1
      case 0x7D:  // }
        tokens.append(RawToken(kind: .closeBrace, start: i, end: i + 1))
        i += 1
      case 0x5B:  // [
        tokens.append(RawToken(kind: .openBracket, start: i, end: i + 1))
        i += 1
      case 0x5D:  // ]
        tokens.append(RawToken(kind: .closeBracket, start: i, end: i + 1))
        i += 1
      case 0x2C:  // ,
        tokens.append(RawToken(kind: .comma, start: i, end: i + 1))
        i += 1
      case 0x3A:  // :
        tokens.append(RawToken(kind: .colon, start: i, end: i + 1))
        i += 1
      case 0x22:  // "
        let start = i
        i += 1
        var closed = false
        // Start of an escape the buffer ran out in the middle of. The token
        // ends there — the incomplete escape is dropped — while `i` still
        // advances past it, so the leftover bytes are never re-tokenized.
        var truncatedEscape: Int?
        while i < n {
          let b = bytes[i]
          if b == 0x5C {  // backslash
            guard i + 1 < n else {  // dangling escape at EOF
              truncatedEscape = i
              i = n
              break
            }
            if bytes[i + 1] == 0x75 {  // \u needs 4 hex digits
              guard i + 6 <= n else {
                truncatedEscape = i
                i = n
                break
              }
              i += 6
            } else {
              i += 2
            }
            continue
          }
          if b == 0x22 {
            i += 1
            closed = true
            break
          }
          i += 1
        }
        tokens.append(
          RawToken(kind: .string, start: start, end: truncatedEscape ?? i, stringWasClosed: closed)
        )
      case 0x2D, 0x30...0x39:  // '-' or a digit
        let start = i
        i += 1
        while i < n,
          isDigit(bytes[i]) || bytes[i] == 0x2E || bytes[i] == 0x65 || bytes[i] == 0x45
            || bytes[i] == 0x2B || bytes[i] == 0x2D
        {
          i += 1
        }
        tokens.append(RawToken(kind: .number, start: start, end: i))
      case 0x74, 0x66, 0x6E:  // 't', 'f', 'n'
        let start = i
        i += 1
        while i < n, isLowercaseLetter(bytes[i]) {
          i += 1
        }
        tokens.append(RawToken(kind: .literal, start: start, end: i))
      default:
        // Not valid at this position in a JSON prefix; skip defensively.
        i += 1
      }
    }
    return tokens
  }

  // MARK: - Repairing the trailing token

  /// Finds the longest prefix of `bytes[start..<end]` that is a
  /// syntactically valid JSON number, dropping a dangling `-`, `.`, or
  /// exponent marker. Returns `nil` if no valid number prefix exists at
  /// all (e.g. a lone `-`).
  private static func repairedNumberEnd(_ bytes: [UInt8], start: Int, end: Int) -> Int? {
    var i = start
    if i < end, bytes[i] == 0x2D {  // '-'
      i += 1
    }
    if i < end, bytes[i] == 0x30 {  // '0'
      i += 1
    } else if i < end, (0x31...0x39).contains(bytes[i]) {
      i += 1
      while i < end, isDigit(bytes[i]) {
        i += 1
      }
    } else {
      return nil
    }
    var lastValidEnd = i

    if i < end, bytes[i] == 0x2E {  // '.'
      let fracStart = i + 1
      var j = fracStart
      while j < end, isDigit(bytes[j]) {
        j += 1
      }
      if j > fracStart {
        i = j
        lastValidEnd = i
      }
    }

    if i < end, bytes[i] == 0x65 || bytes[i] == 0x45 {  // 'e' or 'E'
      var j = i + 1
      if j < end, bytes[j] == 0x2B || bytes[j] == 0x2D {
        j += 1
      }
      let digitsStart = j
      while j < end, isDigit(bytes[j]) {
        j += 1
      }
      if j > digitsStart {
        lastValidEnd = j
      }
    }

    return lastValidEnd
  }

  private static func hexDigitValue(_ byte: UInt8) -> Int? {
    switch byte {
    case 0x30...0x39: return Int(byte) - 0x30
    case 0x61...0x66: return Int(byte) - 0x61 + 10
    case 0x41...0x46: return Int(byte) - 0x41 + 10
    default: return nil
    }
  }

  /// Decodes the four hex digits of the `\uXXXX` escape starting at `index`.
  ///
  /// The caller guarantees the six escape bytes are all present.
  private static func hexEscapeValue(_ bytes: [UInt8], at index: Int) -> Int? {
    var scalar = 0
    for offset in 2..<6 {
      guard let digit = hexDigitValue(bytes[index + offset]) else { return nil }
      scalar = scalar << 4 | digit
    }
    return scalar
  }

  /// Whether `byte` may follow a backslash in a JSON string.
  private static func isEscapableByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x22, 0x5C, 0x2F: return true  // '"', '\', '/'
    case 0x62, 0x66, 0x6E, 0x72, 0x74: return true  // 'b', 'f', 'n', 'r', 't'
    default: return false
    }
  }

  /// Finds where the body of a string can be cut so that closing it yields
  /// valid JSON.
  ///
  /// Anything a JSON string may not contain ends the body: a raw control
  /// character, an unrecognized escape, a truncated or non-hex `\uXXXX`, a
  /// lone low surrogate, and a `\uD800`–`\uDBFF` high surrogate not followed
  /// by its low half — which is what a prefix landing between the two halves
  /// of a pair leaves behind. `start` is the index of the opening quote and
  /// `bodyEnd` the exclusive end of the body, excluding any closing quote.
  private static func safeStringBodyEnd(_ bytes: [UInt8], start: Int, bodyEnd: Int) -> Int {
    var i = start + 1  // skip the opening quote
    var pendingHighSurrogate: Int?  // a \uD800-\uDBFF escape awaiting its low half
    while i < bodyEnd {
      if bytes[i] < 0x20 { return pendingHighSurrogate ?? i }  // raw control character
      guard bytes[i] == 0x5C else {  // backslash
        if let high = pendingHighSurrogate { return high }
        i += 1
        continue
      }
      guard i + 1 < bodyEnd else { return pendingHighSurrogate ?? i }
      guard bytes[i + 1] == 0x75 else {  // 'u'
        if let high = pendingHighSurrogate { return high }
        guard isEscapableByte(bytes[i + 1]) else { return i }
        i += 2
        continue
      }
      guard i + 6 <= bodyEnd, let scalar = hexEscapeValue(bytes, at: i) else {
        return pendingHighSurrogate ?? i
      }
      if let high = pendingHighSurrogate {
        guard (0xDC00...0xDFFF).contains(scalar) else { return high }
        pendingHighSurrogate = nil
      } else if (0xD800...0xDBFF).contains(scalar) {
        pendingHighSurrogate = i
      } else if (0xDC00...0xDFFF).contains(scalar) {
        return i  // low surrogate with no high half before it
      }
      i += 6
    }
    return pendingHighSurrogate ?? bodyEnd
  }

  private static let literalCandidates: [[UInt8]] = [
    Array("true".utf8), Array("false".utf8), Array("null".utf8),
  ]

  /// How to emit one token: the source byte range to copy verbatim, plus
  /// any bytes to inject after it (a closing quote, or the remainder of a
  /// completed literal).
  private static func emissionPlan(for token: RawToken, bytes: [UInt8]) -> (
    range: Range<Int>, suffix: [UInt8]
  )? {
    switch token.kind {
    case .string:
      // The closing quote is re-injected rather than copied, so a body cut
      // short of it still ends in one.
      let bodyEnd = token.stringWasClosed ? token.end - 1 : token.end
      let safeEnd = safeStringBodyEnd(bytes, start: token.start, bodyEnd: bodyEnd)
      return (token.start..<safeEnd, [0x22])
    case .number:
      guard let repairedEnd = repairedNumberEnd(bytes, start: token.start, end: token.end) else {
        return nil
      }
      return (token.start..<repairedEnd, [])
    case .literal:
      let text = bytes[token.start..<token.end]
      guard
        let match = literalCandidates.first(where: {
          $0.count >= text.count && $0[0..<text.count].elementsEqual(text)
        })
      else {
        return nil
      }
      return (token.start..<token.end, Array(match[text.count...]))
    case .openBrace, .closeBrace, .openBracket, .closeBracket, .comma, .colon:
      return (token.start..<token.end, [])
    }
  }

  // MARK: - Walking the JSON grammar

  private enum Expect {
    case topLevelStart, topLevelDone
    case objectStart, objectAfterComma, objectKeyDone, objectAfterColon, objectAfterValue
    case arrayStart, arrayAfterComma, arrayAfterValue
  }

  private enum ContainerKind { case object, array }

  /// Repairs `bytes` into the longest prefix that is valid JSON once every
  /// open container is closed, completing or dropping a dangling trailing
  /// token as needed.
  private static func repair(_ bytes: [UInt8]) -> [UInt8] {
    let tokens = tokenize(bytes)
    guard !tokens.isEmpty else { return Array("null".utf8) }

    var output: [UInt8] = []
    var committed: [UInt8] = []
    var stack: [ContainerKind] = []
    var committedStack: [ContainerKind] = []
    var expect: Expect = .topLevelStart

    func markSafe() {
      committed = output
      committedStack = stack
    }

    func afterValueState() -> Expect {
      switch stack.last {
      case .object: return .objectAfterValue
      case .array: return .arrayAfterValue
      case nil: return .topLevelDone
      }
    }

    tokenLoop: for token in tokens {
      // Every token is emitted through its plan, not just the trailing one:
      // a truncated string is closed wherever it sits, and a token with no
      // valid prefix at all ends the walk at the last safe point.
      guard let plan = emissionPlan(for: token, bytes: bytes) else { break tokenLoop }
      let range = plan.range
      let suffix = plan.suffix

      switch (expect, token.kind) {
      case (.topLevelStart, .string), (.topLevelStart, .number), (.topLevelStart, .literal):
        output.append(contentsOf: bytes[range])
        output.append(contentsOf: suffix)
        expect = .topLevelDone
        markSafe()
      case (.topLevelStart, .openBrace):
        output.append(contentsOf: bytes[range])
        stack.append(.object)
        expect = .objectStart
        markSafe()
      case (.topLevelStart, .openBracket):
        output.append(contentsOf: bytes[range])
        stack.append(.array)
        expect = .arrayStart
        markSafe()

      case (.objectStart, .string), (.objectAfterComma, .string):
        output.append(contentsOf: bytes[range])
        output.append(contentsOf: suffix)
        expect = .objectKeyDone
      case (.objectStart, .closeBrace):
        output.append(contentsOf: bytes[range])
        stack.removeLast()
        expect = afterValueState()
        markSafe()
      case (.objectAfterComma, .closeBrace):
        break tokenLoop  // dangling comma before close: keep the last safe point

      case (.objectKeyDone, .colon):
        output.append(contentsOf: bytes[range])
        expect = .objectAfterColon

      case (.objectAfterColon, .string), (.objectAfterColon, .number),
        (.objectAfterColon, .literal):
        output.append(contentsOf: bytes[range])
        output.append(contentsOf: suffix)
        expect = .objectAfterValue
        markSafe()
      case (.objectAfterColon, .openBrace):
        output.append(contentsOf: bytes[range])
        stack.append(.object)
        expect = .objectStart
        markSafe()
      case (.objectAfterColon, .openBracket):
        output.append(contentsOf: bytes[range])
        stack.append(.array)
        expect = .arrayStart
        markSafe()

      case (.objectAfterValue, .comma):
        output.append(contentsOf: bytes[range])
        expect = .objectAfterComma
      case (.objectAfterValue, .closeBrace):
        output.append(contentsOf: bytes[range])
        stack.removeLast()
        expect = afterValueState()
        markSafe()

      case (.arrayStart, .string), (.arrayAfterComma, .string),
        (.arrayStart, .number), (.arrayAfterComma, .number),
        (.arrayStart, .literal), (.arrayAfterComma, .literal):
        output.append(contentsOf: bytes[range])
        output.append(contentsOf: suffix)
        expect = .arrayAfterValue
        markSafe()
      case (.arrayStart, .openBrace), (.arrayAfterComma, .openBrace):
        output.append(contentsOf: bytes[range])
        stack.append(.object)
        expect = .objectStart
        markSafe()
      case (.arrayStart, .openBracket), (.arrayAfterComma, .openBracket):
        output.append(contentsOf: bytes[range])
        stack.append(.array)
        expect = .arrayStart
        markSafe()
      case (.arrayStart, .closeBracket):
        output.append(contentsOf: bytes[range])
        stack.removeLast()
        expect = afterValueState()
        markSafe()
      case (.arrayAfterComma, .closeBracket):
        break tokenLoop  // dangling comma before close: keep the last safe point

      case (.arrayAfterValue, .comma):
        output.append(contentsOf: bytes[range])
        expect = .arrayAfterComma
      case (.arrayAfterValue, .closeBracket):
        output.append(contentsOf: bytes[range])
        stack.removeLast()
        expect = afterValueState()
        markSafe()

      default:
        break tokenLoop  // malformed relative to the grammar: stop, keep the last safe point
      }
    }

    guard !committed.isEmpty else { return Array("null".utf8) }
    var result = committed
    for kind in committedStack.reversed() {
      result.append(kind == .object ? 0x7D : 0x5D)
    }
    return result
  }
}
