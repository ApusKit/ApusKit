// OpenAICompletionsAPITests
//
// Coverage for OpenAICompletionsAPI (TRD §3.3): request shape, and a
// fixture-driven conformance suite (TEST-3) that replays recorded
// transcripts whole and split at every byte offset (TEST-2), proving
// PROV-1 holds regardless of where the HTTP body happens to be chunked.

import ApusKitCore
import ApusKitProviders
import Foundation
import JSONSchema
import TestSupport
import Testing

/// A `StreamingHTTPTransport` that fails the test if it is ever called —
/// the request-shape tests only exercise request building, never a real
/// stream.
private struct NeverCalledTransport: StreamingHTTPTransport {
  func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, any Error> {
    Issue.record("StreamingHTTPTransport must not be invoked while building a request")
    return AsyncThrowingStream { $0.finish() }
  }
}

/// Replays `chunks` through `OpenAICompletionsAPI` and collects every
/// `StreamEvent` it yields.
private func replay(chunks: [Data]) async throws -> [StreamEvent] {
  let api = OpenAICompletionsAPI()
  // Force-unwrap justified: "https://api.openai.com/v1" is a fixed, valid URL literal.
  // swift-format-ignore: NeverForceUnwrap
  let baseURL = URL(string: "https://api.openai.com/v1")!
  let connection = ProviderConnection(
    baseURL: baseURL, auth: .bearer("test-key"), transport: FixtureTransport(chunks: chunks))
  let request = LLMRequest(
    model: "gpt-4o-mini", messages: [.user(UserMessage(content: [.text("hi")]))])

  var events: [StreamEvent] = []
  for try await event in api.stream(request: request, connection: connection) {
    events.append(event)
  }
  return events
}

/// Replays `transcript` at every byte offset and asserts every split
/// reproduces `expected` exactly — `PROV-1` must hold no matter where the
/// HTTP body happens to be chunked.
private func assertSplitInvariant(_ transcript: Data, matches expected: [StreamEvent]) async throws
{
  for offset in 0..<transcript.count {
    let events = try await replay(chunks: transcript.splitOnce(at: offset))
    #expect(events == expected, "split at byte offset \(offset) diverged from the whole replay")
  }
}

/// Renders a `[StreamEvent]` sequence as a stable textual dump, to
/// compare against an inline expected literal (`TEST-4`).
private func dump(_ events: [StreamEvent]) -> String {
  events.map(describe).joined(separator: "\n") + "\n"
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
    return
      "toolCallStart(\(contentIndex), id: \(id.debugDescription), name: \(name.debugDescription))"
  case .toolCallDelta(let contentIndex, let argumentsJSONDelta):
    return "toolCallDelta(\(contentIndex), \(argumentsJSONDelta.debugDescription))"
  case .toolCallEnd(let contentIndex):
    return "toolCallEnd(\(contentIndex))"
  case .done(let usage, let stopReason):
    return
      "done(usage: in=\(usage.inputTokens) out=\(usage.outputTokens) "
      + "cacheRead=\(usage.cacheReadTokens) cacheWrite=\(usage.cacheWriteTokens), "
      + "stopReason: \(stopReason))"
  case .error(let error):
    return "error(\(error.code), \(error.message.debugDescription))"
  @unknown default:
    return "unknown"
  }
}

