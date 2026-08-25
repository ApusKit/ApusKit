internal import ApusKitCore

/// An error assembling a ``SessionEntryKind/compaction(summary:retainedTail:replacedThrough:)``
/// entry.
///
/// Per `ERR-2`, this is a struct wrapping a `@nonexhaustive` `Code` enum
/// rather than a public enum of its own.
public struct CompactionError: Sendable, Equatable, Error {
  /// The category of failure a ``CompactionError`` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// `tokenCounts` did not have one entry per element of `messages`.
    case tokenCountMismatch

    /// The injected summarizer kept producing a summary over
    /// `summaryTokenBudget` for `maxAttempts` consecutive calls.
    case summarizerExceededAttemptLimit
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates a compaction error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

/// One summarizer attempt's output: the summary text and its token count.
///
/// The token count is supplied by the caller's summarizer rather than
/// measured by a tokenizer this target does not depend on (`DI-1`), so
/// ``Compaction`` can judge whether the summary fits `summaryTokenBudget`
/// without ever counting tokens itself.
public struct CompactionSummary: Sendable, Equatable {
  /// The summary text.
  public var text: String

  /// `text`'s token count, as measured by whatever produced it.
  public var tokenCount: Int

  /// Creates a compaction summary.
  public init(text: String, tokenCount: Int) {
    self.text = text
    self.tokenCount = tokenCount
  }
}

/// Summarizes the messages ``Compaction`` selected for replacement.
///
/// Called once per attempt with the same `messages`; a real
/// implementation asks a model to summarize them, while a scripted test
/// closure can vary its returned ``CompactionSummary`` call by call to
/// exercise iteration. Taking a closure rather than a provider connection
/// keeps this target free of `ApusKitProviders` (`PKG-6`) and out of
/// `ACC-2`'s closed conformable-protocol set.
public typealias CompactionSummarizer =
  @Sendable ([SessionMessage]) async throws ->
  CompactionSummary

/// Compacts an over-budget session context into a
/// ``SessionEntryKind/compaction(summary:retainedTail:replacedThrough:)``
/// entry (`§3.5`, `R6`).
///
/// `16 384` and `20 000` below are normative, ported from pi — they are
/// not tuning knobs.
public enum Compaction {
  /// The default token reserve subtracted from a model's context window
  /// when deciding whether to compact.
  public static let defaultReserve = 16_384

  /// The default number of most-recent tokens a compaction's cut-point
  /// retains verbatim in `retainedTail`.
  public static let defaultRetainedTokens = 20_000

  /// The default bound on how many times ``compact(messages:tokenCounts:replacedThrough:retainedTokens:summaryTokenBudget:maxAttempts:summarize:)``
  /// re-invokes `summarize` before giving up.
  public static let defaultMaxAttempts = 3

  /// Whether a session with `contextTokens` in a `contextWindow`-token
  /// model should compact, i.e. `contextTokens > contextWindow - reserve`.
  public static func shouldCompact(
    contextTokens: Int,
    contextWindow: Int,
    reserve: Int = defaultReserve
  ) -> Bool {
    contextTokens > contextWindow - reserve
  }

  /// Where to cut a leaf-to-root-ordered context so the tail retains
  /// approximately `retainedTokens` of the most recent tokens.
  public struct CutPoint: Sendable, Equatable {
    /// The index into the messages passed to ``cutPoint(tokenCounts:retainedTokens:)``
    /// at which the retained tail begins: messages before this index are
    /// summarized, messages from this index onward are kept verbatim.
    public var index: Int

    /// The tail's actual accumulated token count, which may run slightly
    /// over `retainedTokens` since a whole message is never split.
    public var retainedTokens: Int

    /// Creates a cut point.
    public init(index: Int, retainedTokens: Int) {
      self.index = index
      self.retainedTokens = retainedTokens
    }
  }

  /// Selects the cut point that keeps roughly `retainedTokens` of the
  /// most recent tokens in `tokenCounts` (oldest first) intact.
  ///
  /// Walks from the end backward, accumulating each message's token
  /// count, stopping once the accumulated total reaches `retainedTokens`
  /// — so the tail is never emptied by a single oversized recent message,
  /// but the accumulated total can run slightly over `retainedTokens`.
  ///
  /// - Complexity: O(*n*) in `tokenCounts.count`.
  public static func cutPoint(
    tokenCounts: [Int],
    retainedTokens: Int = defaultRetainedTokens
  ) -> CutPoint {
    var accumulated = 0
    var index = tokenCounts.count
    while index > 0 && accumulated < retainedTokens {
      index -= 1
      accumulated += tokenCounts[index]
    }
    return CutPoint(index: index, retainedTokens: accumulated)
  }

  /// The ids of the tool calls `message` requests, in order.
  private static func toolCallIDs(of message: SessionMessage) -> [String] {
    let content: [ContentBlock]
    switch message {
    case .user(let message): content = message.content
    case .assistant(let message): content = message.content
    case .toolResult(let message): content = message.content
    }
    return content.compactMap { block in
      if case .toolCall(let id, _, _) = block { return id }
      return nil
    }
  }

