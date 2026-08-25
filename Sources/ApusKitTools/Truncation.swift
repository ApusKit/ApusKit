internal import Foundation

/// The outcome of head-truncating a piece of text with `headTruncate`.
public struct TruncatedText: Sendable, Equatable {
  /// The text for the requested `offset`/`limit` window, itself
  /// byte-capped at `maxBytes`.
  public var text: String

  /// Whether the source held more, past `offset + linesReturned` lines or
  /// `maxBytes` bytes, than this window returned.
  public var isTruncated: Bool

  /// How many whole source lines `text` covers.
  ///
  /// This is the `offset` step for continuation: it is `limit` when the
  /// line cap ended the window, and fewer when the byte cap ended it first
  /// (`R8`). It is `0` only when a single line alone exceeds `maxBytes`.
  public var linesReturned: Int

  /// The line count of the untruncated source text.
  public var originalLineCount: Int

  /// The UTF-8 byte count of the untruncated source text.
  public var originalByteCount: Int
}

/// Head-truncates `text` at `limit` lines or `maxBytes` UTF-8 bytes,
/// whichever comes first (`TRUNC-1`).
///
/// Pass `offset` (a line count) on a later call to fetch the remainder of a
/// text a previous call truncated: advance it by the previous call's
/// `linesReturned`, not by `limit` (`R8`). The two differ whenever the byte
/// cap ended the window before `limit` did, so stepping by `limit` would
/// skip the lines the byte cap held back.
///
/// The byte cap ends on a line boundary, so a window never contains half a
/// line and never cuts a Unicode scalar in half. The one case line offset
/// cannot step past is a single line that alone exceeds `maxBytes`: that
/// window is returned byte-capped at a scalar boundary with
/// `linesReturned == 0`. `TRUNC-1` leaves spilling such a payload to the
/// consumer.
///
/// - Complexity: O(*n*) in the length of `text`.
public func headTruncate(
  _ text: String,
  offset: Int = 0,
  limit: Int = 2000,
  maxBytes: Int = 50_000
) -> TruncatedText {
  let allLines = text.components(separatedBy: "\n")
  let originalLineCount = allLines.count
  let originalByteCount = text.utf8.count

  let start = min(max(offset, 0), allLines.count)
  let end = min(start + max(limit, 0), allLines.count)
  let windowLines = allLines[start..<end]
  let windowText = windowLines.joined(separator: "\n")

  guard windowText.utf8.count > maxBytes else {
    return TruncatedText(
      text: windowText,
      isTruncated: end < allLines.count,
      linesReturned: windowLines.count,
      originalLineCount: originalLineCount,
      originalByteCount: originalByteCount
    )
  }

  // Take whole lines while they fit, so the window ends on a line boundary
  // and `start + linesReturned` is a valid continuation offset.
  var usedBytes = 0
  var fittingLines = 0
  for line in windowLines {
    // Every line after the first costs its preceding "\n".
    let cost = line.utf8.count + (fittingLines == 0 ? 0 : 1)
    if usedBytes + cost > maxBytes { break }
    usedBytes += cost
    fittingLines += 1
  }

  guard fittingLines > 0 else {
    // One line on its own is over the cap. Cut it at a scalar boundary
    // rather than emitting a replacement character.
    return TruncatedText(
      text: String(
        decoding: scalarAlignedPrefix(of: windowText, maxBytes: maxBytes), as: UTF8.self),
      isTruncated: true,
      linesReturned: 0,
      originalLineCount: originalLineCount,
      originalByteCount: originalByteCount
    )
  }

  return TruncatedText(
    text: windowLines.prefix(fittingLines).joined(separator: "\n"),
    isTruncated: true,
    linesReturned: fittingLines,
    originalLineCount: originalLineCount,
    originalByteCount: originalByteCount
  )
}

/// The longest prefix of `text`'s UTF-8 that is at most `maxBytes` long and
/// ends on a Unicode scalar boundary.
///
/// Backing off over continuation bytes (`0b10xxxxxx`) is the same technique
/// `AnthropicMessagesAPI` uses to avoid emitting half a scalar.
private func scalarAlignedPrefix(of text: String, maxBytes: Int) -> ArraySlice<UInt8> {
  let bytes = Array(text.utf8)
  var cut = min(max(maxBytes, 0), bytes.count)
  while cut > 0, cut < bytes.count, bytes[cut] & 0xC0 == 0x80 {
    cut -= 1
  }
  return bytes[0..<cut]
}
