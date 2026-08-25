public import ApusKitCore

/// One message carried by a `.message` session entry.
///
/// Wraps `ApusKitCore`'s three message types in a single union, mirroring
/// `ApusKitProviders`' `LLMRequestMessage`. `ApusKitSessions` cannot
/// import `ApusKitProviders` (`PKG-6`), so it defines its own equivalent
/// union here rather than reusing that one.
@nonexhaustive(warn)
public enum SessionMessage: Sendable, Codable, Equatable {
  /// A message from the user.
  case user(UserMessage)

  /// A prior message from the model.
  case assistant(AssistantMessage)

  /// The result of a prior tool call.
  case toolResult(ToolResultMessage)
}

/// The type-specific payload of a ``SessionEntry``.
///
/// Covers the eight entry types pi's v3 session format defines: a
/// conversational `message`; a `compaction` that replaces a range of
/// ancestor entries with a summary; a `branchSummary` describing a fork;
/// opaque `custom` and `customMessage` payloads for extensions (`WF-1`
/// journals workflow steps as `custom` entries); a named `label`; and
/// `modelChange` / `thinkingLevelChange` records of mid-session
/// configuration changes. Cases are named per Swift's API Design
/// Guidelines (`API-2`); they correspond one-to-one with `§3.5`'s
/// `message, compaction, branch_summary, custom, custom_message, label,
/// model_change, thinking_level_change`.
@nonexhaustive(warn)
public enum SessionEntryKind: Sendable, Codable, Equatable {
  /// A conversational message.
  case message(SessionMessage)

  /// A record replacing the ancestor entries from the session root
  /// through `replacedThrough` with `summary`, keeping `retainedTail`
  /// verbatim.
  ///
  /// `retainedTail` holds the most recent messages kept as-is (pi's
  /// compaction retains ~20 000 recent tokens); `summary` covers
  /// everything older, up to and including the entry identified by
  /// `replacedThrough`. Rebuilding context at a `compaction` entry
  /// substitutes `summary` and `retainedTail` for that ancestor range
  /// instead of walking past it.
  case compaction(summary: String, retainedTail: [SessionMessage], replacedThrough: EntryID)

  /// A summary describing the history on a branch, e.g. after a fork.
  case branchSummary(summary: String)

  /// An opaque, extension-defined payload that is not itself a message.
  ///
  /// `kind` names the payload's shape for the consumer that produced it;
  /// `payloadJSON` carries it as already-serialized JSON text (mirroring
  /// `ContentBlock.toolCall`'s `argumentsJSON`) so `ApusKitSessions`
  /// stays free of a JSON-value dependency (`PKG-6`).
  case custom(kind: String, payloadJSON: String)

  /// An opaque, extension-defined payload that behaves like a message
  /// entry in the session tree, e.g. a UI-only or system-authored
  /// message a consumer wants to journal.
  case customMessage(kind: String, payloadJSON: String)

  /// A named marker on an entry, e.g. a branch or checkpoint name.
  case label(name: String)

  /// A record that the active model changed mid-session.
  case modelChange(model: String)

  /// A record that the active thinking/reasoning level changed
  /// mid-session.
  case thinkingLevelChange(level: String)
}

/// One node in a session's history tree.
///
/// Entries form a tree via `parentID`: `id`/`parentID` are 8-hex
/// ``EntryID``s, so branching from any entry — or forking an alternative
/// continuation — is just appending a new entry under the branch point's
/// id, with no rewriting of existing lines (`§3.5`).
public struct SessionEntry: Sendable, Codable, Equatable {
  /// This entry's id.
  public var id: EntryID

  /// The id of the entry this one was appended under, or `nil` at the
  /// session root.
  public var parentID: EntryID?

  /// This entry's type-specific payload.
  public var kind: SessionEntryKind

  /// Creates a session entry.
  public init(id: EntryID, parentID: EntryID?, kind: SessionEntryKind) {
    self.id = id
    self.parentID = parentID
    self.kind = kind
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case parentID = "parentId"
    case kind
  }
}
