// ApusKitAgentTests
//
// The M0 gate suite: drives the real Agent actor against ScriptedProvider
// with no network and no API keys (TEST-1: Swift Testing only; TEST-2:
// protocol-seam fakes only).

import ApusKitAgent
import ApusKitCore
import ApusKitProviders
import ApusKitTools
import Foundation
import JSONSchema
import TestSupport
import Testing

/// Builds an `Agent` wired to `provider` and `tools`, with a throwaway
/// connection the test providers ignore entirely.
private func makeAgent(provider: some APIImplementation, tools: [AnyAgentTool]) -> Agent {
  var registry = ToolRegistry()
  for tool in tools {
    registry.register(tool)
  }

  // Force-unwrap justified: "https://example.invalid" is a fixed, valid URL literal.
  // swift-format-ignore: NeverForceUnwrap
  let baseURL = URL(string: "https://example.invalid")!

  return Agent(
    apiImplementation: provider,
    connection: ProviderConnection(
      baseURL: baseURL, auth: .none, transport: NeverCalledTransport()),
    model: "test-model",
    tools: registry
  )
}

/// Builds an `Agent` wired to `provider` and a single `tool`.
private func makeAgent(provider: some APIImplementation, tool: some Tool) -> Agent {
  makeAgent(provider: provider, tools: [AnyAgentTool(tool)])
}

/// A `StreamingHTTPTransport` that fails the test if it is ever called —
/// `ScriptedProvider` must never touch the network.
private struct NeverCalledTransport: StreamingHTTPTransport {
  func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, any Error> {
    Issue.record("StreamingHTTPTransport must not be invoked by ScriptedProvider")
    return AsyncThrowingStream { $0.finish() }
  }
}

/// Every `ToolResultMessage` in `request`, in send order.
private func toolResults(in request: LLMRequest) -> [ToolResultMessage] {
  request.messages.compactMap { message in
    if case .toolResult(let result) = message {
      return result
    }
    return nil
  }
}

/// The concatenated text of every user message in `request`, in order.
private func userTexts(in request: LLMRequest) -> [String] {
  request.messages.compactMap { message in
    guard case .user(let user) = message else {
      return nil
    }
    return text(of: user.content)
  }
}

/// The concatenated text of `blocks`, ignoring non-text content.
private func text(of blocks: [ContentBlock]) -> String {
  blocks.compactMap { block in
    if case .text(let text) = block {
      return text
    }
    return nil
  }.joined()
}

/// Coverage for `Agent`'s event-observation surface (TRD §3.6).
///
/// Each defect these pin was live and unnoticed because every earlier test
/// `break`s out of the stream on its first matching event, so none of them
/// ever observed termination, a second observer, or buffer growth.
@Suite("Agent event streams")
struct AgentEventStreamTests {
  @Test(
    "a stream finishes when the agent goes away, so `for await` returns",
    .timeLimit(.minutes(1))
  )
  func streamFinishesWhenAgentDeinitializes() async throws {
    // The agent is confined to the helper, so it is released as soon as
    // the helper returns. Without `deinit` finishing every continuation
    // this loop never returns and the time limit fires.
    let events = await runAndReleaseAgent()

    var seen: [AgentEvent] = []
    for await event in events {
      seen.append(event)
    }
    #expect(seen.contains(.agentStart))
    #expect(seen.contains { if case .agentEnd = $0 { return true } else { return false } })
  }

  @Test("two observers each receive every event", .timeLimit(.minutes(1)))
  func everyObserverSeesEveryEvent() async throws {
    let agent = makeAgent(
      provider: ScriptedProvider(scripts: [ScriptedTurn.text("done")]),
      tool: RecordingTool()
    )
    let first = await agent.makeEventStream()
    let second = await agent.makeEventStream()

    async let firstSeen = collectThroughAgentEnd(first)
    async let secondSeen = collectThroughAgentEnd(second)

    _ = await agent.run(UserMessage(content: [.text("hello")]))

    let a: [AgentEvent] = await firstSeen
    let b: [AgentEvent] = await secondSeen
    // A single shared stream would let one observer consume events the
    // other never sees, so the two transcripts would diverge.
    #expect(a == b)
    #expect(a.contains(.agentStart))
  }

