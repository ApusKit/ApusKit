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
    pricing: Pricing(inputPerMillion: 1, outputPerMillion: 2),
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

@Suite("Agent gate suite")
struct AgentGateTests {
  @Test("scripted multi-turn tool round-trip ends in .endTurn")
  func multiTurnToolRoundTrip() async throws {
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.toolCall(
        id: "call_1", name: "recording_tool", argumentsJSON: #"{"value":"hi"}"#),
      ScriptedTurn.text("all done"),
    ])
    let tool = RecordingTool(result: ToolResult(content: [.text("tool output")]))
    let agent = makeAgent(provider: provider, tool: tool)

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))

    #expect(final.stopReason == .endTurn)
    #expect(final.content == [.text("all done")])

    let calls = await tool.recordedCalls
    #expect(calls == [RecordingTool.Arguments(value: "hi")])
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
    let provider = ScriptedProvider(scripts: [
      ScriptedTurn.toolCall(
        id: "call_1", name: "throwing_tool", argumentsJSON: #"{"value":"boom"}"#),
      ScriptedTurn.text("recovered"),
    ])
    let agent = makeAgent(provider: provider, tool: ThrowingTool())

    let final = await agent.run(UserMessage(content: [.text("please use the tool")]))

    // The loop survives the throwing tool and completes a second turn.
    #expect(final.stopReason == .endTurn)
    #expect(final.content == [.text("recovered")])
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
    let events = await agent.events

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
}
