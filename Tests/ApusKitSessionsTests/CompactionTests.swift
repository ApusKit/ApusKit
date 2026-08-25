// CompactionTests
//
// Coverage for R6/§3.5 compaction: the trigger condition, the cut-point
// that retains ~20 000 recent tokens, and end-to-end assembly of a
// `.compaction` entry via an injected summarizer — including the
// iterative retry when a summary itself overflows its budget.

import ApusKitCore
import ApusKitSessions
import Testing

/// A deterministic `RandomNumberGenerator` so `EntryID.random(using:)`
/// calls in these tests do not depend on the system's entropy source.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

/// A scripted summarizer that replays one `CompactionSummary` per call,
/// recording how many times it was invoked.
///
/// An actor rather than a lock-protected counter, per `CC-4`.
private actor ScriptedSummarizer {
  private var remainingResults: [CompactionSummary]
  private(set) var callCount = 0

  init(_ results: [CompactionSummary]) {
    self.remainingResults = results
  }

  func next(_ messages: [SessionMessage]) throws -> CompactionSummary {
    callCount += 1
    guard !remainingResults.isEmpty else {
      throw ScriptedSummarizerError()
    }
    return remainingResults.removeFirst()
  }
}

private struct ScriptedSummarizerError: Error, Sendable, Equatable {}

/// A scripted summarizer that records the messages it was called with and
/// always returns a fixed, within-budget summary.
///
/// An actor rather than a lock-protected var, per `CC-4`.
private actor CapturingSummarizer {
  private(set) var seen: [SessionMessage] = []

  func record(_ messages: [SessionMessage]) -> CompactionSummary {
    seen = messages
    return CompactionSummary(text: "ok", tokenCount: 10)
  }
}

private func message(_ text: String) -> SessionMessage {
  .user(UserMessage(content: [.text(text)]))
}

/// An assistant message requesting one tool call.
private func toolCall(_ id: String) -> SessionMessage {
  .assistant(
    AssistantMessage(
      content: [.toolCall(id: id, name: "read_file", argumentsJSON: "{}")],
      stopReason: .toolUse,
      usage: Usage(inputTokens: 0, outputTokens: 0)
    )
  )
}

/// The tool result answering the call with the given id.
private func toolResult(_ id: String) -> SessionMessage {
  .toolResult(ToolResultMessage(toolCallID: id, content: [.text("result of \(id)")]))
}

/// The R6/§3.5 compaction suites, nested under one `CompactionTests`
/// symbol so `swift test --filter 'CompactionTests'` selects them by a
/// declared type name rather than by the source file path.
@Suite("Compaction")
struct CompactionTests {
  @Suite("Compaction.shouldCompact")
  struct ShouldCompactTests {
    @Test("tokens at or below the budget do not trigger compaction")
    func withinBudgetDoesNotTrigger() {
      // window 200_000, reserve 16_384 -> budget 183_616.
      #expect(!Compaction.shouldCompact(contextTokens: 183_616, contextWindow: 200_000))
    }

    @Test("tokens over the budget trigger compaction")
    func overBudgetTriggers() {
      #expect(Compaction.shouldCompact(contextTokens: 183_617, contextWindow: 200_000))
    }

    @Test("a custom reserve is honored instead of the pi-normative default")
    func customReserveIsHonored() {
      #expect(Compaction.shouldCompact(contextTokens: 91, contextWindow: 100, reserve: 10))
      #expect(!Compaction.shouldCompact(contextTokens: 90, contextWindow: 100, reserve: 10))
    }

    @Test("the default reserve is pi's normative 16 384")
    func defaultReserveIsNormative() {
      #expect(Compaction.defaultReserve == 16_384)
    }
  }

  @Suite("Compaction.cutPoint")
  struct CutPointTests {
    @Test("the default retained-tokens budget is pi's normative 20 000")
    func defaultRetainedTokensIsNormative() {
      #expect(Compaction.defaultRetainedTokens == 20_000)
    }

    @Test("an empty context cuts at index zero, retaining nothing")
    func emptyContextCutsAtZero() {
      let cut = Compaction.cutPoint(tokenCounts: [])
      #expect(cut.index == 0)
      #expect(cut.retainedTokens == 0)
    }

    @Test("walking from the tail stops once the retained budget is reached")
    func stopsOnceBudgetReached() {
      // Oldest first: 10 messages of 3_000 tokens each = 30_000 total.
      // Retaining ~20_000 from the tail needs the last 7 (21_000).
      let tokenCounts = Array(repeating: 3_000, count: 10)
      let cut = Compaction.cutPoint(tokenCounts: tokenCounts, retainedTokens: 20_000)
      #expect(cut.index == 3)
      #expect(cut.retainedTokens == 21_000)
    }

