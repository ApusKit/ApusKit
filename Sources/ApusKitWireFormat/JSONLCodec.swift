internal import Foundation

/// A typed error thrown by ``JSONLCodec`` when it cannot decode its input.
///
/// Per `WIRE-1`, `ApusKitWireFormat` is the only target where typed
/// `throws` is permitted; per `ERR-2` the error is still a struct wrapping
/// a `@nonexhaustive` `Code` enum, not a public enum of its own.
public struct JSONLDecodeError: Sendable, Equatable, Error {
  /// The category of failure a ``JSONLDecodeError`` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// A complete line's bytes could not be decoded as UTF-8.
    case invalidUTF8
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates a decode error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

/// The result of splitting a byte buffer into JSONL lines.
public struct JSONLDecodeResult: Sendable, Equatable {
  /// Complete lines found in the buffer, in order, line terminator excluded.
  public var lines: [String]

  /// Bytes following the last line terminator, if the buffer did not end
  /// on one. Empty when the buffer was fully consumed into `lines`.
  public var trailing: [UInt8]

  /// Creates a decode result.
  public init(lines: [String], trailing: [UInt8]) {
    self.lines = lines
    self.trailing = trailing
  }
}

/// Encodes and decodes newline-delimited JSON (JSONL) byte buffers.
///
/// `JSONLCodec` is a generic line-level kernel: it knows nothing about
/// session semantics — header lines, entry types, and the like — it only
/// splits a byte buffer into complete, `LF`-terminated lines and
/// reassembles lines into `LF`-terminated bytes. Higher-level session
/// structure is layered on top of it elsewhere.
///
/// `decode(_:)` is tolerant of a trailing partial line: bytes after the
/// last `LF` are returned as `trailing` rather than treated as an error,
/// so a caller reading a file that was truncated mid-write (or a chunk
/// boundary that split a line) can decide what to do with the remainder —
/// including feeding it back in with the next chunk. Encoding every line
/// `decode(_:)` returned with `encode(_:)` reproduces the original bytes
/// exactly, up to any undecoded `trailing` remainder.
public enum JSONLCodec {
  /// Splits `bytes` into complete JSON lines and any trailing partial line.
  ///
  /// A line is delimited by `LF` (`0x0A`); the terminator is not included
  /// in the returned line. Bytes after the final `LF` — including all of
  /// `bytes` if it contains no `LF` at all — are returned as `trailing`,
  /// undecoded.
  ///
  /// - Parameter bytes: The buffer to split, e.g. a whole session file or
  ///   the next chunk of one.
  /// - Throws: `JSONLDecodeError` if a complete line's bytes are not valid
  ///   UTF-8.
  /// - Complexity: O(*n*) in the number of bytes in `bytes`.
  public static func decode(
    _ bytes: some Sequence<UInt8>
  ) throws(JSONLDecodeError) -> JSONLDecodeResult {
    let buffer = Array(bytes)
    var lines: [String] = []
    var lineStart = buffer.startIndex
    var i = buffer.startIndex
    while i < buffer.endIndex {
      if buffer[i] == 0x0A {
        guard let line = String(bytes: buffer[lineStart..<i], encoding: .utf8) else {
          throw JSONLDecodeError(code: .invalidUTF8, message: "JSONL line is not valid UTF-8")
        }
        lines.append(line)
        i += 1
        lineStart = i
      } else {
        i += 1
      }
    }
    return JSONLDecodeResult(lines: lines, trailing: Array(buffer[lineStart...]))
  }

  /// Encodes `lines` as `LF`-terminated JSONL bytes, in order.
  ///
  /// Every line, including the last, is terminated with a single `LF` —
  /// there is no trailing-newline special case, so the result is always
  /// what `decode(_:)` accepts with an empty `trailing` remainder.
  ///
  /// - Parameter lines: The lines to encode, each already-serialized JSON
  ///   text (no embedded `LF`).
  /// - Complexity: O(*n*) in the total length of `lines`.
  public static func encode(_ lines: some Sequence<String>) -> [UInt8] {
    var result: [UInt8] = []
    for line in lines {
      result.append(contentsOf: line.utf8)
      result.append(0x0A)
    }
    return result
  }
}