@Suite("OpenAICompletionsAPI request shape")
struct OpenAICompletionsAPIRequestShapeTests {
  @Test(
    "builds POST <baseURL>/chat/completions with stream + include_usage and the full message shape"
  )
  func buildsRequestShape() throws {
    // Force-unwrap justified: fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://api.openai.com/v1")!
    let connection = ProviderConnection(
      baseURL: baseURL, auth: .bearer("sk-test"), transport: NeverCalledTransport())
    let request = LLMRequest(
      model: "gpt-4o-mini",
      messages: [
        .user(UserMessage(content: [.text("What's the weather?")])),
        .assistant(
          AssistantMessage(
            content: [
              .text("Let me check."),
              .toolCall(id: "call_1", name: "get_weather", argumentsJSON: "{\"location\":\"SF\"}"),
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 10, outputTokens: 5)
          )),
        .toolResult(ToolResultMessage(toolCallID: "call_1", content: [.text("72F and sunny")])),
      ],
      systemPrompt: "Be terse."
    )

    let httpRequest = try OpenAICompletionsAPI.makeHTTPRequest(for: request, connection: connection)

    #expect(httpRequest.url.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(httpRequest.method == "POST")
    #expect(httpRequest.headers["Authorization"] == "Bearer sk-test")
    #expect(httpRequest.headers["Content-Type"] == "application/json")

    let body = try #require(httpRequest.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(json["model"] as? String == "gpt-4o-mini")
    #expect(json["stream"] as? Bool == true)
    let streamOptions = try #require(json["stream_options"] as? [String: Any])
    #expect(streamOptions["include_usage"] as? Bool == true)

    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 4)

    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[0]["content"] as? String == "Be terse.")

    #expect(messages[1]["role"] as? String == "user")
    #expect(messages[1]["content"] as? String == "What's the weather?")

    #expect(messages[2]["role"] as? String == "assistant")
    #expect(messages[2]["content"] as? String == "Let me check.")
    let toolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
    #expect(toolCalls.count == 1)
    #expect(toolCalls[0]["id"] as? String == "call_1")
    #expect(toolCalls[0]["type"] as? String == "function")
    let function = try #require(toolCalls[0]["function"] as? [String: Any])
    #expect(function["name"] as? String == "get_weather")
    #expect(function["arguments"] as? String == "{\"location\":\"SF\"}")

    #expect(messages[3]["role"] as? String == "tool")
    #expect(messages[3]["content"] as? String == "72F and sunny")
    #expect(messages[3]["tool_call_id"] as? String == "call_1")
  }

  @Test("renders LLMRequest.tools as type:function objects with a nested function (R5)")
  func requestBodyRendersTools() throws {
    // Force-unwrap justified: fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://api.openai.com/v1")!
    let connection = ProviderConnection(
      baseURL: baseURL, auth: .bearer("sk-test"), transport: NeverCalledTransport())
    let request = LLMRequest(
      model: "gpt-4o-mini",
      messages: [],
      tools: [
        ToolDefinition(
          name: "get_weather",
          description: "Look up the current weather for a city.",
          parameters: [
            "type": "object",
            "properties": ["location": ["type": "string"]],
            "required": ["location"],
          ]
        )
      ]
    )

    let httpRequest = try OpenAICompletionsAPI.makeHTTPRequest(for: request, connection: connection)
    let body = try #require(httpRequest.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["type"] as? String == "function")
    // Chat Completions nests the tool under a `function` object — a flat
    // name/description/parameters (the Responses shape) is a different
    // wire contract and must not appear here.
    #expect(tools[0]["name"] == nil)
    let function = try #require(tools[0]["function"] as? [String: Any])
    #expect(function["name"] as? String == "get_weather")
    #expect(function["description"] as? String == "Look up the current weather for a city.")
    let parameters = try #require(function["parameters"] as? [String: Any])
    #expect(parameters["type"] as? String == "object")
    let properties = try #require(parameters["properties"] as? [String: Any])
    let location = try #require(properties["location"] as? [String: Any])
    #expect(location["type"] as? String == "string")
    #expect(parameters["required"] as? [String] == ["location"])
  }

  @Test("an empty LLMRequest.tools omits the tools key entirely (R5)")
  func emptyToolsOmitsToolsKey() throws {
    // Force-unwrap justified: fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://api.openai.com/v1")!
    let connection = ProviderConnection(
      baseURL: baseURL, auth: .bearer("sk-test"), transport: NeverCalledTransport())
    let messages: [LLMRequestMessage] = [.user(UserMessage(content: [.text("hi")]))]

    let plain = try OpenAICompletionsAPI.makeHTTPRequest(
      for: LLMRequest(model: "gpt-4o-mini", messages: messages), connection: connection)
    let explicitlyEmpty = try OpenAICompletionsAPI.makeHTTPRequest(
      for: LLMRequest(model: "gpt-4o-mini", messages: messages, tools: []), connection: connection)

    // An empty `tools` array must be indistinguishable from a request that
    // never mentioned tools at all — a bare key-absence check alone would
    // miss a mutant that renders `"tools": []` instead of omitting it.
    #expect(explicitlyEmpty.url == plain.url)
    #expect(explicitlyEmpty.method == plain.method)
    #expect(explicitlyEmpty.headers == plain.headers)
    let plainJSON = try JSONSerialization.jsonObject(with: #require(plain.body))
    let emptyJSON = try JSONSerialization.jsonObject(with: #require(explicitlyEmpty.body))
    #expect(
      NSDictionary(dictionary: try #require(plainJSON as? [String: Any]))
        == NSDictionary(dictionary: try #require(emptyJSON as? [String: Any])))
    #expect(try #require(emptyJSON as? [String: Any])["tools"] == nil)
  }

  @Test("ignores LLMRequest.cacheBreakpoints without error (PROV-2)")
  func ignoresCacheBreakpoints() throws {
    // Force-unwrap justified: fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://api.openai.com/v1")!
    let connection = ProviderConnection(
      baseURL: baseURL, auth: .bearer("sk-test"), transport: NeverCalledTransport())
    let messages: [LLMRequestMessage] = [
      .user(UserMessage(content: [.text("hi")])),
      .assistant(
        AssistantMessage(
          content: [.text("hello")], stopReason: .endTurn,
          usage: Usage(inputTokens: 1, outputTokens: 1))),
      .user(UserMessage(content: [.text("again")])),
    ]

    let plain = try OpenAICompletionsAPI.makeHTTPRequest(
      for: LLMRequest(model: "gpt-4o-mini", messages: messages), connection: connection)
    let hinted = try OpenAICompletionsAPI.makeHTTPRequest(
      for: LLMRequest(model: "gpt-4o-mini", messages: messages, cacheBreakpoints: [0, 2]),
      connection: connection)

    // Cache hints have no Chat Completions wire equivalent, so the hinted
    // request must be indistinguishable from the plain one rather than
    // merely "not an error" — that is what keeps context provider-neutral
    // (PROV-2). Bodies are compared as decoded JSON, not bytes: the encoder
    // does not promise a stable key order.
    #expect(hinted.url == plain.url)
    #expect(hinted.method == plain.method)
    #expect(hinted.headers == plain.headers)
    let hintedJSON = try JSONSerialization.jsonObject(with: #require(hinted.body))
    let plainJSON = try JSONSerialization.jsonObject(with: #require(plain.body))
    #expect(
      NSDictionary(dictionary: try #require(hintedJSON as? [String: Any]))
        == NSDictionary(dictionary: try #require(plainJSON as? [String: Any])))

    let body = try #require(hinted.body)
    #expect(!String(decoding: body, as: UTF8.self).contains("cache_control"))
  }

  @Test("preserves an arbitrary OpenAI-compatible baseURL with no version path")
  func preservesArbitraryBaseURL() throws {
    // Force-unwrap justified: fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "http://localhost:11434")!
    let connection = ProviderConnection(
      baseURL: baseURL, auth: .none, transport: NeverCalledTransport())
    let request = LLMRequest(
      model: "llama3", messages: [.user(UserMessage(content: [.text("hi")]))])

    let httpRequest = try OpenAICompletionsAPI.makeHTTPRequest(for: request, connection: connection)

    #expect(httpRequest.url.absoluteString == "http://localhost:11434/chat/completions")
    #expect(httpRequest.headers["Authorization"] == nil)
  }

  @Test("renders .apiKey auth as a bearer Authorization header, same as .bearer")
  func rendersAPIKeyAsBearer() throws {
    // Force-unwrap justified: fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://api.groq.com/openai/v1")!
    let connection = ProviderConnection(
      baseURL: baseURL, auth: .apiKey("gsk-test"), transport: NeverCalledTransport())
    let request = LLMRequest(
      model: "llama3-70b", messages: [.user(UserMessage(content: [.text("hi")]))])

    let httpRequest = try OpenAICompletionsAPI.makeHTTPRequest(for: request, connection: connection)

    #expect(httpRequest.url.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    #expect(httpRequest.headers["Authorization"] == "Bearer gsk-test")
  }

  @Test("reports the .openAICompletions id")
  func reportsID() {
    #expect(OpenAICompletionsAPI().id == .openAICompletions)
  }
}

@Suite("OpenAICompletionsAPI fixture conformance")
struct OpenAICompletionsAPIConformanceTests {
  @Test("a text-only response decodes to textDelta events and a terminal done")
  func textOnlyResponse() async throws {
    let transcript = try Fixtures.transcript("text-only.sse", for: "openai-completions")
    let events = try await replay(chunks: [transcript])
    assertPROV1Shape(events)

    #expect(
      dump(events) == """
        start
        textDelta(0, "Hello")
        textDelta(0, ", world!")
        done(usage: in=12 out=4 cacheRead=0 cacheWrite=0, stopReason: endTurn)

        """
    )

    try await assertSplitInvariant(transcript, matches: events)
  }

  @Test("a single tool call's fragmented arguments accumulate under one contentIndex")
  func singleToolCallResponse() async throws {
    let transcript = try Fixtures.transcript("tool-call.sse", for: "openai-completions")
    let events = try await replay(chunks: [transcript])
    assertPROV1Shape(events)

    #expect(
      dump(events) == """
        start
        toolCallStart(0, id: "call_abc123", name: "get_weather")
        toolCallDelta(0, "{\\"loc")
        toolCallDelta(0, "ation\\":\\"S")
        toolCallDelta(0, "F\\"}")
        toolCallEnd(0)
        done(usage: in=18 out=18 cacheRead=32 cacheWrite=0, stopReason: toolUse)

        """
    )

    // The fragments, concatenated in order, must reconstruct valid JSON —
    // the adapter forwards them verbatim (PROV-1's accumulator lives in
    // the agent loop, not here), but a mis-split delta would still show up
    // here as broken JSON.
    let argumentsFragments = events.compactMap { event -> String? in
      guard case .toolCallDelta(_, let delta) = event else { return nil }
      return delta
    }
    let arguments = argumentsFragments.joined()
    #expect(arguments == "{\"location\":\"SF\"}")
    #expect(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) is [String: Any])

    try await assertSplitInvariant(transcript, matches: events)
  }

  @Test("two parallel tool calls are routed by their wire index to distinct contentIndexes")
  func multipleToolCallsResponse() async throws {
    let transcript = try Fixtures.transcript("multi-tool-calls.sse", for: "openai-completions")
    let events = try await replay(chunks: [transcript])
    assertPROV1Shape(events)

    #expect(
      dump(events) == """
        start
        toolCallStart(0, id: "call_1", name: "search")
        toolCallStart(1, id: "call_2", name: "lookup")
        toolCallDelta(0, "{\\"q\\":\\"a\\"}")
        toolCallDelta(1, "{\\"id\\":1}")
        toolCallEnd(0)
        toolCallEnd(1)
        done(usage: in=40 out=10 cacheRead=0 cacheWrite=0, stopReason: toolUse)

        """
    )

    try await assertSplitInvariant(transcript, matches: events)
  }

  @Test("a malformed chunk terminates the stream with a single decoding error, per PROV-1")
  func malformedChunkTerminatesWithError() async throws {
    let transcript = try Fixtures.transcript("malformed.sse", for: "openai-completions")
    let events = try await replay(chunks: [transcript])
    assertPROV1Shape(events)

    #expect(events.count == 2)
    #expect(events.first == .start)
    guard case .error(let error) = events.last else {
      Issue.record("expected a terminal .error, got \(String(describing: events.last))")
      return
    }
    #expect(error.code == .decoding)

    try await assertSplitInvariant(transcript, matches: events)
  }
}
