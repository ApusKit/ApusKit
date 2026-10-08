# 0007 — Agent run control: steering, queue modes, and queue clearing

Status: draft (M3 Public 0.1.0, F4.2/F4.4/F4.5). Not implemented.

## Motivation

M3's first deliverable is "Steering, abort, event stream surfaced (F4.2,
F4.4, F4.5)" (`PRD.md` §5). Most of that surface already exists. This
proposal covers only the missing part, so it starts with an inventory of
what `Sources/ApusKitAgent` already exposes.

### What is already public

| PRD | Public today | Rule coverage |
|---|---|---|
| F4.5 event stream | `Agent.makeEventStream(bufferingPolicy:)`, defaulting to `.bufferingNewest(256)`. `AgentEvent` has the ten `§3.6` cases. Every stream finishes in `deinit` | `EVENT-1` (independent streams), `EVENT-2` (bounded by default), `EVENT-3` (lifetime of the agent, runs delimited by `.agentStart`/`.agentEnd`). Tested in `AgentTests` (`everyObserverSeesEveryEvent`, `undrainedStreamIsBounded`, `streamFinishesWhenAgentDeinitializes`) |
| F4.4 abort | `Agent.abort()` cancels the run's task. The loop and the `LOOP-7` tool group unwind to a final `.aborted` message | `LOOP-6`. Tested by `abortMidStreamEndsInAborted` |
| LOOP-1 follow-up queue | `Agent.run(_:)` appends to `followUpQueue`. A `run(_:)` that arrives during a run joins it, and the outer loop drains the queue one message at a time | `LOOP-1` outer loop. Tested by `outerLoopDrainsMessageQueuedMidRun`. `queuedFollowUpCount` is `package` (`PKG-8`) |

F4.4 and F4.5 need **no new public API**, but F4.5 needs a payload change
on two existing cases (gap 3). F4.2 has no API at all. These are the gaps
against `§3.6`, `LOOP-1`, `LOOP-2`, `LOOP-5` and pi:

1. **No steering queue.** `§3.6` says `Agent` owns "steering + follow-up
   queues". `LOOP-1`'s inner loop must continue "while tool calls **or
   steering messages** exist", and `LOOP-2` starts each turn with "inject
   steering". `RunLoop.swift` has neither.
2. **No queue modes.** `LOOP-5` requires `all | oneAtATime`. The
   follow-up drain is hard-wired to one at a time.
3. **User messages are invisible on the event stream.** `.messageStart`
   has no payload and `.messageEnd` carries an `AssistantMessage`. A UI
   cannot see when a prompt, follow-up or steering message entered the
   conversation. pi emits `message_start`/`message_end` carrying the
   message for every user message it injects (pi-agent-core 0.72.1,
   `agent-loop.js` lines 51-52 for the prompt, 95-96 for steering and
   follow-ups).
4. **`run(_:)`'s own message shares the follow-up queue.** `run(_:)`
   appends its message to the tail of `followUpQueue` (`Agent.swift:108`),
   and the outer loop takes from the head (`RunLoop.swift:20`). After
   `abort()`, `drainFollowUpQueue()` breaks out and leaves the remaining
   follow-ups queued, so the next `run(_:)` sends those stale follow-ups
   **before** its own message, even though their callers already got
   `.aborted`. pi does not do this: `prompt()` hands its messages to
   `runAgentLoop` directly (`agent.js` ~215-221, `agent-loop.js` 43-52),
   and queued follow-ups are drained only after the prompt's run would
   stop.
5. **No way to take back queued messages.** pi-agent-core has
   `clearSteeringQueue`/`clearFollowUpQueue`/`clearAllQueues`
   (`agent.js` 173-183); ApusKit has nothing.
