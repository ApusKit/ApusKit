# 0005 — Hook bus and `AgentExtension` packaging

Status: draft (M3 Public 0.1.0, `F5.1`/`F5.2`). **Blocked.** It cannot
land until the maintainer has answered the open questions marked
*blocking* at the end and the TRD amendments they imply have been made.
Questions 1, 2, 3 and 6 each touch TRD text (`ACC-2`/`ACC-3`, `PKG-6`,
`§3.5`, `§3.6`). The other questions can be answered during review.

## Motivation

M3 lists "Hook bus + `AgentExtension` (F5.1, F5.2)" as a deliverable
(`PRD.md` §5), and `§3.6` names the bus's eleven registration points,
from `toolCall` to `shouldStopAfterTurn`. None of them exists yet. The
loop in `Sources/ApusKitAgent/RunLoop.swift` has three internal
placeholders for the `LOOP-2` steps. `transformContext(_:)` is the
identity, `prepareNextTurn()` does nothing and `shouldStopAfterTurn(_:)`
always returns `false`. Nothing else in the loop can be intercepted. So a
consumer cannot build a permission gate, a budget, a quota or telemetry,
although `F5.1` says they must be able to. Three later deliverables also
have nowhere to attach:

- **`WF-2` token budgets** (M5). These are "counted from `Usage` and
  enforced between turns through the hook bus", so they need a bus.
- **Compaction wiring** (`§3.5`). `ApusKitSessions` owns the whole
  policy behind two seams, `CompactionSummarizer` and
  `CompactionTokenCounter` (0004 and its 2026-10-08 amendment). "`ApusKitAgent`
  wires them up", and `sessionBeforeCompact` is the hook that lets an
  extension veto a compaction or supply the summary. Today
  `ApusKitAgent` does not depend on `ApusKitSessions` at all
  (`Package.swift`), although `PKG-6` allows that edge.
- **`MCPToolSource: AgentExtension`** (`§3.7`, M4). It needs an install
  seam that can add, and later refresh, tools.

