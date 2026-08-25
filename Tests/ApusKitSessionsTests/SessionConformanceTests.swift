// SessionConformanceTests
//
// SESS-1 / R8: a pi-v3-format session fixture loads, rebuilds context
// equivalently, and round-trips losslessly.
//
// IMPORTANT — provenance, not wire-compat: TEST-3 names "recorded pi v3
// session files" as the fixture source, but no real, licensed pi session
// file exists in this repo (see Tests/Fixtures/conformance-baseline.yml).
// `Tests/Fixtures/sessions/pi-v3-session.jsonl` is instead authored from
// pi's PUBLIC v3 format (§3.5: 8-hex EntryID ids/parentIds, the eight
// named entry kinds) together with this target's own
// SessionEntry/SessionFileCodec — fixture and codec were authored
// together. This suite therefore proves SELF-CONSISTENCY (the fixture
// decodes with this codec, rebuilds context as this codec's own rules
// predict, and round-trips through it losslessly), not byte-compatibility
// with a real pi installation. SESS-1 stays open until a real pi v3 file
// can be substituted for this authored one.

import ApusKitCore
import ApusKitSessions
import Foundation
import TestSupport
import Testing

private func id(_ hex: String) throws -> EntryID {
  try EntryID(hex: hex)
}

/// Renders a rebuilt context as one deterministic line per item, to
/// compare against an inline expected literal (`TEST-4`).
private func dump(_ items: [ContextItem]) -> String {
  items.map(dump).joined(separator: "\n")
}

private func dump(_ item: ContextItem) -> String {
  switch item {
  case .message(let message):
    return "message(\(dump(message)))"
  case .summary(let text):
    return "summary(\(String(reflecting: text)))"
  }
}

private func dump(_ message: SessionMessage) -> String {
  switch message {
  case .user(let user):
    return "user(\(dump(user.content)))"
  case .assistant(let assistant):
    return "assistant(\(dump(assistant.content)), \(assistant.stopReason), \(assistant.usage))"
  case .toolResult(let toolResult):
    return
      "toolResult(\(String(reflecting: toolResult.toolCallID)), \(dump(toolResult.content)), isError: \(toolResult.isError))"
  }
}

private func dump(_ blocks: [ContentBlock]) -> String {
  "[" + blocks.map(dump).joined(separator: ", ") + "]"
}

private func dump(_ block: ContentBlock) -> String {
  switch block {
  case .text(let text):
    return "text(\(String(reflecting: text)))"
  case .image(_, let mimeType):
    return "image(mimeType: \(String(reflecting: mimeType)))"
  case .thinking(let text):
    return "thinking(\(String(reflecting: text)))"
  case .toolCall(let toolCallID, let name, let argumentsJSON):
    return
      "toolCall(\(String(reflecting: toolCallID)), \(String(reflecting: name)), \(String(reflecting: argumentsJSON)))"
  }
}

@Suite("pi v3 session fixture conformance")
struct SessionConformanceTests {
  /// The header the fixture file was authored with.
  private static func referenceHeader() throws -> SessionHeader {
    SessionHeader(version: SessionHeader.currentVersion, sessionID: try id("c0ffee00"))
  }