6. **`run(_:)` can strand a message (existing bug).** See
   [Existing race in `run(_:)`](#existing-race-in-run_).

## Proposed API (`ApusKitAgent`)

Ported from pi-agent-core's `Agent` (`steer`, `steeringMode`,
`followUpMode`, `PendingMessageQueue.drain`) and `runLoop`, as `§3.6`
requires ("ported from pi 1:1, normative"). The reference was pi 0.72.1
as installed locally. See open question 9. Where this draft departs from
pi-agent-core, the departure is listed under
[Deliberate deviations](#deliberate-deviations-from-pi-agent-core).

```swift
extension Agent {
  /// How a message queue releases queued messages to the run loop (`LOOP-5`).
  ///
  /// Sealed (`ACC-2`). `@nonexhaustive(warn)` per `ENUM-1`.
  @nonexhaustive(warn)
  public enum QueueMode: Sendable, Equatable {
    /// Each drain releases every queued message, so they enter the
    /// conversation together before one model turn.
    case all

    /// Each drain releases only the oldest queued message, so each one gets
    /// its own model turn. This is pi's default.
    case oneAtATime
  }

  /// Creates an agent.
  ///
  /// - Parameters:
  ///   - apiImplementation: The provider wire adapter to stream turns through.
  ///   - connection: Where and how to reach the provider.
  ///   - model: The model identifier to request.
  ///   - tools: The tools available to the model during this conversation.
  ///   - systemPrompt: An optional system prompt sent with every request.
  ///   - steeringMode: How queued steering messages are drained between turns.
  ///   - followUpMode: How queued follow-up messages are drained when the
  ///     agent would otherwise stop.
  public init(
    apiImplementation: any APIImplementation,
    connection: ProviderConnection,
    model: String,
    tools: ToolRegistry,
    systemPrompt: String? = nil,
    steeringMode: QueueMode = .oneAtATime,
    followUpMode: QueueMode = .oneAtATime
  )

  /// Queues `message` to be injected into the in-flight run before its next
  /// model turn (`LOOP-5`).
  ///
  /// The message is never injected mid-stream. Tool calls the current
  /// assistant message already requested still run. If no run is in
  /// flight, the message waits. The next run that `run(_:)` starts
  /// injects it right after that run's own message and before the run's
  /// first model turn. Queued follow-ups are not sent before it.
  public func steer(_ message: UserMessage)

  /// Removes every queued steering and follow-up message and returns
  /// them, oldest first.
  ///
  /// Call this after `abort()` to get back messages the aborted run never
  /// sent, for example to put them back in an input field. A message
  /// removed here never reaches the model. A `run(_:)` caller whose
  /// follow-up is removed still gets the run's final message.
  public func clearQueuedMessages() -> (steering: [UserMessage], followUps: [UserMessage])
}
```

```swift
// AgentEvent: payload change on two existing cases. The case count stays
// at the ten §3.6 names.
public enum AgentEvent {
  /// A message started entering the conversation: a user message (the
  /// `run(_:)` message, a drained follow-up or an applied steering
  /// message), or an assistant message whose stream has just opened.
  case messageStart(LLMRequestMessage)      // was: case messageStart

  /// A message finished entering the conversation. For a user message it
  /// follows its `.messageStart` immediately. For an assistant message it
  /// carries the final message.
  case messageEnd(LLMRequestMessage)        // was: case messageEnd(AssistantMessage)
  // … other cases unchanged
}
```

**Run semantics of `run(_:)`.** `run(_:)` keeps its signature. What it
does with its message changes:

- **Idle.** `run(_:)` starts a run with its message as the run's prompt.
  The prompt goes straight into `history`, as pi's `prompt()` does. It is
  never put in `followUpQueue` and is never subject to `followUpMode`.
- **A run is in flight.** `run(_:)` appends its message to
  `followUpQueue` and joins the run, as today. The message is a
  follow-up: it is drained in `followUpMode` when the run would
  otherwise stop. pi throws here instead (`prompt()` while `activeRun`);
  joining is the existing ApusKit behaviour and is kept.

So after `abort()` the next `run(_:)` sends, in order: its own message,
any steering queued while idle, then (when the inner loop would stop)
leftover follow-ups. This matches pi's order for a `prompt()` after an
aborted run. A caller who wants the leftovers gone calls
`clearQueuedMessages()` first.

`init` gains two defaulted trailing parameters, so every existing call
site still compiles.

**Isolation (`CC-2`).** `steer(_:)` and `clearQueuedMessages()` are
synchronous and actor-isolated, like `abort()`. Neither is an async
declaration, so `CC-2` adds no annotation. That matches 0005's reading
for `run(_:)` and `install(_:)`.

**Evolution (`ENUM-1`, `CC-3`).** The two payload changes are a source
break for any consumer that matches `.messageStart` or
`.messageEnd(let assistant)`. Nothing has been released (`git tag`
prints nothing, and M3 is the first public 0.1.0), so the break costs
only the two in-repo emit sites (`RunLoop.swift:100`,
`RunLoop.swift:159`); no test matches either case by name today. After 0.1.0 the same change
would be SemVer-major, which is why it belongs in this milestone. No
`docs(trd)` amendment is needed: `§3.6` names the ten cases but not their
payloads. `QueueMode` gets a new row in `docs/sendable-audit.md`, and
the `AgentEvent` row records the new payloads. The same change fixes two
stale claims: the audit's `AgentEvent` row ("deliberately exhaustive, not
`@nonexhaustive`") and `AgentEvent`'s own doc comment ("a plain
(exhaustive) public enum") both contradict the `@nonexhaustive(warn)`
declaration. The exact payload type is open question 3.

### Loop semantics (no new API, ported from pi `runLoop`)

Line references are to pi-agent-core 0.72.1 `agent-loop.js`.

- **Run start.** `.agentStart`, `.turnStart`, then
  `.messageStart`/`.messageEnd` for the prompt (lines 48-52). Then the
  steering queue is polled once in `steeringMode` (line 80), so steering
  queued while idle is injected after the prompt and before the first
  model turn, in the same turn.
- **Inner loop (`LOOP-1`).** After each turn and its tool execution,
  `prepareNextTurn` and `shouldStopAfterTurn` run, then the steering
  queue is drained in `steeringMode` (lines 123-133). The inner loop
  continues if tool calls remained **or** steering was drained. A turn
  with no tool calls but pending steering therefore triggers one more
  turn instead of returning. In pi, `shouldStopAfterTurn` runs after
  **every** turn, including one with no tool calls. That differs from
  the guard at `RunLoop.swift:84` and from 0005's hook table. See
  [Interaction with 0005](#interaction-with-0005) and open question 4.
- **Injection (`LOOP-2`, `LOOP-5`).** Drained steering is appended to
  `history` at the top of the next turn, after `.turnStart` and before
  `transformContext`, with one `.messageStart`/`.messageEnd` pair per
  message (lines 91-99). 0005's `transformContext` hook therefore sees
  it. The stream is never interrupted.
- **Follow-ups (`LOOP-1` outer).** When the inner loop would stop, the
  follow-up queue is drained in `followUpMode` and the drained messages
  are injected like steering at the top of the next turn (lines
  135-141). In `.all` mode, every queued follow-up enters history before
  a single turn.
- **`.error` and `.aborted` turns (`LOOP-3`, `LOOP-6`).** As in pi
  (lines 105-108), a turn whose final message is `.error` or `.aborted`
  ends the run at once with `.agentEnd`. Steering is not polled and stays
  queued. Today `drainFollowUpQueue()` moves on to the next follow-up
  after an `.error`. Whether follow-ups also stay queued is open
  question 1.
- **`.length` turns (`LOOP-4`).** pi has no length rule. `LOOP-4` is
  ApusKit's own: the message's tool calls are failed unexecuted. This
  draft then treats the turn as one with no remaining tool calls, so
  `prepareNextTurn`, `shouldStopAfterTurn` and the steering poll run as
  for any other non-error turn. Pending steering forces another turn;
  otherwise follow-ups are drained. Today the inner loop returns at once
  (`RunLoop.swift:75`). See open question 5.
- **`shouldStopAfterTurn` (0005).** If it returns `true`, the run ends
  with `.agentEnd` before steering is polled, as in pi (lines 123-131).
  What happens to queued messages then is 0005's open question 4; this
  proposal does not decide it. In pi they stay queued.
- **Abort (`LOOP-6`).** `abort()` is unchanged and leaves both queues
  intact, as in pi. `clearQueuedMessages()` is how a caller drops them.

### Interaction with 0005

0005's hook table (`docs/proposals/0005-hook-bus-and-agent-extension.md`,
the `shouldStopAfterTurn` row) says the hook fires "only while tool calls
remain (`LOOP-1`)". That matches today's `RunLoop.swift:84` but not pi,
which calls `shouldStopAfterTurn` after every turn. This draft follows
pi. The two proposals must agree before either lands: either 0005's row
changes to "after every turn", or this draft's inner-loop rule keeps the
current guard. That is open question 4. 0005's open question 4 (does the
hook end the run, and what happens to queued messages) stays 0005's to
answer, and this draft defers to it.

