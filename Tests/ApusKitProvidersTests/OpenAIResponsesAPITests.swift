// OpenAIResponsesAPITests
//
// Request-shape coverage plus a TEST-3 fixture-driven conformance suite
// for `OpenAIResponsesAPI`, offline against recorded transcripts in
// `Tests/Fixtures/openai-responses/` (TEST-2). Every transcript is
// replayed whole and split at every byte offset, proving the adapter
// survives a chunk boundary falling anywhere (PROV-1).

import ApusKitCore
import ApusKitProviders
import Foundation
import InlineSnapshotTesting
import TestSupport
import Testing

/// Builds a connection good enough to exercise `OpenAIResponsesAPI`
/// against `transport`.
private func connection(transport: some StreamingHTTPTransport) -> ProviderConnection {
  // Force-unwrap justified: "https://api.openai.com/v1" is a fixed, valid URL literal.
  // swift-format-ignore: NeverForceUnwrap
  let baseURL = URL(string: "https://api.openai.com/v1")!
  return ProviderConnection(baseURL: baseURL, auth: .bearer("sk-test"), transport: transport)
}

/// Collects every event a stream yields, in order.
private func collect(_ stream: AsyncThrowingStream<StreamEvent, any Error>) async throws
  -> [StreamEvent]
{
  var events: [StreamEvent] = []
  for try await event in stream {
    events.append(event)
  }
  return events
}

/// Streams `request` against a `FixtureTransport` replaying `data` as one
/// chunk.
private func replay(_ data: Data, request: LLMRequest = LLMRequest(model: "gpt-5", messages: []))
  async throws -> [StreamEvent]
{
  let transport = FixtureTransport(body: data)
  return try await collect(
    OpenAIResponsesAPI().stream(request: request, connection: connection(transport: transport)))
}

/// Streams `request` against a `FixtureTransport` replaying `chunks` in
/// order.
private func replay(
  chunks: [Data], request: LLMRequest = LLMRequest(model: "gpt-5", messages: [])
) async throws -> [StreamEvent] {
  let transport = FixtureTransport(chunks: chunks)
  return try await collect(
    OpenAIResponsesAPI().stream(request: request, connection: connection(transport: transport)))
}

/// Replays `data` split at every possible byte offset (and whole, at
/// offset 0) and asserts each split reproduces `expected` exactly — the
/// substantive PROV-1 proof that no chunk boundary can desynchronize the
/// adapter.
private func assertStableAcrossEveryChunkBoundary(
  _ data: Data, expected: [StreamEvent]
) async throws {
  for offset in 0...data.count {
    let events = try await replay(chunks: data.splitOnce(at: offset))
    #expect(events == expected, "mismatch when split at byte offset \(offset)")
  }
}

/// Renders an event stream as a deterministic textual dump for
/// `InlineSnapshotTesting` (TEST-4). Writes out every field explicitly
/// rather than relying on `Usage`/`StreamError`'s default mirror-based
/// description, which is not guaranteed stable across Swift versions.
private func dump(_ events: [StreamEvent]) -> String {
  events.map(describe).joined(separator: "\n")
}

private func describe(_ event: StreamEvent) -> String {
  switch event {
  case .start:
    return "start"
  case .textDelta(let contentIndex, let text):
    return "textDelta(\(contentIndex), \(text.debugDescription))"
  case .thinkingDelta(let contentIndex, let text):
    return "thinkingDelta(\(contentIndex), \(text.debugDescription))"
  case .toolCallStart(let contentIndex, let id, let name):
    return "toolCallStart(\(contentIndex), id: \(id), name: \(name))"
  case .toolCallDelta(let contentIndex, let argumentsJSONDelta):
    return "toolCallDelta(\(contentIndex), \(argumentsJSONDelta.debugDescription))"
  case .toolCallEnd(let contentIndex):
    return "toolCallEnd(\(contentIndex))"
  case .done(let usage, let stopReason):
    return
      "done(usage: input=\(usage.inputTokens) output=\(usage.outputTokens) "
      + "cacheRead=\(usage.cacheReadTokens) cacheWrite=\(usage.cacheWriteTokens), "
      + "stopReason: \(stopReason))"
  case .error(let error):
    return "error(code: \(error.code), message: \(error.message.debugDescription))"
  @unknown default:
    return "unknown"
  }
}

@Suite("OpenAIResponsesAPI request shape")
struct OpenAIResponsesAPIRequestShapeTests {
  @Test(
    "builds the POST <baseURL>/responses request, preserving the path prefix, with headers and body"
  )
  func buildsRequestShape() async throws {
    let log = RequestSpyLog()
    let transcript = try Fixtures.transcript("text-and-tool-call.sse", for: "openai-responses")
    let transport = FixtureTransport(body: transcript, log: log)
    // Force-unwrap justified: fixed, valid URL literal with a path prefix.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://my-proxy.example.com/v1")!
    let connection = ProviderConnection(
      baseURL: baseURL, auth: .bearer("sk-test"), transport: transport)
    let request = LLMRequest(
      model: "gpt-5",
      messages: [
        .user(UserMessage(content: [.text("What's the weather in Boston?")])),
        .assistant(
          AssistantMessage(
            content: [
              .text("Let me check."),
              .toolCall(
                id: "call_abc123", name: "get_weather",
                argumentsJSON: "{\"location\":\"Boston, MA\"}"),
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 10, outputTokens: 5)
          )),
        .toolResult(
          ToolResultMessage(toolCallID: "call_abc123", content: [.text("72F and sunny")])),
      ],
      systemPrompt: "Be terse."
    )

    _ = try await collect(OpenAIResponsesAPI().stream(request: request, connection: connection))

    let requests = await log.requests
    #expect(requests.count == 1)
    let httpRequest = try #require(requests.first)

    #expect(httpRequest.url == URL(string: "https://my-proxy.example.com/v1/responses"))
    #expect(httpRequest.method == "POST")
    #expect(httpRequest.headers["Authorization"] == "Bearer sk-test")
    #expect(httpRequest.headers["Content-Type"] == "application/json")

    let body = try #require(httpRequest.body)
    let json = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "gpt-5")
    #expect(json["stream"] as? Bool == true)
    #expect(json["instructions"] as? String == "Be terse.")