  @Test("the buffering policy bounds an undrained stream", .timeLimit(.minutes(1)))
  func undrainedStreamIsBounded() async throws {
    // Never iterated during the run: with the default `.unbounded` policy
    // every event would be retained instead of just the newest.
    let events = await runAndReleaseAgent(bufferingPolicy: .bufferingNewest(1))

    var seen: [AgentEvent] = []
    for await event in events {
      seen.append(event)
    }
    #expect(seen.count == 1)
  }
}

/// Runs one scripted turn and returns its event stream, releasing the agent.
///
/// The agent is local to this function precisely so that it has no
/// remaining strong reference by the time the caller drains the stream —
/// which is what makes the stream's termination observable at all.
private func runAndReleaseAgent(
  bufferingPolicy: AsyncStream<AgentEvent>.Continuation.BufferingPolicy = .unbounded
) async -> AsyncStream<AgentEvent> {
  let agent = makeAgent(
    provider: ScriptedProvider(scripts: [ScriptedTurn.text("done")]),
    tool: RecordingTool()
  )
  let events = await agent.makeEventStream(bufferingPolicy: bufferingPolicy)
  _ = await agent.run(UserMessage(content: [.text("hello")]))
  return events
}

/// Collects a stream up to and including the run's terminating `.agentEnd`.
private func collectThroughAgentEnd(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
  var seen: [AgentEvent] = []
  for await event in stream {
    seen.append(event)
    if case .agentEnd = event { break }
  }
  return seen
}