### Existing race in `run(_:)`

**Status: fixed** in `2f993b5` (the drain clears `runningTask` itself),
with `45a7f9f` adding a second regression test. The rest of this section
records the defect as it was found.

Found by reading `Agent.swift:107-118`, not yet by a reproducing test.
`runningTask` is reset to `nil` only after the first caller resumes from
`await task.value` (line 117). Because actor calls interleave, a second
`run(_:)` can be served after `drainFollowUpQueue()` has returned but
before the first caller resumes. That call appends its message (line
108), finds a non-`nil` but finished `runningTask` (line 110), returns
the previous run's result at once, and leaves its message stranded in
the queue until some later `run(_:)`. `steer(_:)` while idle depends on
the same "is a run in flight" state, so it would inherit the race.

This proposal fixes it as part of the work. The run's task clears
`runningTask` itself, on the actor, in the same synchronous stretch as
the final "anything left to do?" check and `.agentEnd`, so no
`run(_:)` can interleave between "the run decided to stop" and "the
agent is idle". Per `TEST-7`, the fix lands with a regression test
written first. The test needs a deterministic interleaving, so it
holds the run open on `GateTool`/`FollowUpGate` and issues the second
`run(_:)` at the exact point described above.

### Deliberate deviations from pi-agent-core

`§3.6` ports pi-agent-core, and TRD §0 principle 1 says to re-decide
nothing pi has decided. Each item below is therefore a deviation, named
as one, not a port.