  /// The entries the fixture file was authored with, in file order.
  ///
  /// Exercises all eight `SessionEntryKind` cases (`§3.5`), plus a branch
  /// (`00000008` gains a second child, `0000000f`, diverging mid-history
  /// while `00000009` continues the main line) and a fork (`0000000e`
  /// gains two sibling children, `00000011` and `00000012`, forking two
  /// alternative closing replies) and one compaction (`0000000d`).
  private static func referenceEntries() throws -> [SessionEntry] {
    let e1 = try id("00000001")
    let e2 = try id("00000002")
    let e3 = try id("00000003")
    let e4 = try id("00000004")
    let e5 = try id("00000005")
    let e6 = try id("00000006")
    let e7 = try id("00000007")
    let e8 = try id("00000008")
    let e9 = try id("00000009")
    let e10 = try id("0000000a")
    let e11 = try id("0000000b")
    let e12 = try id("0000000c")
    let e13 = try id("0000000d")
    let e14 = try id("0000000e")
    let e15 = try id("0000000f")
    let e16 = try id("00000010")
    let e17 = try id("00000011")
    let e18 = try id("00000012")

    return [
      // The main line: a user turn, a tool-using assistant reply, its
      // result, a model change, and the assistant's final answer.
      SessionEntry(
        id: e1, parentID: nil,
        kind: .message(.user(UserMessage(content: [.text("What's the weather in Paris today?")])))
      ),
      SessionEntry(id: e2, parentID: e1, kind: .label(name: "turn-1")),
      SessionEntry(
        id: e3, parentID: e2,
        kind: .message(
          .assistant(
            AssistantMessage(
              content: [
                .toolCall(id: "call_1", name: "get_weather", argumentsJSON: #"{"city":"Paris"}"#)
              ],
              stopReason: .toolUse,
              usage: Usage(inputTokens: 120, outputTokens: 18)
            )
          ))
      ),
      SessionEntry(
        id: e4, parentID: e3,
        kind: .message(
          .toolResult(
            ToolResultMessage(
              toolCallID: "call_1", content: [.text("15°C, partly cloudy")], isError: false)))
      ),
      SessionEntry(id: e5, parentID: e4, kind: .modelChange(model: "claude-opus-5")),
      SessionEntry(
        id: e6, parentID: e5,
        kind: .message(
          .assistant(
            AssistantMessage(
              content: [.text("It's 15°C and partly cloudy in Paris.")],
              stopReason: .endTurn,
              usage: Usage(inputTokens: 140, outputTokens: 12)
            )
          ))
      ),
      SessionEntry(id: e7, parentID: e6, kind: .thinkingLevelChange(level: "high")),

      // The branch point: e8 is a second user turn. The main line
      // continues to e9; a second, alternate continuation is appended
      // later (e15) directly under e8, branching from it.
      SessionEntry(
        id: e8, parentID: e7,
        kind: .message(
          .user(UserMessage(content: [.text("Now check London too, and remember this for later.")]))
        )
      ),
      SessionEntry(
        id: e9, parentID: e8,
        kind: .custom(kind: "workflow.step", payloadJSON: #"{"step":"scheduled-followup"}"#)),
      SessionEntry(
        id: e10, parentID: e9,
        kind: .message(
          .assistant(
            AssistantMessage(
              content: [
                .thinking("Need to call get_weather for London"),
                .toolCall(id: "call_2", name: "get_weather", argumentsJSON: #"{"city":"London"}"#),
              ],
              stopReason: .toolUse,
              usage: Usage(inputTokens: 160, outputTokens: 22)
            )
          ))
      ),
      SessionEntry(
        id: e11, parentID: e10,
        kind: .message(
          .toolResult(
            ToolResultMessage(toolCallID: "call_2", content: [.text("12°C, rain")], isError: false))
        )
      ),
      SessionEntry(
        id: e12, parentID: e11,
        kind: .customMessage(kind: "system-note", payloadJSON: #"{"note":"reminder scheduled"}"#)),

      // The compaction: replaces e1...e12 with a summary plus a
      // retained tail, then the main line's final reply (e14, the leaf
      // that the fork below branches from).
      SessionEntry(
        id: e13, parentID: e12,
        kind: .compaction(
          summary: "earlier turns covering Paris and London weather were summarized",
          retainedTail: [
            .assistant(
              AssistantMessage(
                content: [.text("London is 12°C with rain.")],
                stopReason: .endTurn,
                usage: Usage(inputTokens: 150, outputTokens: 10)
              ))
          ],
          replacedThrough: e12
        )
      ),
      SessionEntry(
        id: e14, parentID: e13,
        kind: .message(
          .assistant(
            AssistantMessage(
              content: [.text("Got it, I'll keep that in mind.")],
              stopReason: .endTurn,
              usage: Usage(inputTokens: 200, outputTokens: 9)
            )))
      ),

      // The branch: an alternate continuation appended under e8, the
      // earlier user turn, diverging from the main line at e9.
      SessionEntry(
        id: e15, parentID: e8,
        kind: .branchSummary(summary: "explored a shorter reply without scheduling a followup")),
      SessionEntry(
        id: e16, parentID: e15,
        kind: .message(
          .assistant(
            AssistantMessage(
              content: [.text("Sure — just let me check the weather for London.")],
              stopReason: .endTurn,
              usage: Usage(inputTokens: 130, outputTokens: 14)
            )
          ))
      ),

      // The fork: two alternative closing replies appended under the
      // same parent, e14.
      SessionEntry(
        id: e17, parentID: e14,
        kind: .message(
          .assistant(
            AssistantMessage(
              content: [.text("Anything else I can help with?")],
              stopReason: .endTurn,
              usage: Usage(inputTokens: 210, outputTokens: 8)
            )
          ))
      ),
      SessionEntry(
        id: e18, parentID: e14,
        kind: .message(
          .assistant(
            AssistantMessage(
              content: [.text("Let me know if you need more cities.")],
              stopReason: .endTurn,
              usage: Usage(inputTokens: 210, outputTokens: 9)
            )
          ))
      ),
    ]
  }

  private static func fixtureBytes() throws -> [UInt8] {
    let url = Fixtures.directory.appendingPathComponent("sessions/pi-v3-session.jsonl")
    return [UInt8](try Data(contentsOf: url))
  }

  @Test("the fixture decodes into exactly the entries it was authored from")
  func fixtureLoads() throws {
    let result = try SessionFileCodec.decode(try Self.fixtureBytes())

    #expect(result.header == (try Self.referenceHeader()))
    #expect(result.entries == (try Self.referenceEntries()))
    #expect(result.trailing.isEmpty)
  }

  @Test("the fixture exercises all eight SessionEntryKind cases")
  func fixtureCoversAllEightKinds() throws {
    var seenMessage = false
    var seenCompaction = false
    var seenBranchSummary = false
    var seenCustom = false
    var seenCustomMessage = false
    var seenLabel = false
    var seenModelChange = false
    var seenThinkingLevelChange = false

    for entry in try Self.referenceEntries() {
      switch entry.kind {
      case .message: seenMessage = true
      case .compaction: seenCompaction = true
      case .branchSummary: seenBranchSummary = true
      case .custom: seenCustom = true
      case .customMessage: seenCustomMessage = true
      case .label: seenLabel = true
      case .modelChange: seenModelChange = true
      case .thinkingLevelChange: seenThinkingLevelChange = true
      @unknown default: break
      }
    }

    #expect(seenMessage)
    #expect(seenCompaction)
    #expect(seenBranchSummary)
    #expect(seenCustom)
    #expect(seenCustomMessage)
    #expect(seenLabel)
    #expect(seenModelChange)
    #expect(seenThinkingLevelChange)
  }

  @Test(
    "decoding the fixture, re-encoding it, and decoding again reproduces the same header and entries"
  )
  func fixtureRoundTripsLosslessly() throws {
    // `JSONEncoder` does not guarantee stable key ordering across calls
    // (confirmed empirically: encoding the same value twice in one
    // process can already reorder its keys), so `SessionFileCodec`
    // cannot promise byte-identical output. Losslessness is instead
    // decode -> encode -> decode producing the same structured data, not
    // encode producing the same bytes.
    let originalBytes = try Self.fixtureBytes()
    let decoded = try SessionFileCodec.decode(originalBytes)

    let reencoded = try SessionFileCodec.encode(header: decoded.header, entries: decoded.entries)
    let redecoded = try SessionFileCodec.decode(reencoded)

    #expect(redecoded.header == decoded.header)
    #expect(redecoded.entries == decoded.entries)
    #expect(redecoded.trailing.isEmpty)
  }

  @Test("00000008 branches into a second continuation, and 0000000e forks two closing replies")
  func fixtureTreeHasABranchAndAFork() throws {
    let decoded = try SessionFileCodec.decode(try Self.fixtureBytes())
    let session = Session(header: decoded.header, entries: decoded.entries)

    let branchPoint = try id("00000008")
    let forkPoint = try id("0000000e")
    #expect(session.children(of: branchPoint) == [try id("00000009"), try id("0000000f")])
    #expect(session.children(of: forkPoint) == [try id("00000011"), try id("00000012")])
    #expect(
      Set(session.leaves()) == Set([try id("00000010"), try id("00000011"), try id("00000012")]))
  }

  @Test(
    "rebuilding context on the main line substitutes the compaction's summary and retained tail")
  func rebuildsContextThroughCompaction() throws {
    let decoded = try SessionFileCodec.decode(try Self.fixtureBytes())
    let session = Session(header: decoded.header, entries: decoded.entries)

    let items = try session.buildContext(leaf: id("0000000e"))

    #expect(
      dump(items) == """
        summary("earlier turns covering Paris and London weather were summarized")
        message(assistant([text("London is 12°C with rain.")], endTurn, Usage(inputTokens: 150, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)))
        message(assistant([text("Got it, I\\'ll keep that in mind.")], endTurn, Usage(inputTokens: 200, outputTokens: 9, cacheReadTokens: 0, cacheWriteTokens: 0)))
        """
    )
  }

  @Test(
    "both forked leaves rebuild the same context through the shared compaction, plus their own reply"
  )
  func rebuildsContextOnBothForkedLeaves() throws {
    let decoded = try SessionFileCodec.decode(try Self.fixtureBytes())
    let session = Session(header: decoded.header, entries: decoded.entries)

    let leafA = try session.buildContext(leaf: id("00000011"))
    let leafB = try session.buildContext(leaf: id("00000012"))

    #expect(
      dump(leafA) == """
        summary("earlier turns covering Paris and London weather were summarized")
        message(assistant([text("London is 12°C with rain.")], endTurn, Usage(inputTokens: 150, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)))
        message(assistant([text("Got it, I\\'ll keep that in mind.")], endTurn, Usage(inputTokens: 200, outputTokens: 9, cacheReadTokens: 0, cacheWriteTokens: 0)))
        message(assistant([text("Anything else I can help with?")], endTurn, Usage(inputTokens: 210, outputTokens: 8, cacheReadTokens: 0, cacheWriteTokens: 0)))
        """
    )
    #expect(
      dump(leafB) == """
        summary("earlier turns covering Paris and London weather were summarized")
        message(assistant([text("London is 12°C with rain.")], endTurn, Usage(inputTokens: 150, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)))
        message(assistant([text("Got it, I\\'ll keep that in mind.")], endTurn, Usage(inputTokens: 200, outputTokens: 9, cacheReadTokens: 0, cacheWriteTokens: 0)))
        message(assistant([text("Let me know if you need more cities.")], endTurn, Usage(inputTokens: 210, outputTokens: 9, cacheReadTokens: 0, cacheWriteTokens: 0)))
        """
    )
  }

  @Test(
    "the branched leaf rebuilds context walking through 00000008 with no compaction, skipping non-contributing entries"
  )
  func rebuildsContextOnTheBranchedLeaf() throws {
    let decoded = try SessionFileCodec.decode(try Self.fixtureBytes())
    let session = Session(header: decoded.header, entries: decoded.entries)

    let items = try session.buildContext(leaf: id("00000010"))

    #expect(
      dump(items) == """
        message(user([text("What\\'s the weather in Paris today?")]))
        message(assistant([toolCall("call_1", "get_weather", "{\\"city\\":\\"Paris\\"}")], toolUse, Usage(inputTokens: 120, outputTokens: 18, cacheReadTokens: 0, cacheWriteTokens: 0)))
        message(toolResult("call_1", [text("15°C, partly cloudy")], isError: false))
        message(assistant([text("It\\'s 15°C and partly cloudy in Paris.")], endTurn, Usage(inputTokens: 140, outputTokens: 12, cacheReadTokens: 0, cacheWriteTokens: 0)))
        message(user([text("Now check London too, and remember this for later.")]))
        message(assistant([text("Sure — just let me check the weather for London.")], endTurn, Usage(inputTokens: 130, outputTokens: 14, cacheReadTokens: 0, cacheWriteTokens: 0)))
        """
    )
    // The label, model-change, thinking-level-change and branch-summary
    // entries on this path do not contribute to the rebuilt context.
    #expect(!dump(items).contains("turn-1"))
    #expect(!dump(items).contains("claude-opus-5"))
  }
}
