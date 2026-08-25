// SessionCodecTests
//
// Coverage for entry ids, the eight `SessionEntryKind` cases, and
// `SessionFileCodec`: a session file is a header line followed by entry
// lines (R2), all eight entry types encode and decode with id/parentId
// as 8-hex identifiers (R3), and decoding tolerates a trailing partial
// line the way the underlying `JSONLCodec` kernel does.

import ApusKitCore
import ApusKitSessions
import Foundation
import Testing

/// A deterministic `RandomNumberGenerator` so `EntryID.random(using:)`
/// tests do not depend on the system's entropy source.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

@Suite("EntryID")
struct EntryIDTests {
  @Test("an 8-hex-character string is accepted and normalized to lowercase")
  func validHexIsAccepted() throws {
    let id = try EntryID(hex: "DEADBEEF")
    #expect(id.hex == "deadbeef")
  }

  @Test(
    "a string that is not exactly 8 hex characters is rejected",
    arguments: [
      "",
      "abc",
      "deadbeef0",
      "deadbee",
    ])
  func wrongLengthIsRejected(_ hex: String) {
    #expect(throws: EntryIDError.self) {
      try EntryID(hex: hex)
    }
  }

  @Test("a string with a non-hex character is rejected")
  func nonHexCharacterIsRejected() {
    #expect(throws: EntryIDError.self) {
      try EntryID(hex: "deadbeeg")
    }
  }

  @Test("random ids are 8 lowercase hex characters and deterministic under a seeded generator")
  func randomIsDeterministicUnderSeededGenerator() {
    var generatorA = SeededGenerator(state: 42)
    var generatorB = SeededGenerator(state: 42)
    let idA = EntryID.random(using: &generatorA)
    let idB = EntryID.random(using: &generatorB)
    #expect(idA == idB)
    #expect(idA.hex.count == 8)
    #expect(idA.hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }

  @Test("decoding an invalid hex string from JSON fails")
  func decodingInvalidHexFails() {
    let json = Data(#""not-hex!""#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(EntryID.self, from: json)
    }
  }
}

@Suite("SessionEntryKind")
struct SessionEntryKindTests {
  private static func sampleMessage() -> SessionMessage {
    .user(UserMessage(content: [.text("hello")]))
  }

  private static func fixedID(_ seed: UInt64) -> EntryID {
    var generator = SeededGenerator(state: seed)
    return EntryID.random(using: &generator)
  }

  /// One instance of every entry kind, exercising R3's eight types.
  private static let allKinds: [SessionEntryKind] = [
    .message(sampleMessage()),
    .compaction(
      summary: "the user asked about weather, then pricing",
      retainedTail: [sampleMessage()],
      replacedThrough: fixedID(1)
    ),
    .branchSummary(summary: "explored an alternative tool call"),
    .custom(kind: "workflow.step", payloadJSON: #"{"step":1}"#),
    .customMessage(kind: "system-note", payloadJSON: #"{"note":"restarted"}"#),
    .label(name: "checkpoint-1"),
    .modelChange(model: "claude-opus-5"),
    .thinkingLevelChange(level: "high"),
  ]

  @Test("every entry kind round-trips through JSON")
  func everyKindRoundTrips() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for kind in Self.allKinds {
      let data = try encoder.encode(kind)
      let decoded = try decoder.decode(SessionEntryKind.self, from: data)
      #expect(decoded == kind)
    }
  }

  @Test("a session entry carrying each kind round-trips through JSON")
  func entryWrappingEachKindRoundTrips() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var generator = SeededGenerator(state: 7)
    for kind in Self.allKinds {
      let entry = SessionEntry(id: EntryID.random(using: &generator), parentID: nil, kind: kind)
      let data = try encoder.encode(entry)
      let decoded = try decoder.decode(SessionEntry.self, from: data)
      #expect(decoded == entry)
    }
  }

  @Test("a non-nil parentID is encoded under the wire key \"parentId\"")
  func parentIDEncodesAsParentId() throws {
    let entry = SessionEntry(
      id: try EntryID(hex: "00000002"),
      parentID: try EntryID(hex: "00000001"),
      kind: .label(name: "x")
    )
    let data = try JSONEncoder().encode(entry)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["parentId"] as? String == "00000001")
    #expect(object["parentID"] == nil)
  }
}