- **`clearQueuedMessages()` comes from the application layer.** It is
  modelled on pi-coding-agent's `AgentSession.clearQueue()`, which
  returns the cleared messages. pi-agent-core has
  `clearSteeringQueue()`/`clearFollowUpQueue()`/`clearAllQueues()`,
  which return nothing (`agent.js` 173-183). The reason to deviate is
  that F4.4 asks for a clean abort, and a clear that discards input the
  caller cannot recover makes `abort()` lossy for a UI. The returned
  lists make the method a superset of `clearAllQueues()`. It is still
  scope beyond the core port, which is what this proposal exists to
  approve (`§9.8`, `DOC-4`). Open question 6.
- **Queue modes are init-only.** pi-agent-core has runtime setters for
  `steeringMode` and `followUpMode` (`agent.js` 151-162). Nothing in
  F4.2/F4.4/F4.5 or `LOOP-5` asks to change a mode mid-conversation. A
  public `var` on an actor cannot be set from outside its isolation, so
  parity would need `setSteeringMode(_:)`/`setFollowUpMode(_:)` methods.
  This draft leaves them out to keep the 0.1.0 surface small. Adding
  them later is additive. Open question 7.
- **`run(_:)` joins an in-flight run instead of throwing.** Existing
  behaviour (`LOOP-1` outer loop, `outerLoopDrainsMessageQueuedMidRun`),
  kept. pi's `prompt()` throws, and pi offers `followUp(_:)` instead.
  Open question 2.

### Tests (TEST-2, TEST-4, TEST-7, TEST-8)

Every new loop rule gets a `TEST-4` dump test on `RequestRecordingProvider`
plus `GateTool`/`FollowUpGate`, built so that removing the rule changes
the dump. The cases are:

- steering applied between turns and never mid-stream;
- steering after a no-tool-call turn forcing another turn;
- `.all` versus `.oneAtATime` for both queues, with at least two
  messages queued;
- steering queued while idle, injected after the `run(_:)` message and
  before the first turn;
- `run(_:)` after `abort()` with leftover follow-ups: the dump shows the
  new message first and the leftovers only after the inner loop would
  stop, and `followUpMode` never batches the new message with them;
- `clearQueuedMessages()` after `abort()`;
- steering pending when a turn ends in `.error`: the run ends, steering
  is not injected and is still queued;
- steering pending when a turn ends in `.length`: the tool calls are
  failed (`LOOP-4`) and the steering forces one more turn (subject to
  open question 5);
- `.messageStart`/`.messageEnd` pairs for the prompt, each follow-up and
  each steering message, in injection order;
- the `run(_:)` race regression test, written before the fix (`TEST-7`).

A `package` accessor `queuedSteeringCount` mirrors `queuedFollowUpCount`
(`PKG-8`). The `TEST-8` Evals "steering mid-run" and "abort" scenarios
use the same public API.

## Alternatives considered

- **A public `followUp(_:)` that only queues, like pi's.** Rejected for
  now. `run(_:)` already queues a follow-up when a run is in flight. When
  idle, a queue-only call would just wait for a `run(_:)`, so it is not
  needed for F4.2. See open question 2.
- **Make `abort()` clear the queues.** Rejected because pi keeps them,
  and clearing would lose user input that the caller cannot recover.
  Returning them from `clearQueuedMessages()` lets the caller choose.