    @Test("a single oversized recent message is still retained whole")
    func singleOversizedRecentMessageIsRetainedWhole() {
      let tokenCounts = [5_000, 1_000, 40_000]
      let cut = Compaction.cutPoint(tokenCounts: tokenCounts, retainedTokens: 20_000)
      #expect(cut.index == 2)
      #expect(cut.retainedTokens == 40_000)
    }

    @Test("everything fits when the total is under the retained budget")
    func everythingFitsUnderBudget() {
      let tokenCounts = [100, 200, 300]
      let cut = Compaction.cutPoint(tokenCounts: tokenCounts, retainedTokens: 20_000)
      #expect(cut.index == 0)
      #expect(cut.retainedTokens == 600)
    }
  }

  @Suite("Compaction.compact")
  struct CompactTests {
    private static func replacedThroughID() -> EntryID {
      var generator = SeededGenerator(state: 99)
      return EntryID.random(using: &generator)
    }

    @Test("a summary within budget on the first attempt is used as-is")
    func fittingSummaryIsUsedOnFirstAttempt() async throws {
      let toSummarize = [message("old-1"), message("old-2")]
      let retained = [message("recent-1")]
      let summarizer = ScriptedSummarizer([
        CompactionSummary(text: "summary of the old turns", tokenCount: 50)
      ])
      let replacedThrough = Self.replacedThroughID()

      let kind = try await Compaction.compact(
        messages: toSummarize + retained,
        tokenCounts: [1_000, 1_000, 100],
        replacedThrough: replacedThrough,
        retainedTokens: 100,
        summaryTokenBudget: 200,
        summarize: { try await summarizer.next($0) }
      )

      guard case .compaction(let summary, let retainedTail, let through) = kind else {
        Issue.record("expected a .compaction entry kind, got \(kind)")
        return
      }
      #expect(summary == "summary of the old turns")
      #expect(retainedTail == retained)
      #expect(through == replacedThrough)
      let calls = await summarizer.callCount
      #expect(calls == 1)
    }

    @Test("a summarizer that overflows on its first pass is re-invoked until it fits")
    func overflowingSummaryIsRetriedUntilItFits() async throws {
      let toSummarize = [message("old-1"), message("old-2"), message("old-3")]
      let retained = [message("recent-1")]
      let summarizer = ScriptedSummarizer([
        CompactionSummary(text: "a summary that is still much too long", tokenCount: 500),
        CompactionSummary(text: "a tighter summary", tokenCount: 80),
      ])
      let replacedThrough = Self.replacedThroughID()

      let kind = try await Compaction.compact(
        messages: toSummarize + retained,
        tokenCounts: [1_000, 1_000, 1_000, 100],
        replacedThrough: replacedThrough,
        retainedTokens: 100,
        summaryTokenBudget: 200,
        maxAttempts: 3,
        summarize: { try await summarizer.next($0) }
      )

      guard case .compaction(let summary, let retainedTail, let through) = kind else {
        Issue.record("expected a .compaction entry kind, got \(kind)")
        return
      }
      #expect(summary == "a tighter summary")
      #expect(retainedTail == retained)
      #expect(through == replacedThrough)
      let calls = await summarizer.callCount
      #expect(calls == 2)
    }

    @Test("a summarizer that never fits the budget throws after maxAttempts")
    func neverFittingSummaryThrowsAfterMaxAttempts() async throws {
      let toSummarize = [message("old-1")]
      let summarizer = ScriptedSummarizer([
        CompactionSummary(text: "too long", tokenCount: 500),
        CompactionSummary(text: "still too long", tokenCount: 400),
        CompactionSummary(text: "still too long again", tokenCount: 300),
      ])
      let replacedThrough = Self.replacedThroughID()

      await #expect(throws: CompactionError.self) {
        try await Compaction.compact(
          messages: toSummarize,
          tokenCounts: [1_000],
          replacedThrough: replacedThrough,
          retainedTokens: 0,
          summaryTokenBudget: 200,
          maxAttempts: 3,
          summarize: { try await summarizer.next($0) }
        )
      }
      let calls = await summarizer.callCount
      #expect(calls == 3)
    }

    @Test("the thrown error reports summarizerExceededAttemptLimit")
    func thrownErrorReportsCorrectCode() async throws {
      let summarizer = ScriptedSummarizer([
        CompactionSummary(text: "too long", tokenCount: 500)
      ])
      let replacedThrough = Self.replacedThroughID()

      do {
        _ = try await Compaction.compact(
          messages: [message("old-1")],
          tokenCounts: [1_000],
          replacedThrough: replacedThrough,
          retainedTokens: 0,
          summaryTokenBudget: 200,
          maxAttempts: 1,
          summarize: { try await summarizer.next($0) }
        )
        Issue.record("expected compact to throw")
      } catch let error as CompactionError {
        #expect(error.code == .summarizerExceededAttemptLimit)
      } catch {
        Issue.record("expected a CompactionError, got \(error)")
      }
    }