    let input = try #require(json["input"] as? [[String: Any]])
    #expect(input.count == 4)

    #expect(input[0]["role"] as? String == "user")
    let userContent = try #require(input[0]["content"] as? [[String: Any]])
    #expect(userContent.first?["type"] as? String == "input_text")
    #expect(userContent.first?["text"] as? String == "What's the weather in Boston?")

    #expect(input[1]["role"] as? String == "assistant")
    let assistantContent = try #require(input[1]["content"] as? [[String: Any]])
    #expect(assistantContent.first?["type"] as? String == "output_text")
    #expect(assistantContent.first?["text"] as? String == "Let me check.")

    #expect(input[2]["type"] as? String == "function_call")
    #expect(input[2]["call_id"] as? String == "call_abc123")
    #expect(input[2]["name"] as? String == "get_weather")
    #expect(input[2]["arguments"] as? String == "{\"location\":\"Boston, MA\"}")

    #expect(input[3]["type"] as? String == "function_call_output")
    #expect(input[3]["call_id"] as? String == "call_abc123")
    #expect(input[3]["output"] as? String == "72F and sunny")
  }

  @Test("ignores auth-less connections without adding an Authorization header")
  func noAuthOmitsAuthorizationHeader() async throws {
    let log = RequestSpyLog()
    let transcript = try Fixtures.transcript("response-failed.sse", for: "openai-responses")
    let transport = FixtureTransport(body: transcript, log: log)
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://api.openai.com/v1")!
    let connection = ProviderConnection(baseURL: baseURL, auth: .none, transport: transport)
    let request = LLMRequest(model: "gpt-5", messages: [])

    _ = try await collect(OpenAIResponsesAPI().stream(request: request, connection: connection))

    let httpRequest = try #require(await log.requests.first)
    #expect(httpRequest.headers["Authorization"] == nil)
  }
}

@Suite("OpenAIResponsesAPI conformance")
struct OpenAIResponsesAPIConformanceTests {
  @Test(
    "parses a text-and-tool-call transcript into unified StreamEvents, stable at every chunk boundary"
  )
  func textAndToolCall() async throws {
    let data = try Fixtures.transcript("text-and-tool-call.sse", for: "openai-responses")
    let events = try await replay(data)

    #expect(events.first == .start)
    guard case .done = events.last else {
      Issue.record("expected a terminal .done, got \(String(describing: events.last))")
      return
    }

    assertInlineSnapshot(of: dump(events), as: .lines) {
      """
      start
      textDelta(0, "The weather in ")
      textDelta(0, "Boston is")
      toolCallStart(1, id: call_abc123, name: get_weather)
      toolCallDelta(1, "{\\"location\\":")
      toolCallDelta(1, "\\"Boston, MA\\"}")
      toolCallEnd(1)
      done(usage: input=24 output=18 cacheRead=100 cacheWrite=0, stopReason: toolUse)
      """
    }

    // R6: usage on the terminal event carries cached tokens from the
    // provider's own usage fields, and cost is derived from ModelInfo
    // pricing via Core's Usage.cost(at:) — never a hardcoded rate.
    guard case .done(let usage, _) = events.last else {
      Issue.record("expected a terminal .done")
      return
    }
    let pricing = Pricing(
      inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: 0.5, cacheWritePerMillion: 0)
    let expectedCost =
      24.0 / 1_000_000 * 2 + 18.0 / 1_000_000 * 8 + 100.0 / 1_000_000 * 0.5
    #expect(usage.cost(at: pricing) == expectedCost)

    // R8: decoded tool-call arguments. The two `toolCallDelta` fragments
    // for content index 1 concatenate into complete, decodable JSON.
    let argumentsJSON = events.compactMap { event -> String? in
      guard case .toolCallDelta(1, let delta) = event else { return nil }
      return delta
    }.joined()
    let decodedArguments = try #require(
      try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: String])
    #expect(decodedArguments["location"] == "Boston, MA")

    try await assertStableAcrossEveryChunkBoundary(data, expected: events)
  }

  @Test("maps response.failed to a terminal .error event, stable at every chunk boundary")
  func responseFailed() async throws {
    let data = try Fixtures.transcript("response-failed.sse", for: "openai-responses")
    let events = try await replay(data)

    #expect(events.first == .start)
    guard case .error = events.last else {
      Issue.record("expected a terminal .error, got \(String(describing: events.last))")
      return
    }

    assertInlineSnapshot(of: dump(events), as: .lines) {
      """
      start
      error(code: provider, message: "the model is overloaded")
      """
    }

    try await assertStableAcrossEveryChunkBoundary(data, expected: events)
  }
}