- **pi-agent-core's three clear methods, returning nothing.** The 1:1
  port. Not chosen by this draft for the reason in
  [Deliberate deviations](#deliberate-deviations-from-pi-agent-core);
  open question 6 asks the maintainer to confirm.
- **A `QueuedMessages` struct instead of a labelled tuple.** A struct
  could grow fields later, but no extra field is foreseen, and a tuple
  adds no type to the audit. This is easy to change before 0.1.0.
- **A new `.userMessage(UserMessage)` case instead of reshaping
  `.messageStart`/`.messageEnd`.** The previous draft of this proposal.
  Rejected: it adds an eleventh case that `§3.6` does not list, so it
  would need a `docs(trd)` amendment, and it departs from pi, which
  reuses `message_start`/`message_end`. Its only advantage was avoiding
  a source break, and before 0.1.0 there is nothing to break.
- **Keep `run(_:)`'s message in `followUpQueue`.** Smaller diff, but
  stale follow-ups after `abort()` run before the new message, and in
  `.all` mode the new message is batched with them. Neither matches pi.
- **Public `isRunning` or `waitForIdle()`.** Not needed. `run(_:)`
  already returns when the run ends, and `.agentEnd` marks the end on the
  stream.

## Open questions for the maintainer

1. **Should a run that ends in `.error` keep queued follow-ups queued?**
   In pi, an `error` or `aborted` assistant message ends the run with
   `agent_end`, and queued steering and follow-ups stay queued.
   `drainFollowUpQueue()` today only breaks on cancellation; after an
   `.error` it moves on to the next follow-up. This draft ends the run
   and keeps steering queued on `.error`. Should follow-ups also stay
   queued, as `§3.6` "1:1, normative" implies? That changes observable
   behaviour for joined `run(_:)` callers.
2. **Should `followUp(_:)` (queue-only, no run started) be public in
   0.1.0,** for pi parity? This draft says no, and keeps `run(_:)`
   joining an in-flight run instead of throwing.
3. **What payload should `.messageStart`/`.messageEnd` carry?** This
   draft uses `LLMRequestMessage`, which already exists and has `.user`
   and `.assistant`. Alternatives: a new agent-level message enum, or
   only widening `.messageEnd` and leaving the assistant `.messageStart`
   payload empty-partial. pi also emits the pair for each tool-result
   message (`agent-loop.js` line 455); `LLMRequestMessage.toolResult`
   could carry that, but this draft does not add it, because
   `.toolExecutionEnd` already reports results. Should it? Should the
   event also say where a user message
   came from (prompt, follow-up, steering)? pi does not, so this draft
   does not.
4. **Does `shouldStopAfterTurn` run after every turn (pi) or only while
   tool calls remain (today's `RunLoop.swift:84`, 0005's hook table)?**
   This draft follows pi. 0005 and 0007 must agree before either lands,
   so one of them changes. Separately, 0005's open question 4 (does the
   hook end the whole run, and what happens to queued messages) is
   0005's to answer; this draft defers to it.
5. **What happens after a `.length` turn?** `LOOP-4` is not from pi.
   This draft fails the tool calls, then polls steering and drains
   follow-ups as for any other non-error turn. The alternative is to end
   the inner loop at once as today, which leaves steering queued until
   the follow-up drain or the next run.
6. **Should queue clearing be pi-agent-core's three void methods (the
   1:1 port) or this draft's single `clearQueuedMessages()` that returns
   the messages (from pi-coding-agent's `AgentSession`)?** Choosing the
   latter is a deliberate deviation from the core port under TRD §0
   principle 1.
7. **Should the queue modes be settable at runtime, as in pi-agent-core**
   (`setSteeringMode(_:)`/`setFollowUpMode(_:)` on the actor), or stay
   init-only as in this draft?
8. **Should both modes default to `.oneAtATime`?** That is pi's default
   and today's follow-up behaviour. `LOOP-5` names the modes but no
   default.
9. **Which pi version is the porting reference?** This is the same
   question as 0005 open question 7. This draft read pi-agent-core
   0.72.1 as installed. Nothing pins it in `conformance-baseline.yml`.
10. **Should cancelling the task that awaits `run(_:)` abort the run?**
    `run(_:)` drives the loop in an unstructured `Task`, so cancelling
    the caller does nothing today. F4.4 says "clean abort at any
    moment", and only `abort()` provides one. Wrapping the await in
    `withTaskCancellationHandler { … } onCancel: { abort() }` would make
    ordinary Swift cancellation work too. It is not new API, but it
    changes behaviour, and with joined callers it would let one caller
    cancel everyone's run.
11. **Should the `run(_:)` race fix land in this PR or ahead of it as a
    standalone `fix(m3):` commit?** This draft includes it because
    steering-while-idle depends on it.