    @Test("mismatched token counts throw tokenCountMismatch before invoking the summarizer")
    func mismatchedTokenCountsThrow() async throws {
      let summarizer = ScriptedSummarizer([])
      let replacedThrough = Self.replacedThroughID()

      do {
        _ = try await Compaction.compact(
          messages: [message("old-1"), message("old-2")],
          tokenCounts: [1_000],
          replacedThrough: replacedThrough,
          summaryTokenBudget: 200,
          summarize: { try await summarizer.next($0) }
        )
        Issue.record("expected compact to throw")
      } catch let error as CompactionError {
        #expect(error.code == .tokenCountMismatch)
      } catch {
        Issue.record("expected a CompactionError, got \(error)")
      }
      let calls = await summarizer.callCount
      #expect(calls == 0)
    }

    @Test("only the messages selected for replacement are handed to the summarizer")
    func onlyReplacedMessagesReachTheSummarizer() async throws {
      let old1 = message("old-1")
      let old2 = message("old-2")
      let recent = message("recent-1")
      let replacedThrough = Self.replacedThroughID()

      let recorder = CapturingSummarizer()
      let kind = try await Compaction.compact(
        messages: [old1, old2, recent],
        tokenCounts: [1_000, 1_000, 100],
        replacedThrough: replacedThrough,
        retainedTokens: 100,
        summaryTokenBudget: 200,
        summarize: { await recorder.record($0) }
      )

      let seen = await recorder.seen
      #expect(seen == [old1, old2])
      guard case .compaction(_, let retainedTail, _) = kind else {
        Issue.record("expected a .compaction entry kind, got \(kind)")
        return
      }
      #expect(retainedTail == [recent])
    }

    @Test("a tail that would open on a tool result retains its originating tool call")
    func retainedTailKeepsTheCallItsToolResultAnswers() async throws {
      let old = message("old-1")
      let call = toolCall("call-1")
      let result = toolResult("call-1")
      let replacedThrough = Self.replacedThroughID()

      // Token arithmetic alone cuts at the tool result (100 tokens is
      // already the whole budget); the boundary must move back to the
      // assistant message that requested the call (`R6`, `§3.5`).
      let recorder = CapturingSummarizer()
      let kind = try await Compaction.compact(
        messages: [old, call, result],
        tokenCounts: [1_000, 1_000, 100],
        replacedThrough: replacedThrough,
        retainedTokens: 100,
        summaryTokenBudget: 200,
        summarize: { await recorder.record($0) }
      )

      let seen = await recorder.seen
      #expect(seen == [old])
      guard case .compaction(_, let retainedTail, _) = kind else {
        Issue.record("expected a .compaction entry kind, got \(kind)")
        return
      }
      #expect(retainedTail == [call, result])
    }

    @Test("a tool result stranded deeper in the tail also pulls the boundary back")
    func retainedTailKeepsCallsForResultsBeyondItsHead() async throws {
      let old = message("old-1")
      let callA = toolCall("call-a")
      let callB = toolCall("call-b")
      let resultB = toolResult("call-b")
      let resultA = toolResult("call-a")
      let replacedThrough = Self.replacedThroughID()

      // Arithmetic cuts at `resultB`; repairing that strands `resultA`,
      // so the boundary walks back again, to `callA`.
      let recorder = CapturingSummarizer()
      let kind = try await Compaction.compact(
        messages: [old, callA, callB, resultB, resultA],
        tokenCounts: [1_000, 1_000, 1_000, 100, 100],
        replacedThrough: replacedThrough,
        retainedTokens: 150,
        summaryTokenBudget: 200,
        summarize: { await recorder.record($0) }
      )

      let seen = await recorder.seen
      #expect(seen == [old])
      guard case .compaction(_, let retainedTail, _) = kind else {
        Issue.record("expected a .compaction entry kind, got \(kind)")
        return
      }
      #expect(retainedTail == [callA, callB, resultB, resultA])
    }

    @Test("a tool result whose call is nowhere in the context does not empty the tail")
    func anUnanswerableToolResultLeavesTheBoundaryAlone() async throws {
      let old = message("old-1")
      let orphan = toolResult("call-never-made")
      let replacedThrough = Self.replacedThroughID()

      let recorder = CapturingSummarizer()
      let kind = try await Compaction.compact(
        messages: [old, orphan],
        tokenCounts: [1_000, 100],
        replacedThrough: replacedThrough,
        retainedTokens: 100,
        summaryTokenBudget: 200,
        summarize: { await recorder.record($0) }
      )

      let seen = await recorder.seen
      #expect(seen == [old])
      guard case .compaction(_, let retainedTail, _) = kind else {
        Issue.record("expected a .compaction entry kind, got \(kind)")
        return
      }
      #expect(retainedTail == [orphan])
    }
  }
}