@Suite("SessionFileCodec")
struct SessionFileCodecTests {
  private static func sampleEntries(startingAt generator: inout SeededGenerator) -> [SessionEntry] {
    let kinds: [SessionEntryKind] = [
      .message(.user(UserMessage(content: [.text("hi")]))),
      .message(
        .assistant(
          AssistantMessage(
            content: [.text("hello back")],
            stopReason: .endTurn,
            usage: Usage(inputTokens: 10, outputTokens: 5)
          )
        )
      ),
      .compaction(
        summary: "earlier turns summarized",
        retainedTail: [.user(UserMessage(content: [.text("recent turn")]))],
        replacedThrough: EntryID.random(using: &generator)
      ),
      .branchSummary(summary: "a fork explored a different tool"),
      .custom(kind: "workflow.step", payloadJSON: #"{"ok":true}"#),
      .customMessage(kind: "system-note", payloadJSON: #"{"n":1}"#),
      .label(name: "checkpoint"),
      .modelChange(model: "claude-opus-5"),
      .thinkingLevelChange(level: "medium"),
    ]
    var entries: [SessionEntry] = []
    var previousID: EntryID?
    for kind in kinds {
      let id = EntryID.random(using: &generator)
      entries.append(SessionEntry(id: id, parentID: previousID, kind: kind))
      previousID = id
    }
    return entries
  }

  @Test("a header plus entries covering all eight kinds round-trips losslessly")
  func headerAndEntriesRoundTrip() throws {
    var generator = SeededGenerator(state: 1)
    let header = SessionHeader(
      version: SessionHeader.currentVersion,
      sessionID: EntryID.random(using: &generator)
    )
    let entries = Self.sampleEntries(startingAt: &generator)

    let bytes = try SessionFileCodec.encode(header: header, entries: entries)
    let result = try SessionFileCodec.decode(bytes)

    #expect(result.header == header)
    #expect(result.entries == entries)
    #expect(result.trailing.isEmpty)
  }

  @Test("the file is a header line followed by one line per entry")
  func fileIsHeaderLinePlusOneLinePerEntry() throws {
    var generator = SeededGenerator(state: 2)
    let header = SessionHeader(version: 3, sessionID: EntryID.random(using: &generator))
    let entries = Self.sampleEntries(startingAt: &generator)

    let bytes = try SessionFileCodec.encode(header: header, entries: entries)
    let text = try #require(String(bytes: bytes, encoding: .utf8))
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    #expect(lines.count == entries.count + 1)
  }

  @Test("decoding tolerates a trailing partial line, returning it unconsumed")
  func decodingTruncatedFileToleratesPartialLastLine() throws {
    var generator = SeededGenerator(state: 3)
    let header = SessionHeader(version: 3, sessionID: EntryID.random(using: &generator))
    let entries = Self.sampleEntries(startingAt: &generator)
    let complete = try SessionFileCodec.encode(header: header, entries: entries)

    // Drop the final LF and a few trailing characters of the last
    // entry's line, simulating a file read mid-write.
    let truncated = Array(complete.dropLast(5))

    let result = try SessionFileCodec.decode(truncated)
    #expect(result.header == header)
    #expect(result.entries == entries.dropLast())
    #expect(!result.trailing.isEmpty)
  }

  @Test("decoding an empty buffer throws a missingHeader error")
  func emptyBufferThrowsMissingHeader() {
    #expect(throws: SessionFileDecodeError.self) {
      try SessionFileCodec.decode([UInt8]())
    }
    do {
      _ = try SessionFileCodec.decode([UInt8]())
      Issue.record("expected decode to throw")
    } catch let error as SessionFileDecodeError {
      #expect(error.code == .missingHeader)
    } catch {
      Issue.record("expected a SessionFileDecodeError, got \(error)")
    }
  }

  @Test("decoding a malformed entry line throws an invalidEntry error")
  func malformedEntryLineThrowsInvalidEntry() throws {
    var generator = SeededGenerator(state: 4)
    let header = SessionHeader(version: 3, sessionID: EntryID.random(using: &generator))
    var bytes = try SessionFileCodec.encode(header: header, entries: [])
    bytes.append(contentsOf: Array("not valid json\n".utf8))

    do {
      _ = try SessionFileCodec.decode(bytes)
      Issue.record("expected decode to throw")
    } catch let error as SessionFileDecodeError {
      #expect(error.code == .invalidEntry)
    } catch {
      Issue.record("expected a SessionFileDecodeError, got \(error)")
    }
  }
}
