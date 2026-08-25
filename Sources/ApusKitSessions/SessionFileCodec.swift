internal import ApusKitWireFormat
internal import Foundation

/// An error encoding or decoding a session file.
///
/// Per `ERR-2`, this is a struct wrapping a `@nonexhaustive` `Code` enum
/// rather than a public enum of its own.
public struct SessionFileDecodeError: Sendable, Equatable, Error {
  /// The category of failure a ``SessionFileDecodeError`` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// The buffer's bytes could not be split into JSONL lines, e.g. a
    /// complete line was not valid UTF-8.
    case invalidLineEncoding

    /// The buffer had no header line to decode.
    case missingHeader

    /// The header line's bytes could not be decoded as a
    /// ``SessionHeader``.
    case invalidHeader

    /// An entry line's bytes could not be decoded as a ``SessionEntry``.
    case invalidEntry
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

/// The result of decoding a session file.
public struct SessionFileDecodeResult: Sendable, Equatable {
  /// The session's header.
  public var header: SessionHeader

  /// The session's entries, in file order.
  public var entries: [SessionEntry]

  /// Bytes following the last complete line, if the buffer did not end on
  /// a line terminator. Empty when the buffer was fully consumed.
  public var trailing: [UInt8]

  /// Creates a decode result.
  public init(header: SessionHeader, entries: [SessionEntry], trailing: [UInt8]) {
    self.header = header
    self.entries = entries
    self.trailing = trailing
  }
}

/// Encodes and decodes a session file: a header line followed by entry
/// lines, layered on `ApusKitWireFormat`'s line-level JSONL kernel.
///
/// Per `WIRE-1`/`ASM-6`, line splitting and reassembly live in
/// `ApusKitWireFormat`'s `JSONLCodec`; `SessionFileCodec` only knows the
/// session-specific shape on top of it — the first line is a header, the
/// rest are entries.
public enum SessionFileCodec {
  /// Encodes `header` and `entries` as `LF`-terminated JSONL bytes.
  ///
  /// - Complexity: O(*n*) in the total size of `header` and `entries`.
  public static func encode(
    header: SessionHeader,
    entries: some Sequence<SessionEntry>
  ) throws -> [UInt8] {
    let encoder = JSONEncoder()
    var lines: [String] = [try Self.encodeLine(header, using: encoder)]
    for entry in entries {
      lines.append(try Self.encodeLine(entry, using: encoder))
    }
    return JSONLCodec.encode(lines)
  }

  private static func encodeLine(_ value: some Encodable, using encoder: JSONEncoder) throws
    -> String
  {
    let data = try encoder.encode(value)
    guard let line = String(data: data, encoding: .utf8) else {
      // JSONEncoder always emits UTF-8 text; unreachable in practice.
      throw SessionFileDecodeError(
        code: .invalidHeader,
        message: "JSON encoder produced non-UTF-8 output"
      )
    }
    return line
  }

  /// Decodes `bytes` as a session file's header and entries.
  ///
  /// Tolerant of a trailing partial line: bytes after the last complete
  /// line are returned as `SessionFileDecodeResult.trailing` rather than
  /// treated as an error, so a caller reading a file that is still being
  /// appended to (or a chunk boundary that split a line) can decide what
  /// to do with the remainder — including feeding it back in with the
  /// next chunk.
  ///
  /// - Throws: `SessionFileDecodeError` if the lines cannot be split from
  ///   `bytes`, the buffer has no header line, or a header or entry line
  ///   cannot be decoded.
  /// - Complexity: O(*n*) in the number of bytes in `bytes`.
  public static func decode(_ bytes: some Sequence<UInt8>) throws -> SessionFileDecodeResult {
    let split: JSONLDecodeResult
    do {
      split = try JSONLCodec.decode(bytes)
    } catch {
      throw SessionFileDecodeError(code: .invalidLineEncoding, message: "\(error)")
    }
    guard let headerLine = split.lines.first else {
      throw SessionFileDecodeError(code: .missingHeader, message: "session file has no header line")
    }
    let decoder = JSONDecoder()
    let header: SessionHeader
    do {
      header = try decoder.decode(SessionHeader.self, from: Data(headerLine.utf8))
    } catch {
      throw SessionFileDecodeError(code: .invalidHeader, message: "\(error)")
    }
    var entries: [SessionEntry] = []
    entries.reserveCapacity(split.lines.count - 1)
    for line in split.lines.dropFirst() {
      do {
        entries.append(try decoder.decode(SessionEntry.self, from: Data(line.utf8)))
      } catch {
        throw SessionFileDecodeError(code: .invalidEntry, message: "\(error)")
      }
    }
    return SessionFileDecodeResult(header: header, entries: entries, trailing: split.trailing)
  }
}
