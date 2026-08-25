// TruncationTests
//
// Coverage for `headTruncate` (TRUNC-1): the 2000-line/50 KB head cap, and
// offset/limit continuation (R8).

import ApusKitTools
import Testing

@Suite("headTruncate")
struct TruncationTests {
  @Test("text under both caps is returned unchanged and not marked truncated")
  func shortTextIsNotTruncated() {
    let text = "line 1\nline 2\nline 3"
    let result = headTruncate(text)

    #expect(result.text == text)
    #expect(!result.isTruncated)
    #expect(result.originalLineCount == 3)
    #expect(result.originalByteCount == text.utf8.count)
  }

  @Test("TRUNC-1: text over the line cap is head-truncated at 2000 lines")
  func truncatesAtLineCap() {
    let lines = (1...2500).map { "line \($0)" }
    let text = lines.joined(separator: "\n")

    let result = headTruncate(text)

    #expect(result.isTruncated)
    #expect(result.text == lines.prefix(2000).joined(separator: "\n"))
    #expect(result.originalLineCount == 2500)
    #expect(result.originalByteCount == text.utf8.count)
  }

  @Test("TRUNC-1: text over the byte cap is head-truncated at 50 KB even under the line cap")
  func truncatesAtByteCap() {
    // Ten lines, each 10 KB: well under 2000 lines, well over 50 KB.
    let line = String(repeating: "x", count: 10_000)
    let lines = Array(repeating: line, count: 10)
    let text = lines.joined(separator: "\n")

    let result = headTruncate(text)

    #expect(result.isTruncated)
    #expect(result.text.utf8.count == 50_000)
    #expect(result.originalLineCount == 10)
    #expect(result.originalByteCount == text.utf8.count)
  }

  @Test("R8: offset/limit continuation serves the remainder of a previously truncated text")
  func offsetLimitContinuesPastAPreviousWindow() {
    let lines = (1...10).map { "line \($0)" }
    let text = lines.joined(separator: "\n")

    let first = headTruncate(text, limit: 4)
    #expect(first.isTruncated)
    #expect(first.text == lines[0..<4].joined(separator: "\n"))

    let second = headTruncate(text, offset: 4, limit: 4)
    #expect(second.isTruncated)
    #expect(second.text == lines[4..<8].joined(separator: "\n"))

    let third = headTruncate(text, offset: 8, limit: 4)
    #expect(!third.isTruncated)
    #expect(third.text == lines[8..<10].joined(separator: "\n"))
  }

  @Test("an offset past the end of the text returns empty, non-crashing text")
  func offsetPastEndReturnsEmpty() {
    let text = "line 1\nline 2"
    let result = headTruncate(text, offset: 100, limit: 10)

    #expect(result.text == "")
    #expect(result.originalLineCount == 2)
  }
}