@Suite("Agent gate suite")
struct AgentGateTests {
  @Test("scripted multi-turn tool round-trip ends in .endTurn")
  func multiTurnToolRoundTrip() async throws {
    let log = RequestLog()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCall(
          id: "call_1", name: "recording_tool", argumentsJSON: #"{"value":"hi"}"#),
        ScriptedTurn.text("all done"),
      ],
      log: log
    )
    let tool = RecordingTool(result: ToolResult(content: [.text("tool output")]))
    let agent = makeAgent(provider: provider, tool: tool)

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))

    #expect(final.stopReason == .endTurn)
    #expect(final.content == [.text("all done")])

    let calls = await tool.recordedCalls
    #expect(calls == [RecordingTool.Arguments(value: "hi")])

    // The RETURN leg of the round-trip. Asserting only that the tool ran
    // and that the second turn ended .endTurn leaves the gate's "the
    // result feeds back" clause unpinned: ScriptedProvider ignores the
    // request, so the second turn's text is preordained and stays green
    // even if the ToolResultMessage is never appended to the history.
    let requests = await log.requests
    #expect(requests.count == 2)
    let secondRequest = try #require(requests.last)
    let results = toolResults(in: secondRequest)
    #expect(results.map(\.toolCallID) == ["call_1"])
    #expect(results.map(\.isError) == [false])
    #expect(results.first?.content == [.text("tool output")])
  }

  @Test("TOOL-2: the loop classifies a tool result by isError, not by a details key")
  func loopClassifiesFailureByIsErrorField() async throws {
    let log = RequestLog()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCall(
          id: "call_1", name: "recording_tool", argumentsJSON: #"{"value":"hi"}"#),
        ScriptedTurn.text("all done"),
      ],
      log: log
    )
    // Succeeds, but carries an "error" entry in its descriptive metadata.
    // The old rule — `details["error"] != nil` — would mislabel this.
    let tool = RecordingTool(
      result: ToolResult(content: [.text("fine")], details: ["error": .string("just metadata")])
    )
    let agent = makeAgent(provider: provider, tool: tool)

    _ = await agent.run(UserMessage(content: [.text("go")]))

    let requests = await log.requests
    let secondRequest = try #require(requests.last)
    let results = toolResults(in: secondRequest)
    #expect(results.map(\.isError) == [false])
  }

  @Test("TOOL-2: a tool reporting isError with empty details reaches the model as an error")
  func loopForwardsIsErrorWithoutDetails() async throws {
    let log = RequestLog()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCall(
          id: "call_1", name: "recording_tool", argumentsJSON: #"{"value":"hi"}"#),
        ScriptedTurn.text("all done"),
      ],
      log: log
    )
    // The mirror image: a real failure with nothing in `details`.
    let tool = RecordingTool(
      result: ToolResult(content: [.text("could not do it")], isError: true)
    )
    let agent = makeAgent(provider: provider, tool: tool)

    _ = await agent.run(UserMessage(content: [.text("go")]))

    let requests = await log.requests
    let secondRequest = try #require(requests.last)
    let results = toolResults(in: secondRequest)
    #expect(results.map(\.isError) == [true])
  }

  @Test("PROV-1: argument JSON split across chunk boundaries is accumulated intact")
  func splitArgumentChunksAccumulate() async throws {
    // PROV-1 requires the accumulator to survive argument JSON split
    // across arbitrary chunk boundaries. Every other script delivers the
    // arguments in a single delta, which cannot detect an accumulator
    // that drops, overwrites or reorders chunks.
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.toolCallSplit(
        id: "call_1",
        name: "recording_tool",
        argumentChunks: [#"{"val"#, #"ue":"#, #""split ac"#, #"ross chunks"}"#]
      ),
      ScriptedTurn.text("all done"),
    ])
    let tool = RecordingTool()
    let agent = makeAgent(provider: provider, tool: tool)

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))
    #expect(final.stopReason == .endTurn)

    // Decoding at all proves the chunks were joined in order: any other
    // ordering is invalid JSON and would surface as an error result.
    let calls = await tool.recordedCalls
    #expect(calls == [RecordingTool.Arguments(value: "split across chunks")])
  }

  @Test("LOOP-1: tool calls run even when the stop reason is not .toolUse")
  func toolCallsRunRegardlessOfStopReason() async throws {
    // Regression (TEST-7): the inner loop used to key on
    // `stopReason == .toolUse` and evaluate that BEFORE executing tools,
    // so a message carrying tool calls with any other stop reason had
    // them silently dropped. LOOP-1 continues while tool calls remain;
    // LOOP-2 orders shouldStopAfterTurn last.
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.toolCallStopping(
        id: "call_1",
        name: "recording_tool",
        argumentsJSON: #"{"value":"hi"}"#,
        stopReason: .endTurn
      ),
      ScriptedTurn.text("all done"),
    ])
    let tool = RecordingTool()
    let agent = makeAgent(provider: provider, tool: tool)

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))

    let calls = await tool.recordedCalls
    #expect(calls == [RecordingTool.Arguments(value: "hi")])
    #expect(final.content == [.text("all done")])
  }

  @Test("TOOL-2/LOOP-3: a throwing tool becomes an error result without taking down the loop")
  func throwingToolBecomesErrorResultWithoutCrashing() async throws {
    let log = RequestLog()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCall(
          id: "call_1", name: "throwing_tool", argumentsJSON: #"{"value":"boom"}"#),
        ScriptedTurn.text("recovered"),
      ],
      log: log
    )
    let agent = makeAgent(provider: provider, tool: ThrowingTool())

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))

    // The loop survives the throwing tool and completes a second turn.
    #expect(final.stopReason == .endTurn)
    #expect(final.content == [.text("recovered")])

    // Surviving is not enough: the model has to be TOLD the call failed,
    // or it will read the failure as a success and carry on. Without this,
    // hardcoding `isError` to false keeps the whole suite green.
    let requests = await log.requests
    let secondRequest = try #require(requests.last)
    let results = toolResults(in: secondRequest)
    #expect(results.map(\.toolCallID) == ["call_1"])
    #expect(results.map(\.isError) == [true])
  }

  @Test("TOOL-2: an unknown tool name becomes an error result, not a crash or a silent skip")
  func unknownToolBecomesErrorResult() async throws {
    let log = RequestLog()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCall(
          id: "call_1", name: "no_such_tool", argumentsJSON: #"{"value":"hi"}"#),
        ScriptedTurn.text("recovered"),
      ],
      log: log
    )
    let agent = makeAgent(provider: provider, tool: RecordingTool())

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))
    #expect(final.stopReason == .endTurn)

    let requests = await log.requests
    let secondRequest = try #require(requests.last)
    let results = toolResults(in: secondRequest)
    #expect(results.map(\.toolCallID) == ["call_1"])
    #expect(results.map(\.isError) == [true])

    let failure = try #require(results.first)
    #expect(text(of: failure.content).contains("no_such_tool"))
  }

  @Test("LOOP-3: a provider error event ends the run as .error, without throwing out")
  func providerErrorEventEndsRunAsError() async throws {
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.error(code: .provider, message: "provider rejected the request")
    ])
    let agent = makeAgent(provider: provider, tool: RecordingTool())

    let final = await agent.run(UserMessage(content: [.text("hello")]))

    // LOOP-3's .error half: without this, a mutant reporting provider
    // failure as a successful .endTurn passes the entire suite — only the
    // .aborted half was covered.
    #expect(final.stopReason == .error)
    #expect(text(of: final.content).contains("provider rejected the request"))
  }

  @Test("LOOP-3: a stream that throws ends the run as .error, without throwing out")
  func throwingStreamEndsRunAsError() async throws {
    // The other shape a real transport produces: the stream itself
    // terminates with an error rather than delivering a StreamEvent.error.
    let provider = ThrowingStreamProvider(
      error: StreamError(code: .transport, message: "connection dropped"))
    let agent = makeAgent(provider: provider, tool: RecordingTool())

    let final = await agent.run(UserMessage(content: [.text("hello")]))

    #expect(final.stopReason == .error)
    #expect(text(of: final.content).contains("connection dropped"))
  }

  @Test(
    "LOOP-1: the outer loop drains a message queued while a run is in flight",
    .timeLimit(.minutes(1))
  )
  func outerLoopDrainsMessageQueuedMidRun() async throws {
    // LOOP-1's OUTER loop. Every other test queues exactly one message per
    // sequential run() call, so replacing the followUpQueue `while` drain
    // with a single-shot `if` — silently dropping anything queued during
    // an in-flight run — passes the whole suite.
    let log = RequestLog()
    let gate = FollowUpGate()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCall(
          id: "call_1", name: "gate_tool", argumentsJSON: #"{"value":"hold"}"#),
        ScriptedTurn.text("first done"),
        ScriptedTurn.text("second done"),
      ],
      log: log
    )
    let agent = makeAgent(provider: provider, tool: GateTool(gate: gate))
    let events = await agent.makeEventStream()

    let firstRun = Task { await agent.run(UserMessage(content: [.text("first")])) }

    // Hold the run open inside tool execution, queue a second message into
    // it, and only then let the tool finish.
    await gate.waitUntilStarted()
    let secondRun = Task { await agent.run(UserMessage(content: [.text("second")])) }
    while await agent.queuedFollowUpCount == 0 {
      await Task.yield()
    }
    await gate.release()

    _ = await firstRun.value
    _ = await secondRun.value

    let requests = await log.requests
    #expect(requests.count == 3)

    // The second message reached the provider at all...
    let sawSecondMessage = requests.contains { userTexts(in: $0).contains("second") }
    #expect(sawSecondMessage)

    // ...and it did so through the SAME run, not a fresh one. If the wait
    // above ever landed after the drain finished, run() would have started
    // a second agent run — which still sends the message, and would make
    // this test pass without exercising the outer loop at all. Exactly one
    // .agentStart is what distinguishes the two.
    var agentStarts = 0
    for await event in events {
      if case .agentStart = event {
        agentStarts += 1
      }
      if case .agentEnd = event {
        break
      }
    }
    #expect(agentStarts == 1)
  }

  @Test(
    "LOOP-1: run(_:) called as a run ends starts a fresh run, not the previous one's result",
    .timeLimit(.minutes(1))
  )
  func runCalledAtAgentEndStartsAFreshRun() async throws {
    // Regression test (TEST-7) for the race described in proposal 0007:
    // `runningTask` used to be cleared only once the first caller resumed
    // from `await task.value`. A `run(_:)` served on the actor after the
    // drain had finished but before that resumption queued its message,
    // found the finished-but-non-nil task, returned the PREVIOUS run's
    // result, and stranded its message in the follow-up queue.
    let agent = makeAgent(
      provider: ScriptedProvider(scripts: [
        ScriptedTurn.text("first done"),
        ScriptedTurn.text("second done"),
      ]),
      tool: RecordingTool()
    )

    // The seam runs synchronously on the actor inside the drain's final
    // stretch. A `Task` created there with the agent's isolation is
    // enqueued directly on the actor (Swift Evolution SE-0431), so it runs after the drain
    // task completes but strictly before the first caller resumes from
    // `await task.value` — the exact window, every time, with no timing.
    let (secondRuns, secondRunsContinuation) = AsyncStream<Task<AssistantMessage, Never>>
      .makeStream()
    await agent.setRunEndingProbe { agent in
      agent.runEndingProbe = nil
      secondRunsContinuation.yield(
        Task { await agent.run(UserMessage(content: [.text("second")])) })
      secondRunsContinuation.finish()
    }

    let first = await agent.run(UserMessage(content: [.text("first")]))
    var secondRun: Task<AssistantMessage, Never>?
    for await run in secondRuns {
      secondRun = run
    }
    let second = try #require(await secondRun?.value)

    #expect(text(of: first.content) == "first done")
    #expect(text(of: second.content) == "second done")
    #expect(await agent.queuedFollowUpCount == 0)
  }

  @Test("LOOP-4: a .length stop fails all tool calls of that message, unexecuted")
  func lengthStopFailsToolCallsUnexecuted() async throws {
    let log = RequestLog()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCallTruncatedByLength(
          id: "call_1",
          name: "recording_tool",
          argumentsJSON: #"{"value":"trunc"#
        ),
        ScriptedTurn.text("continued"),
      ],
      log: log
    )
    let tool = RecordingTool()
    let agent = makeAgent(provider: provider, tool: tool)

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))

    #expect(final.stopReason == .length)

    // The tool must never have been invoked: truncated arguments are
    // unsafe to execute.
    let calls = await tool.recordedCalls
    #expect(calls.isEmpty)

    // The unexecuted calls must still be FAILED, not skipped: the next
    // request has to answer every tool call the truncated message made.
    let followUp = await agent.run(UserMessage(content: [.text("continue")]))
    #expect(followUp.stopReason == .endTurn)

    let requests = await log.requests
    let lastRequest = try #require(requests.last)
    let results = lastRequest.messages.compactMap { message -> ToolResultMessage? in
      if case .toolResult(let result) = message {
        return result
      }
      return nil
    }
    #expect(results.map(\.toolCallID) == ["call_1"])
    #expect(results.map(\.isError) == [true])

    // The failure has to say something the model can act on, not be an
    // empty placeholder result.
    let failure = try #require(results.first)
    let failureText = failure.content.compactMap { block -> String? in
      if case .text(let text) = block {
        return text
      }
      return nil
    }.joined()
    #expect(failureText.contains("recording_tool"))
    #expect(failureText.contains("length"))

    let stillRecorded = await tool.recordedCalls
    #expect(stillRecorded.isEmpty)
  }

  @Test("LOOP-7: tool calls in one message execute in parallel")
  func toolCallsExecuteInParallel() async throws {
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.toolCalls([
        (id: "call_1", name: "probe_a", argumentsJSON: #"{"value":"a"}"#),
        (id: "call_2", name: "probe_b", argumentsJSON: #"{"value":"b"}"#),
      ]),
      ScriptedTurn.text("all done"),
    ])
    let probe = ConcurrencyProbe()
    let agent = makeAgent(
      provider: provider,
      tools: [
        AnyAgentTool(ConcurrencyProbeTool(name: "probe_a", probe: probe)),
        AnyAgentTool(ConcurrencyProbeTool(name: "probe_b", probe: probe)),
      ]
    )

    let final = await agent.run(UserMessage(content: [.text("please use both tools")]))

    #expect(final.stopReason == .endTurn)

    // Both calls were in flight at the same time: they ran in parallel,
    // not one after the other.
    let maxConcurrent = await probe.maxConcurrent
    #expect(maxConcurrent == 2)

    let completed = await probe.completedNames
    #expect(completed.sorted() == ["probe_a", "probe_b"])
  }

  @Test("LOOP-7: a result with terminate: true ends the rest of the batch")
  func terminatingResultEndsTheBatch() async throws {
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.toolCalls([
        (id: "call_1", name: "terminating_tool", argumentsJSON: #"{"value":"stop"}"#),
        (id: "call_2", name: "slow_tool", argumentsJSON: #"{"value":"slow"}"#),
      ]),
      ScriptedTurn.text("all done"),
    ])
    let probe = ConcurrencyProbe()
    let agent = makeAgent(
      provider: provider,
      tools: [
        AnyAgentTool(
          ConcurrencyProbeTool(
            name: "terminating_tool", probe: probe, duration: .zero, terminate: true)),
        AnyAgentTool(
          ConcurrencyProbeTool(name: "slow_tool", probe: probe, duration: .seconds(30))),
      ]
    )

    let final = await agent.run(UserMessage(content: [.text("please use both tools")]))

    #expect(final.stopReason == .endTurn)

    // The terminating result ended the batch, so the slow call was
    // cancelled long before its own sleep could finish.
    let completed = await probe.completedNames
    #expect(completed == ["terminating_tool"])
  }

  @Test(
    "LOOP-6: abort() mid-stream ends the run with a clean .aborted final message",
    .timeLimit(.minutes(1))
  )
  func abortMidStreamEndsInAborted() async throws {
    let agent = makeAgent(provider: HangingProvider(), tool: RecordingTool())
    let events = await agent.makeEventStream()

    let run = Task { await agent.run(UserMessage(content: [.text("hello")])) }

    // Wait until the provider's stream is actually open, so the abort
    // lands mid-stream rather than before the turn starts.
    for await event in events where event == .messageUpdate(.start) {
      break
    }

    await agent.abort()
    let final = await run.value

    #expect(final.stopReason == .aborted)
    #expect(final.content.isEmpty)
  }

  @Test("R6: registered tools reach LLMRequest.tools on every turn, sorted by name")
  func registeredToolsReachLLMRequestTools() async throws {
    // R6 says "every turn", so the script spans a tool-call turn AND the
    // follow-up turn it provokes, plus a second run() through the outer
    // loop. A single text-only turn would leave the "every turn" half
    // unasserted: sending the definitions only on a run's first turn would
    // pass.
    let log = RequestLog()
    let provider = RequestRecordingProvider(
      scripts: [
        ScriptedTurn.toolCall(id: "call_1", name: "z_tool", argumentsJSON: #"{"value":"hi"}"#),
        ScriptedTurn.text("all done"),
        ScriptedTurn.text("still done"),
      ],
      log: log
    )
    let zTool = AnyAgentTool(RecordingTool(name: "z_tool"))
    let aTool = AnyAgentTool(ThrowingTool(name: "a_tool"))
    let agent = makeAgent(provider: provider, tools: [zTool, aTool])

    _ = await agent.run(UserMessage(content: [.text("hello")]))
    _ = await agent.run(UserMessage(content: [.text("again")]))

    // ToolRegistry.allTools' order is nondeterministic — without sorting
    // by name, this assertion would flap between runs.
    let expected = [
      ToolDefinition(name: aTool.name, description: aTool.description, parameters: aTool.schema),
      ToolDefinition(name: zTool.name, description: zTool.description, parameters: zTool.schema),
    ]

    let requests = await log.requests
    #expect(requests.count == 3)
    for (index, request) in requests.enumerated() {
      #expect(request.tools == expected, "turn \(index) dropped the tool definitions")
    }
  }

  @Test(
    "F2.4: onUpdate progress reaches .toolExecutionUpdate, and abort() is observed via Task.isCancelled",
    .timeLimit(.minutes(1))
  )
  func toolProgressAndCancellationReachTheRealAgent() async throws {
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.toolCall(
        id: "call_1", name: "cancellation_observing_tool", argumentsJSON: #"{"value":"hi"}"#)
    ])
    let gate = FollowUpGate()
    let observation = CancellationObservation()
    let tool = CancellationObservingTool(gate: gate, observation: observation)
    let agent = makeAgent(provider: provider, tool: tool)
    let events = await agent.makeEventStream()

    let run = Task { await agent.run(UserMessage(content: [.text("please use the tool")])) }

    // The tool reports its onUpdate progress and yields
    // .toolExecutionUpdate BEFORE signalling the gate, so by the time this
    // returns the event has already landed in the (unbounded) event stream.
    await gate.waitUntilStarted()

    for await event in events
    where event
      == .toolExecutionUpdate(toolCallID: "call_1", update: ToolUpdate(message: "started"))
    {
      break
    }

    // Abort while the tool is still polling Task.isCancelled,
    // rather than releasing it — proving the tool observes cancellation
    // itself, not merely that the batch was cut short.
    await agent.abort()
    let final = await run.value

    #expect(final.stopReason == .aborted)
    let observedCancelled = await observation.observedCancelled
    #expect(observedCancelled)
  }
}

