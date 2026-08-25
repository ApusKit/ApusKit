// ContextRebuildTests
//
// Coverage for `Session.buildContext(leaf:)` (R5): rebuilding a message
// context by walking leaf-to-root, and honouring a compaction entry by
// substituting its stored summary plus retainedTail for the ancestor
// entries it replaced, instead of walking past it.

import ApusKitCore
import ApusKitSessions
import Testing

private func id(_ hex: String) throws -> EntryID {
  try EntryID(hex: hex)
}

/// Renders `items` as one deterministic line per item, to compare against
/// an inline expected literal (TEST-4).
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

@Suite("Session.buildContext(leaf:)")
struct ContextRebuildTests {
  private static func header() throws -> SessionHeader {
    SessionHeader(version: SessionHeader.currentVersion, sessionID: try id("00000000"))
  }

  private static func userMessage(_ text: String) -> SessionMessage {
    .user(UserMessage(content: [.text(text)]))
  }

  private static func assistantMessage(_ text: String) -> SessionMessage {
    .assistant(
      AssistantMessage(
        content: [.text(text)],
        stopReason: .endTurn,
        usage: Usage(inputTokens: 10, outputTokens: 5)
      )
    )
  }

  @Test("with no compaction, buildContext walks root-to-leaf, dropping non-message entries")
  func noCompactionWalksRootToLeaf() throws {
    var session = Session(header: try Self.header())
    let root = SessionEntry(
      id: try id("00000001"), parentID: nil, kind: .message(Self.userMessage("hi")))
    let label = SessionEntry(
      id: try id("00000002"), parentID: root.id, kind: .label(name: "checkpoint"))
    let reply = SessionEntry(
      id: try id("00000003"), parentID: label.id,
      kind: .message(Self.assistantMessage("hello back")))
    session.append(root)
    session.append(label)
    session.append(reply)

    let items = try session.buildContext(leaf: reply.id)

    #expect(
      dump(items) == """
        message(user([text("hi")]))
        message(assistant([text("hello back")], endTurn, Usage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)))
        """
    )
  }

  @Test(
    "a compaction entry substitutes its summary and retainedTail for the ancestor range it replaced"
  )
  func compactionSubstitutesSummaryAndRetainedTail() throws {
    var session = Session(header: try Self.header())
    let turn1User = SessionEntry(
      id: try id("00000001"), parentID: nil, kind: .message(Self.userMessage("turn1")))
    let turn1Reply = SessionEntry(
      id: try id("00000002"), parentID: turn1User.id,
      kind: .message(Self.assistantMessage("turn1 reply")))
    let turn2User = SessionEntry(
      id: try id("00000003"), parentID: turn1Reply.id, kind: .message(Self.userMessage("turn2")))
    let compaction = SessionEntry(
      id: try id("00000004"), parentID: turn2User.id,
      kind: .compaction(
        summary: "earlier turns summarized",
        retainedTail: [Self.userMessage("turn3 recent")],
        replacedThrough: turn2User.id
      ))
    let turn4Reply = SessionEntry(
      id: try id("00000005"), parentID: compaction.id,
      kind: .message(Self.assistantMessage("turn4 reply")))
    session.append(turn1User)
    session.append(turn1Reply)
    session.append(turn2User)
    session.append(compaction)
    session.append(turn4Reply)

    let items = try session.buildContext(leaf: turn4Reply.id)

    #expect(
      dump(items) == """
        summary("earlier turns summarized")
        message(user([text("turn3 recent")]))
        message(assistant([text("turn4 reply")], endTurn, Usage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)))
        """
    )
    // turn1User/turn1Reply/turn2User are replaced by the compaction and
    // must not appear directly in the rebuilt context.
    #expect(!dump(items).contains("turn1"))
    #expect(!dump(items).contains("\"turn2\""))
  }

  @Test(
    "with two compactions on the path, only the one closest to the leaf contributes"
  )
  func repeatedCompactionUsesTheCompactionClosestToTheLeaf() throws {
    var session = Session(header: try Self.header())
    let turn1User = SessionEntry(
      id: try id("00000001"), parentID: nil, kind: .message(Self.userMessage("turn1")))
    let turn1Reply = SessionEntry(
      id: try id("00000002"), parentID: turn1User.id,
      kind: .message(Self.assistantMessage("turn1 reply")))
    let olderCompaction = SessionEntry(
      id: try id("00000003"), parentID: turn1Reply.id,
      kind: .compaction(
        summary: "stale summary of turns 1-2",
        retainedTail: [Self.userMessage("stale retained tail")],
        replacedThrough: turn1Reply.id
      ))
    let turn3User = SessionEntry(
      id: try id("00000004"), parentID: olderCompaction.id,
      kind: .message(Self.userMessage("turn3")))
    let newerCompaction = SessionEntry(
      id: try id("00000005"), parentID: turn3User.id,
      kind: .compaction(
        summary: "fresh summary of everything so far",
        retainedTail: [Self.userMessage("fresh retained tail")],
        replacedThrough: turn3User.id
      ))
    let turn5Reply = SessionEntry(
      id: try id("00000006"), parentID: newerCompaction.id,
      kind: .message(Self.assistantMessage("turn5 reply")))
    session.append(turn1User)
    session.append(turn1Reply)
    session.append(olderCompaction)
    session.append(turn3User)
    session.append(newerCompaction)
    session.append(turn5Reply)

    let items = try session.buildContext(leaf: turn5Reply.id)

    #expect(
      dump(items) == """
        summary("fresh summary of everything so far")
        message(user([text("fresh retained tail")]))
        message(assistant([text("turn5 reply")], endTurn, Usage(inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)))
        """
    )
    // The older compaction, and everything it replaced, sit above the
    // newer one: reaching them would mean walking past the compaction
    // closest to the leaf.
    #expect(!dump(items).contains("stale"))
    #expect(!dump(items).contains("turn1"))
    #expect(!dump(items).contains("turn3"))
  }

  @Test("a compaction entry that is itself the leaf contributes its summary and retainedTail")
  func compactionAtTheLeafContributesSummaryAndRetainedTail() throws {
    var session = Session(header: try Self.header())
    let turn1User = SessionEntry(
      id: try id("00000001"), parentID: nil, kind: .message(Self.userMessage("turn1")))
    let compaction = SessionEntry(
      id: try id("00000002"), parentID: turn1User.id,
      kind: .compaction(
        summary: "turn1 summarized",
        retainedTail: [Self.userMessage("turn2 recent")],
        replacedThrough: turn1User.id
      ))
    session.append(turn1User)
    session.append(compaction)

    let items = try session.buildContext(leaf: compaction.id)

    // The compaction sits at index 0 of the leaf-to-root walk: the range
    // kept must still include it, not stop short of it.
    #expect(
      dump(items) == """
        summary("turn1 summarized")
        message(user([text("turn2 recent")]))
        """
    )
    // The message the compaction replaced must not appear verbatim.
    #expect(!dump(items).contains("text(\"turn1\")"))
  }

  @Test("buildContext(leaf:) throws unknownEntry for a leaf not in the tree")
  func buildContextThrowsForUnknownLeaf() throws {
    let session = Session(header: try Self.header())
    let missing = try id("deadbeef")

    #expect(throws: SessionTreeError.self) {
      try session.buildContext(leaf: missing)
    }
  }
}