The hooks and the extension packaging are one family. `AgentExtension`
is the only way to reach the bus, and the bus is most of what an
extension installs (`§3.6`, "a single conformance installs tools +
hooks"). Like 0003 and 0004, this is one proposal for the whole family.

## Proposed API

All new types live in `ApusKitAgent`. Every value type is sealed
(`ACC-2`). The conformable surface is `AgentExtension` plus the hook
handler types (see open question 1). Every new public enum is
`@nonexhaustive(warn)` (`ENUM-1`). All of them go into
`docs/sendable-audit.md` (`CC-3`).

### `AgentExtension` and installation

```swift
/// A packaged unit of tools and hooks that installs into an `Agent`
/// through public API only (`EXT-1`).
///
/// Conform freely (`ACC-2`). Extensions are compile-time Swift values;
/// there is no dynamic loading (`EXT-2`).
///
/// Contract (`ACC-3`):
/// - Preconditions: `install(into:)` is called exactly once per
///   `Agent.install(_:)`, and only when the agent was idle at the call.
///   The agent never calls it concurrently with itself for the same
///   `Agent.install(_:)`.
/// - Isolation: it runs off the agent's actor (`@concurrent`) and may
///   suspend.
/// - Errors: a thrown error aborts the install. Nothing the extension
///   registered before throwing stays registered.
/// - Cancellation: it runs in the task that called `Agent.install(_:)`,
///   so cancelling that task cancels it. The extension should return or
///   throw promptly when cancelled. If the calling task is cancelled by
///   the time `install(into:)` returns, the agent discards the batch and
///   `Agent.install(_:)` throws `CancellationError`, even if the
///   extension itself returned normally.
/// - Retry: the agent never retries. Because a failed install leaves the
///   agent unchanged, the caller may install the same extension value
///   again. An extension whose `install(into:)` has side effects outside
///   the context, such as opening a connection, must tolerate being
///   called again after a failed attempt.
public protocol AgentExtension: Sendable {
  /// Registers this extension's tools and hooks on `context`.
  @concurrent
  func install(into context: ExtensionContext) async throws
}

extension Agent {
  /// Installs `extension`, making its tools and hooks live from the
  /// next run.
  ///
  /// Hooks fire in commit order (the order in which `install(_:)` calls
  /// succeed), and within one extension in registration order
  /// (`API-4`). Installs awaited one after another therefore fire in
  /// call order. Installs started concurrently from separate tasks fire
  /// in the order they finish, which is the caller's to control.
  ///
  /// - Throws: `AgentError` with code `.installWhileRunning` if a run is
  ///   in flight when the install starts or when it commits,
  ///   `.duplicateToolName` if a registered tool's name is taken at
  ///   commit, `CancellationError` if the calling task was cancelled, or
  ///   whatever `install(into:)` throws. On any throw the agent is left
  ///   exactly as it was.
  public func install(_ extension: some AgentExtension) async throws
}
```

`Agent.install(_:)` is actor-isolated, so its isolation is the actor's
and `CC-2` needs no extra annotation, just as for `run(_:)`.
`ExtensionContext` collects what the extension registers. The agent
commits the batch when `install(into:)` returns. That is what makes a
throw leave nothing behind.

**Re-entrancy.** `install(_:)` suspends while it awaits
`install(into:)`, and actor re-entrancy means a `run(_:)` or a second
`install(_:)` can start during that suspension. The install is
therefore checked twice:

1. **On entry**, synchronously on the actor: if a run is in flight,
   throw `.installWhileRunning` before calling the extension.
2. **At commit**, after `install(into:)` returns and with no suspension
   point between the checks and the mutation: check cancellation, then
   check again that no run is in flight, then check every collected tool
   name against the registry *as it is at commit*. That registry includes
   tools committed meanwhile by an interleaved install. Only when all of
   these pass are the tools and hooks appended, in one synchronous
   step.

A run that starts during the suspension proceeds without the pending
extension, and the install then fails with `.installWhileRunning`. Two
concurrent installs are both allowed. Each one commits or fails on its
own, and the first to commit takes a contested tool name. "Live from
the next run" means the next `run(_:)` that starts after the commit.
That is the exact sense of "installs only while idle".

### `ExtensionContext`

The context is an `actor`, not a struct. A `Sendable` struct cannot
record registrations from non-mutating synchronous methods without a
shared mutable box. That box would need a lock (forbidden by `CC-4`) or
`@unchecked Sendable` (see "Alternatives considered"). An actor is
`Sendable`, sealed by construction (`ACC-2`) and `CC-4`-compliant. It
also keeps `§3.6`'s exact `install(into context: ExtensionContext)`
signature. The cost is that each registration is an `await`.

```swift
/// The registration surface an `AgentExtension` sees during
/// `install(into:)`: the agent handle, tool registration, the provider
/// registry, the session store, and hook registration (`§3.6`).
///
/// Sealed (`ACC-2`). A context is valid only for the duration of the
/// `install(into:)` call it was passed to. Once that call returns, the
/// agent seals the context, and every later registration on it is
/// ignored. Registration order is the order in which the context
/// receives the calls. Register sequentially (one `await` after another)
/// for a deterministic order (`API-4`).
///
/// Capture rule: the agent keeps every registered hook for its
/// lifetime. A hook that strongly captures the agent (or a value that
/// holds it) creates a retain cycle, which keeps the agent and all its
/// event streams alive forever (`EVENT-3`). See ``agent``.
public actor ExtensionContext {
  /// The agent being extended, held weakly.
  ///
  /// Use it at install time, or capture `context` (not the agent) in a
  /// hook and read this property when the hook runs. It is `nil` once
  /// the agent has been deinitialized. A hook must not call
  /// `Agent.run(_:)` on the agent whose run invoked it (see "Re-entrant
  /// calls from hooks").
  public weak let agent: Agent?

  /// The providers the agent was configured with, if any. This is a
  /// read-only snapshot (see open question 6).
  public let providers: ProviderRegistry?

  /// The store the agent journals into, if it has one.
  public let sessionStore: (any SessionStore)?

  /// Adds `tool` to the agent's registry when the install commits.
  public func register(tool: some Tool)

  /// Adds an already type-erased tool to the agent's registry when the
  /// install commits.
  public func register(tool: AnyAgentTool)

  /// Registers `handler` for the `toolCall` hook. It can block a call.
  public func onToolCall(_ handler: @escaping ToolCallHook)

  // … one `on…` method per hook, as below, each actor-isolated and
  // non-throwing:
  // onToolResult, onBeforeProviderRequest, onAfterProviderResponse,
  // onTransformContext, onPrepareNextTurn, onShouldStopAfterTurn,
  // onSessionBeforeCompact, onSessionStart, onSessionShutdown,
  // onModelSelect.
}
```

`weak let` is SE-0481, available from Swift 6.2. `swiftc -swift-version
6 -typecheck` accepts a `public weak let` on an actor. The registration
methods are actor-isolated, so `CC-2` needs no annotation, as for
`Agent.install(_:)`. Callers write `await context.onToolCall { … }`. The
methods do not throw. `register(tool:)` reports a name clash when
`install(_:)` commits the batch, not at the call, because only the
commit-time check is race-free (see "Re-entrancy"). `register(tool:)`
uses a role label (`API-2`). It deliberately differs from
`ToolRegistry.register(_:)`, whose silent overwrite would let one
extension shadow another's tool unseen.

The context has no public initializer. Testing a third-party extension
without a full `Agent` depends on open question 2.

### Re-entrant calls from hooks

Hooks run inside the run's task tree, so a hook that calls back into the
same agent needs a defined outcome:

- **`run(_:)` from a hook of that agent's own run would deadlock.** The
  call appends to the queue and then awaits `runningTask.value`, but
  that task is itself suspended awaiting the hook (`Agent.swift`,
  `run(_:)`). This would silently break `LOOP-3`/`LOOP-6`. This draft
  proposes that the agent detect it and fail fast. The run loop binds a
  `@TaskLocal` marker carrying the agent's identity. `run(_:)` checks
  it first, and if the call comes from inside that agent's own run, it
  returns immediately with a final `.error` message carrying
  `AgentError` code `.reentrantRun`, which it also emits. It never
  throws (`LOOP-3`) and never enqueues. Whether a `@TaskLocal` is
  acceptable under `DI-1`'s "zero global mutable state" is open
  question 9.
- **`install(_:)` from a hook** throws `.installWhileRunning`. That is
  already the defined outcome.
- **`abort()` and `makeEventStream(bufferingPolicy:)` from a hook** are
  safe. `abort()` cancels the run, and the loop ends `.aborted` at the
  next cancellation check.

The retain-cycle hazard is handled by the weak `agent` property and the
capture rule above. If `Agent.shutdown()` is added (open question 5), it
also drops every registered hook and extension tool, which breaks any
cycle a consumer created anyway. A regression test installs an
extension whose hooks capture `context` and asserts that the agent
deinitializes and its event streams finish (`EVENT-3`).

### Hook handler types and payloads

```swift
/// One tool call as the hook bus presents it.
public struct HookToolCall: Sendable, Equatable {
  /// The id of the `ContentBlock.toolCall` being executed.
  public let toolCallID: String
  /// The tool's registered name.
  public let name: String
  /// The raw arguments JSON, before schema validation (`TOOL-1`).
  public let argumentsJSON: String
  /// Creates a tool call payload, for example to unit-test a handler.
  public init(toolCallID: String, name: String, argumentsJSON: String)
}

/// A `toolCall` handler's verdict.
@nonexhaustive(warn)
public enum ToolCallDecision: Sendable, Equatable {
  /// Lets the call proceed to the next handler and then to execution.
  case allow
  /// Refuses the call. The model receives an error `ToolResult` that
  /// carries `reason`.
  case block(reason: String)
}

/// What one turn produced, as seen by the `prepareNextTurn` and
/// `shouldStopAfterTurn` hooks.
public struct TurnOutcome: Sendable, Equatable {
  /// The turn's final assistant message, including its `Usage`.
  public let message: AssistantMessage
  /// The results appended for this turn's tool calls, in the order their
  /// calls appear in `message.content` (`API-4`). A call that never
  /// produced a result, because a `terminate: true` result ended the
  /// batch first (`LOOP-7`), has no entry.
  public let toolResults: [ToolResultMessage]
  /// Creates a turn outcome, for example to unit-test a handler.
  public init(message: AssistantMessage, toolResults: [ToolResultMessage])
}

/// A proposed compaction, as the `sessionBeforeCompact` hook sees it.
public struct CompactionProposal: Sendable, Equatable {
  /// The context about to be compacted, oldest first.
  public let messages: [SessionMessage]
  /// The model's context window that triggered the compaction.
  public let contextWindow: Int
  /// Creates a compaction proposal, for example to unit-test a handler.
  public init(messages: [SessionMessage], contextWindow: Int)
}

/// A `sessionBeforeCompact` handler's verdict.
@nonexhaustive(warn)
public enum CompactionDecision: Sendable {
  /// Lets the compaction proceed to the next handler.
  case proceed
  /// Skips this compaction. The run continues uncompacted.
  case cancel
  /// Proceeds, but summarizes with `summarizer` instead of the agent's
  /// own. The cut point and retained tail stay `Compaction`'s (`§3.5`).
  case summarize(with: CompactionSummarizer)
}

/// The session lifecycle as the `sessionStart`/`sessionShutdown` hooks
/// see it.
public struct SessionLifecycleInfo: Sendable, Equatable {
  /// The bound session's header, or `nil` for an agent with no store.
  public let header: SessionHeader?
  /// Creates a lifecycle payload, for example to unit-test a handler.
  public init(header: SessionHeader?)
}

/// A model change, as the `modelSelect` hook sees it.
public struct ModelSelection: Sendable, Equatable {
  /// The model in use before, or `nil` on the agent's first selection.
  public let previous: String?
  /// The model now in use.
  public let model: String
  /// Creates a model-selection payload, for example to unit-test a handler.
  public init(previous: String?, model: String)
}

/// Decides whether a tool call may run. Handlers run in order, and the
/// first `.block` wins and short-circuits the rest.
public typealias ToolCallHook = @concurrent @Sendable (HookToolCall) async -> ToolCallDecision

/// Rewrites a tool result. Handlers chain in order, and each receives
/// the previous one's output.
public typealias ToolResultHook =
  @concurrent @Sendable (HookToolCall, ToolResult) async -> ToolResult

/// Observes the exact request about to be streamed.
public typealias BeforeProviderRequestHook = @concurrent @Sendable (LLMRequest) async -> Void

/// Observes the outcome of one provider exchange together with the
/// request that produced it.
public typealias AfterProviderResponseHook =
  @concurrent @Sendable (LLMRequest, AssistantMessage) async -> Void

/// Rewrites the context sent for one turn. Handlers chain in order.
/// Stored history is not changed.
public typealias TransformContextHook =
  @concurrent @Sendable ([LLMRequestMessage]) async -> [LLMRequestMessage]

/// Runs after a turn's tools have executed and before the next turn starts.
public typealias PrepareNextTurnHook = @concurrent @Sendable (TurnOutcome) async -> Void

/// Returns `true` to end the run after this turn. Any `true` wins.
public typealias ShouldStopAfterTurnHook = @concurrent @Sendable (TurnOutcome) async -> Bool

/// Vetoes or re-sources a compaction. The first non-`.proceed` verdict wins.
public typealias SessionBeforeCompactHook =
  @concurrent @Sendable (CompactionProposal) async -> CompactionDecision

/// Observes the agent binding to a session, once, before its first `.agentStart`.
public typealias SessionStartHook = @concurrent @Sendable (SessionLifecycleInfo) async -> Void

/// Observes `Agent.shutdown()`.
public typealias SessionShutdownHook = @concurrent @Sendable (SessionLifecycleInfo) async -> Void

/// Observes the agent's model being selected or changed.
public typealias ModelSelectHook = @concurrent @Sendable (ModelSelection) async -> Void
```

**Payload initializers.** The payload structs get public memberwise
initializers so that a third party can unit-test a handler by calling
it directly, without an `Agent`. They are structs, so the initializers
do not weaken `ACC-2` sealing. The `EVO-1` cost is that adding a stored
property later means adding an initializer overload. Testing a whole
extension (what it registers, in what order) needs a way to build an
`ExtensionContext` without an `Agent`. That belongs to the Conformance
Kit (open question 2).

**`TurnOutcome.toolResults` order.** Today `executeToolCalls(in:)`
appends to `history` in completion order (`for await … in group`),
which varies from run to run for parallel tools (`LOOP-7`). The outcome
the hooks see is built in content-block order instead, to satisfy
`API-4`. This proposal does not change the order of `history` itself.

**Isolation (`CC-2`).** Every handler type is `@concurrent`. A handler
runs off the agent's actor, as `Tool.execute` already does, so a slow
handler never holds the actor. A `MainActor`-default consumer
(`mainactor-consumer`) hops explicitly when it needs the UI.

**Errors and cancellation (`LOOP-3`, `LOOP-6`).** Handlers are
non-throwing. A handler that can fail decides its own fallback, so the
bus never has to invent a policy for a thrown error, and nothing can
throw out of the loop. Handlers run inside the run's task tree, so
`abort()` cancels them. The loop checks cancellation after each hook
point and ends `.aborted`. No hook spawns an unstructured task.

### Where each hook fires (the `ACC-3` contracts)

The positions below are the current `runTurns()`/`executeToolCalls(in:)`
sequence. Each row becomes one documented contract and one executable
contract test (see open question 2 for where those tests live).

| Hook | Fires | Combines | Notes |
|---|---|---|---|
| `transformContext` | Per turn, after steering injection and before the `LLMRequest` is built (`LOOP-2`) | Chain | Replaces the internal identity function. The rewrite applies to the request only, so `history` keeps what really happened, as in pi's `transformContext` |
| `beforeProviderRequest` | After the request is built, before `apiImplementation.stream` | Awaited in order | Observe-only. The TRD marks no "can" capability for it |
| `afterProviderResponse` | When `streamTurn` returns a message, before `history.append`. Also on the thrown-error path, with the `.error` message that `.turnEnd` carries. Not fired on the `.aborted` path | Awaited in order | Observe-only. This is the budget counter's input, with a known gap: see "How `WF-2` budgets ride on the bus" |
| `toolCall` | In each call's child task, after `.toolExecutionStart` and before `execute` | First `.block` wins | Fires only for registered tools. Calls failed by `LOOP-4` never reach it. A blocked call emits `.toolExecutionEnd` with the block result. Handlers can run concurrently for sibling calls (`LOOP-7`) |
| `toolResult` | After `execute` and before `.toolExecutionEnd` | Chain | Applies to block results too. `TRUNC-1` is re-applied after the chain, which needs `AnyAgentTool.truncatingOutput` widened from `private` to `package` (`ACC-1`). A modified `terminate: true` still ends the batch (`LOOP-7`) |
| `prepareNextTurn` | After tool execution (`LOOP-2`) | Awaited in order | Replaces the internal no-op. Compaction is checked here (see below) |
| `shouldStopAfterTurn` | Last in the turn (`LOOP-2`), only while tool calls remain (`LOOP-1`) | Any `true` | Replaces the internal `false`. Ends the run with the turn's message as the final message. See open question 4 for queued follow-ups |
| `sessionBeforeCompact` | After `ApusKitSessions` reports that the context must compact, and before `Compaction.compact` (and so the summarizer) runs | First non-`.proceed` | Depends on open questions 3 and 8. See "Compaction wiring" below |
| `sessionStart` | Once per agent, before the first `.agentStart` | Awaited in order | Payload `header` is `nil` without a store |
| `sessionShutdown` | On a new `Agent.shutdown() async` | Awaited in order | `deinit` cannot await, so the hook needs an explicit call (open question 5) |
| `modelSelect` | With `previous: nil` alongside `sessionStart`, then on each model change | Awaited in order | `Agent.model` is a `let` today. See open question 6 |

pi's extension runner sets the ordering rule: registration order, short
circuit on block, and later handlers see earlier rewrites. Ported per
`§0` principle 1.

### How `WF-2` budgets ride on the bus (M5, not built here)

A budget is an ordinary `AgentExtension` in `ApusKitWorkflows`. It uses
public API only (`EXT-1`) and adds nothing new to the bus:

```swift
struct TokenBudget: AgentExtension {
  let limit: Int
  @concurrent
  func install(into context: ExtensionContext) async throws {
    let spent = UsageTally()  // an actor that sums Usage
    await context.onAfterProviderResponse { _, message in await spent.add(message.usage) }
    await context.onShouldStopAfterTurn { _ in await spent.total >= limit }
  }
}
```

The budget is enforced at turn granularity, which is what `WF-2`'s
"between turns" asks for. A turn already in flight finishes, so the cap
can be overshot by at most one turn. Cost budgets work the same way
through `ProviderRegistry.cost(of:model:)` (`PROV-3`).

**Known gap: errored turns are not counted.** Firing
`afterProviderResponse` on the error path is not enough on its own.
`finalMessage(for:)` builds the `.error` message with zero `Usage`, and
`StreamEvent.error` carries no usage, so whatever a provider billed
before failing never reaches the agent. A budget built this way
therefore undercounts by the tokens of failed (and aborted) turns.
Closing the gap means carrying partial `Usage` on the stream's error
path. That is a wire-format change outside this proposal (open
question 10).

### Compaction wiring (the `§3.5` seams)

**This section lands only if open question 3 is answered "yes, in this
proposal".** Every piece of it presupposes that `Agent` holds a session
tree: `CompactionConfiguration`, the `Agent.init(compaction:)`
parameter, the `ApusKitAgent → ApusKitSessions` edge and the firing of
`sessionBeforeCompact`. If question 3 moves the session tree to a
separate proposal, this whole section moves with it, so that M3 never
ships a public configuration value that does nothing. In that case the
`sessionBeforeCompact` hook type, its payloads and
`ExtensionContext.onSessionBeforeCompact` move too, because a
registration point that can never fire is the same problem. That
proposal would then have to land in M3 as well, since `§3.6` lists the
hook.

**The `ApusKitSessions` API needs a split.**
`Compaction.compactIfNeeded` (`Compaction.swift`) counts, checks the
trigger, cuts and summarizes in one call. It takes the summarizer up
front and never reports the trigger to its caller, so there is no point
between trigger and summarize at which to fire the hook. This draft
proposes a 0004 amendment that splits the decision out, so the trigger
policy stays in `ApusKitSessions` (`PKG-6`):

```swift
extension Compaction {
  /// Measures `messages` once with `countTokens` and returns the
  /// per-message counts if they must compact in a
  /// `contextWindow`-token model, or `nil` if they still fit.
  ///
  /// - Complexity: O(*n*), plus *n* calls to `countTokens`.
  @concurrent
  public static func tokenCountsIfCompactionNeeded(
    messages: [SessionMessage],
    contextWindow: Int,
    reserve: Int = defaultReserve,
    countTokens: CompactionTokenCounter
  ) async throws -> [Int]?
}
```

`compactIfNeeded` is then re-expressed as this function followed by the
existing `compact(messages:tokenCounts:…)`. Its behaviour does not
change. The agent's sequence becomes:

1. Call `tokenCountsIfCompactionNeeded`. On `nil`, stop.
2. Fire `sessionBeforeCompact` with a `CompactionProposal`. On
   `.cancel`, stop.
3. Call `Compaction.compact(messages:tokenCounts:replacedThrough:…)`
   with the counts from step 1 and the winning summarizer (a hook's
   `.summarize(with:)`, otherwise the configured one). The trigger and
   the cut therefore use the same counts, which was the point of the
   0004 amendment.

The alternative, wrapping the summarizer so that the hook fires inside
its first call, needs no Sessions change. But the wrapper is called up
to `maxAttempts` times, so it would have to remember the verdict across
attempts, and `.cancel` could only come out as a thrown sentinel error
that the agent then has to tell apart from a real failure. Open
question 8 asks the maintainer to choose.

```swift
/// How an `Agent` compacts its context, wiring `ApusKitSessions`'
/// summarizer and token-counter seams (`§3.5`).
///
/// The agent never re-implements the policy (`PKG-6`). It asks
/// `Compaction` whether to compact and how, which uses pi's normative
/// 16 384 / 20 000 defaults.
public struct CompactionConfiguration: Sendable {
  /// The model's context window, in tokens.
  public var contextWindow: Int
  /// The most tokens a summary may occupy.
  public var summaryTokenBudget: Int
  /// Measures one message's tokens.
  public var countTokens: CompactionTokenCounter
  /// Summarizes the messages selected for replacement.
  public var summarize: CompactionSummarizer

  /// Creates a compaction configuration.
  public init(
    contextWindow: Int,
    summaryTokenBudget: Int,
    countTokens: @escaping CompactionTokenCounter,
    summarize: @escaping CompactionSummarizer
  )
}
```

The configuration is injected through `Agent.init` (`DI-1`) as
`compaction: CompactionConfiguration? = nil`. The agent checks at the
`prepareNextTurn` boundary and before the first turn of each queued
message, following the three steps above. A compaction failure, either
`CompactionError` or a thrown seam, is reported on the event stream and
the run continues uncompacted. It never ends the run (`LOOP-3`).
`compact` takes `replacedThrough: EntryID`, which is why all of this
presupposes a session tree rather than today's `[LLMRequestMessage]`
(open question 3).

## Alternatives considered

- **`ExtensionContext` as a `Sendable` struct with synchronous
  registration.** This was the first draft. It cannot be implemented:
  `swiftc -swift-version 6 -typecheck` rejects a `Sendable` struct that
  stores a non-`Sendable` box ("stored property 'box' of
  'Sendable'-conforming struct … has non-Sendable type"). Making the box
  `Sendable` needs a lock or `Mutex` (`CC-4`), or `@unchecked Sendable`.
- **`install(into context: inout ExtensionContext)` with `mutating`
  registration.** This keeps the registration calls synchronous with no
  box. Rejected for now because it changes `§3.6`'s normative
  signature, and an `inout` parameter cannot be captured in an escaping
  hook closure, so a hook could not reach `context.agent` later without
  copying it out first. If the `await` on each registration is judged too costly, this
  is the fallback, and it needs a TRD amendment (open question 1).
- **A non-`Sendable` context passed as `sending`.** Rejected. It would
  also change the protocol signature, and the context could not be read
  from a hook later.
- **One handler protocol per hook (`ToolCallHandler`, …) instead of
  closure types.** `ACC-2`'s "hook handler types" reads most literally
  this way. Rejected for now: it adds eleven protocols, each needing a
  Conformance Kit suite (`ACC-3`), for what are one-function contracts.
  0004 already set the precedent of `@Sendable` closures for
  `CompactionSummarizer`/`CompactionTokenCounter`, chosen so as not to
  widen the conformable set. Open question 1.
- **A single `AgentHooks` protocol with eleven defaulted requirements.**
  This is `EVO-1`-friendly. Rejected because a misspelled override
  silently binds to the default no-op, which is exactly the failure a
  permission gate cannot afford.
- **Throwing handlers.** Rejected. Every hook would need a defined
  fallback for a throw (fail open or fail closed?), and `LOOP-3` already
  forbids the error from escaping. The handler is the only party that
  knows the right fallback.
- **`beforeProviderRequest` able to rewrite the request.** Rejected,
  because `transformContext` is the sanctioned rewrite point (`LOOP-2`)
  and the TRD gives this hook no "can" capability. Two rewrite points
  would make the effective request order-dependent across hooks.
- **Registering hooks directly on `Agent` (no `ExtensionContext`).**
  Rejected. `§3.6` makes `AgentExtension` the packaging unit, and a
  batch committed by `install(_:)` is what gives a failed install no
  partial effect.
- **Serializing installs (a second `install(_:)` waits for, or is
  refused during, the first).** Rejected. The commit-time checks already
  make concurrent installs safe, and commit order is a deterministic,
  documented rule (`API-4`).
- **Letting `sessionBeforeCompact` return a whole compaction entry (cut
  point included), as pi's `session_before_compact` can.** Rejected for
  the first cut. `§3.5` says `ApusKitSessions` owns the cut policy, so
  an extension supplies only a summarizer. Revisit if a real consumer
  needs a custom cut.

## Open questions for the maintainer

Questions 1, 2, 3 and 6 are **blocking**. Each needs an answer and a
matching TRD amendment before this proposal can be accepted.

1. **(Blocking) What does `ACC-2` mean by "hook handler types":
   closure typealiases or protocols?** This draft proposes closures,
   following 0004's precedent. If you accept that, `ACC-2`/`ACC-3` need
   a one-line TRD clarification. The same amendment should confirm that
   `ExtensionContext` becomes an `actor` with `async` registration,
   which keeps `§3.6`'s signature, rather than the `inout` alternative,
   which changes it.
2. **(Blocking) Where do the `ACC-3` executable contracts for
   `AgentExtension` and the hooks live, and how does a third party test
   an extension?** `PKG-6` says `ApusKitConformance` never imports
   `ApusKitAgent`, but `TEST-6`/`ACC-3` want every conformable protocol
   covered by the Conformance Kit. The options are: (a) amend `PKG-6`
   to allow `Conformance ← Agent`; (b) add a separate
   `ApusKitAgentConformance` product; (c) keep the contracts in
   `ApusKitAgentTests` only, which leaves third parties without a
   runnable kit. Related: should `ExtensionContext` get a public
   test-only way to be built without an `Agent` and to read back what
   was registered? Without one, only individual handlers are testable
   (through the payload initializers). That entry point would naturally
   live wherever (a)/(b) puts the kit.
3. **(Blocking) Does M3 move `Agent` onto a session tree, in this
   proposal or a separate one?** `Compaction.compact` needs
   `replacedThrough: EntryID`, and `ContextItem.summary` must be
   rendered into an `LLMRequestMessage`. pi renders it as a user message
   carrying the summary. That needs the pi version pinned to port the
   exact wording. Wiring requires `Agent` to hold a `Session`, plus an
   injected entry-ID source (`DI-1`), and to journal to a `SessionStore`.
   0004 deferred that wiring to M3. If it goes into a separate proposal,
   "Compaction wiring" and the whole `sessionBeforeCompact` hook move
   there with it (see that section), and that proposal must also land
   in M3.
4. **Does `shouldStopAfterTurn` end only the inner loop or the whole
   run?** `§3.6` says "can end the run". This draft ends the run and
   leaves queued follow-ups in the queue for the next `run(_:)`. The
   alternative is to drain them, which a budget would not want.
5. **Should `Agent.shutdown() async` be added?** `sessionShutdown`
   needs something to fire on, and `deinit` cannot await. The other
   option is to fire it from `deinit` best-effort with no await. If it
   is added, should it also drop all hooks and extension tools, which
   breaks any retain cycle a consumer's hooks created?
6. **(Blocking) Do model switching (`F1.3`), the provider registry and
   the session store belong here?** `§3.6` promises that
   `ExtensionContext` exposes a provider registry and a session store,
   but `Agent` holds neither: `providers` would be an optional snapshot
   fixed at init, and there is no store until question 3 is answered.
   `modelSelect` needs a trigger, but `Agent` holds
   `let model`/`let apiImplementation`. This draft fires `modelSelect`
   only at start and makes both properties optional. Either `§3.6` is
   amended to make them optional, or `Agent` gains them first. A
   `selectModel(_:)` API is a separate family (DOC-4). `F1.3` was
   scheduled in M1, so should it be tracked as an M3 gap?
7. **Which pi version is the porting reference?** The ordering rules,
   the `toolCall` block text and the `sessionBeforeCompact` semantics
   above come from pi's extension runner. It is not vendored, and no pi
   version is pinned in `conformance-baseline.yml`. The answer probably
   matches the version chosen for the SESS-1 recording.
8. **How does `sessionBeforeCompact` get a firing point: split the
   Sessions API or wrap the summarizer?** This draft proposes a 0004
   amendment adding `Compaction.tokenCountsIfCompactionNeeded`, which
   widens `ApusKitSessions`' public surface by one function. Wrapping
   the summarizer needs no Sessions change, but it fires inside a call
   that may be retried up to `maxAttempts` times and can express
   `.cancel` only as a thrown sentinel error. Only relevant if question
   3 keeps compaction in this proposal.
9. **How should a re-entrant `run(_:)` from a hook be handled?** This
   draft detects it with a `@TaskLocal` marker and returns an `.error`
   final message (new `AgentError` code `.reentrantRun`). A task-local
   is declared `static`. It is task-scoped rather than global mutable
   state, but you may read `DI-1` otherwise. The alternatives are to
   document it as a precondition violation (it deadlocks), or to drop
   `agent` from `ExtensionContext` in favour of a narrower handle, which
   needs a `§3.6` amendment. Relatedly, is a weak `agent` (nil after
   deinit) acceptable for `§3.6`'s "agent handle"?
10. **Should errored turns count against `WF-2` budgets?** Today their
    `Usage` is zeroed (`finalMessage(for:)`), and `StreamEvent.error`
    carries none, so a bus-based budget undercounts them. Fixing it
    needs `Usage` on the stream's error path, which is a wire-format
    change for M5 or a separate proposal. Is the documented gap
    acceptable for 0.1.0?
11. **Is installing only while idle acceptable?** `MCPToolSource`
    (M4) must refresh tools on list-changed notifications, which can
    arrive mid-run. That would need an `unregister`/replace path and a
    rule for "takes effect at the next turn boundary". Should that seam
    be specified now, or in the M4 proposal?