  /// The id of the first tool result in `messages` whose originating
  /// `ContentBlock.toolCall` is not itself in `messages`, if any.
  private static func orphanedToolCallID(in messages: ArraySlice<SessionMessage>) -> String? {
    var requested: Set<String> = []
    for message in messages {
      if case .toolResult(let result) = message, !requested.contains(result.toolCallID) {
        return result.toolCallID
      }
      requested.formUnion(Self.toolCallIDs(of: message))
    }
    return nil
  }

  /// Moves a cut point earlier until `messages[index...]` is
  /// self-contained, i.e. holds the originating `ContentBlock.toolCall`
  /// of every tool result it retains.
  ///
  /// Token arithmetic alone can cut between an assistant message that
  /// requested a tool call and the result answering it, which would
  /// summarize the call away and leave the tail opening on an orphaned
  /// tool result — a shape providers reject. `R6`/`§3.5` require a
  /// self-contained `retainedTail`, so the boundary is pulled back to the
  /// message that made the call (retaining slightly more than
  /// `retainedTokens`, as an over-budget cut point already may). A result
  /// whose call is nowhere in `messages` cannot be repaired by retaining
  /// more, so it stops the walk instead of emptying the tail.
  ///
  /// - Complexity: O(*n*²) in `messages.count` in the worst case, O(*n*)
  ///   when tool results follow the message that requested them.
  private static func selfContainedIndex(from index: Int, in messages: [SessionMessage]) -> Int {
    var index = index
    while index > 0,
      let orphan = Self.orphanedToolCallID(in: messages[index...]),
      let callIndex = messages[..<index].lastIndex(where: {
        Self.toolCallIDs(of: $0).contains(orphan)
      })
    {
      index = callIndex
    }
    return index
  }

  /// Compacts `messages` (oldest first) into a `.compaction` entry kind,
  /// summarizing everything before the cut point and retaining everything
  /// from the cut point onward verbatim.
  ///
  /// The cut point comes from ``cutPoint(tokenCounts:retainedTokens:)``
  /// and is then moved earlier if that boundary would strand a tool
  /// result whose originating `ContentBlock.toolCall` is about to be
  /// summarized away, so `retainedTail` is always self-contained (`R6`,
  /// `§3.5`) and can retain slightly more than `retainedTokens`.
  ///
  /// Ported from pi's iterative summarization (`§3.5`): `summarize` is
  /// invoked with the messages selected for replacement, and re-invoked
  /// — up to `maxAttempts` times total — whenever the returned
  /// ``CompactionSummary/tokenCount`` still exceeds `summaryTokenBudget`,
  /// so a summary that itself overflows never reaches the session tree.
  ///
  /// - Throws: ``CompactionError`` with code `tokenCountMismatch` if
  ///   `tokenCounts.count != messages.count`, or code
  ///   `summarizerExceededAttemptLimit` if `summarize` never produced a
  ///   summary within `summaryTokenBudget` inside `maxAttempts` attempts.
  ///   Rethrows whatever `summarize` throws.
  /// - Complexity: O(*n*) in `messages.count` plus whatever `summarize`
  ///   costs, called at most `maxAttempts` times.
  @concurrent
  public static func compact(
    messages: [SessionMessage],
    tokenCounts: [Int],
    replacedThrough: EntryID,
    retainedTokens: Int = defaultRetainedTokens,
    summaryTokenBudget: Int,
    maxAttempts: Int = defaultMaxAttempts,
    summarize: CompactionSummarizer
  ) async throws -> SessionEntryKind {
    guard tokenCounts.count == messages.count else {
      throw CompactionError(
        code: .tokenCountMismatch,
        message:
          "tokenCounts has \(tokenCounts.count) entries but messages has \(messages.count)"
      )
    }

    let cut = Self.cutPoint(tokenCounts: tokenCounts, retainedTokens: retainedTokens)
    let start = Self.selfContainedIndex(from: cut.index, in: messages)
    let toSummarize = Array(messages[..<start])
    let retainedTail = Array(messages[start...])

    var attempt = 0
    var lastTokenCount = -1
    while attempt < max(maxAttempts, 1) {
      attempt += 1
      let summary = try await summarize(toSummarize)
      if summary.tokenCount <= summaryTokenBudget {
        return .compaction(
          summary: summary.text,
          retainedTail: retainedTail,
          replacedThrough: replacedThrough
        )
      }
      lastTokenCount = summary.tokenCount
    }
    throw CompactionError(
      code: .summarizerExceededAttemptLimit,
      message:
        "summarizer produced a \(lastTokenCount)-token summary after \(attempt) attempts, "
        + "exceeding the \(summaryTokenBudget)-token budget"
    )
  }
}
