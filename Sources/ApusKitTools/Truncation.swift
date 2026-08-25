internal import Foundation

/// The outcome of head-truncating a piece of text with `headTruncate`.
public struct TruncatedText: Sendable, Equatable {
  /// The text for the requested `offset`/`limit` window, itself
  /// byte-capped at `maxBytes`.
  public var text: String

  /// Whether the source held more, past `offset + limit` lines or
  /// `maxBytes` bytes, than this window returned.
  public var isTruncated: Bool

  /// The line count of the untruncated source text.
  public var originalLineCount: Int

  /// The UTF-8 byte count of the untruncated source text.
  public var originalByteCount: Int
}

/// Head-truncates `text` at `limit` lines or `maxBytes` UTF-8 bytes,
/// whichever comes first (`TRUNC-1`).
///
/// Pass `offset` (a line count) on a later call to fetch the remainder of
/// a text a previous call truncated — e.g. call again with `offset` set
/// to the `limit` used on the first call to continue right after it
/// (`R8`).
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
  let windowText = allLines[start..<end].joined(separator: "\n")

  let windowBytes = Array(windowText.utf8)
  let byteCapped = windowBytes.count > maxBytes
  let outputText =
    byteCapped ? String(decoding: windowBytes.prefix(maxBytes), as: UTF8.self) : windowText

  return TruncatedText(
    text: outputText,
    isTruncated: byteCapped || end < allLines.count,
    originalLineCount: originalLineCount,
    originalByteCount: originalByteCount
  )
}