/// An error whose description spans many lines, so a tool throwing it
/// produces an oversized error `ToolResult`.
private struct VerboseToolError: Error, CustomStringConvertible {
  let description: String
}

/// A raw `Tool` that always throws a `VerboseToolError` carrying `message`.
private struct VerboseThrowingTool: Tool {
  typealias Arguments = ThrowingTool.Arguments

  let name = "verbose_throwing_tool"
  let description = "Throws an error with a very long description."
  let message: String

  func execute(
    toolCallID: String,
    arguments: Arguments,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    throw VerboseToolError(description: message)
  }
}

/// Runs one scripted tool call to `toolName` through the real `Agent`, with
/// `tool` registered as a raw `Tool` conformer (the registry erases it, not
/// the test), and returns the `ToolResultMessage` the model is sent back.
private func toolResultSentToModel(
  toolName: String, registering tool: some Tool
) async throws -> ToolResultMessage {
  let log = RequestLog()
  let provider = RequestRecordingProvider(
    scripts: [
      ScriptedTurn.toolCall(id: "call_1", name: toolName, argumentsJSON: #"{"value":"hi"}"#),
      ScriptedTurn.text("all done"),
    ],
    log: log
  )
  var registry = ToolRegistry()
  registry.register(tool)

  // Force-unwrap justified: "https://example.invalid" is a fixed, valid URL literal.
  // swift-format-ignore: NeverForceUnwrap
  let baseURL = URL(string: "https://example.invalid")!
  let agent = Agent(
    apiImplementation: provider,
    connection: ProviderConnection(
      baseURL: baseURL, auth: .none, transport: NeverCalledTransport()),
    model: "test-model",
    tools: registry
  )

  _ = await agent.run(UserMessage(content: [.text("go")]))

  let requests = await log.requests
  let secondRequest = try #require(requests.last)
  return try #require(toolResults(in: secondRequest).first)
}

/// `TRUNC-1` pinned at the loop level: whatever a tool returns, the model
/// is sent at most 2000 lines / 50 KB of it, without the tool cooperating.
@Suite("TRUNC-1 through the agent loop")
struct AgentTruncationTests {
  @Test("TRUNC-1: a raw Tool's output over 2000 lines reaches the model head-truncated")
  func rawToolOutputOverLineCapIsTruncated() async throws {
    let output = (1...2500).map { "line \($0)" }.joined(separator: "\n")
    let tool = RecordingTool(result: ToolResult(content: [.text(output)]))

    let result = try await toolResultSentToModel(toolName: "recording_tool", registering: tool)

    let sent = text(of: result.content)
    #expect(sent.components(separatedBy: "\n").count == 2000)
    #expect(sent.hasPrefix("line 1\n"))
    #expect(sent.hasSuffix("\nline 2000"))
    #expect(!result.isError)
  }

  @Test("TRUNC-1: a raw Tool's output over 50 KB in a few lines reaches the model byte-capped")
  func rawToolOutputOverByteCapIsTruncated() async throws {
    // Four 20 KB lines: far under the line cap, 80 KB over the byte cap.
    let output = (0..<4).map { _ in String(repeating: "x", count: 20_000) }
      .joined(separator: "\n")
    let tool = RecordingTool(result: ToolResult(content: [.text(output)]))

    let result = try await toolResultSentToModel(toolName: "recording_tool", registering: tool)

    let sent = text(of: result.content)
    #expect(sent.utf8.count <= 50_000)
    #expect(sent.components(separatedBy: "\n").count == 2)
  }

  @Test("TRUNC-1: an oversized error from a throwing tool reaches the model head-truncated")
  func oversizedThrownErrorIsTruncated() async throws {
    // Regression (TEST-7): AnyAgentTool truncated only the success path, so
    // an error result built from a thrown error's description — or from a
    // schema violation — reached the model at full size.
    let message = (1...3000).map { "detail \($0)" }.joined(separator: "\n")
    let tool = VerboseThrowingTool(message: message)

    let result = try await toolResultSentToModel(
      toolName: "verbose_throwing_tool", registering: tool)

    let sent = text(of: result.content)
    #expect(result.isError)
    #expect(sent.components(separatedBy: "\n").count == 2000)
    #expect(sent.hasPrefix("Tool \"verbose_throwing_tool\" failed: detail 1\n"))
  }
}
