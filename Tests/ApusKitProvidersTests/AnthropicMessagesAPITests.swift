// AnthropicMessagesAPITests
//
// Fixture-driven conformance suite for `AnthropicMessagesAPI` (TEST-3): the
// request it builds, and the unified `StreamEvent`s it decodes from
// recorded transcripts in `Tests/Fixtures/anthropic-messages/`, replayed
// whole and split at every byte offset through `FixtureTransport` so
// `PROV-1` holds no matter where an HTTP chunk boundary falls.

import ApusKitCore
import ApusKitProviders
import Foundation
import JSONSchema
import TestSupport
import Testing

// swift-format-ignore: NeverForceUnwrap
// Force-unwrap justified: fixed, valid URL literal.
private let exampleBaseURL = URL(string: "https://api.anthropic.example")!

/// Runs `AnthropicMessagesAPI` against a fixed response body, split into
/// `chunks`, and collects the `StreamEvent`s it produces.
private func collectEvents(
  chunks: [Data],
  request: LLMRequest = LLMRequest(model: "claude-3-5-sonnet-20241022", messages: [])
) async throws -> [StreamEvent] {
  let api = AnthropicMessagesAPI()
  let connection = ProviderConnection(
    baseURL: exampleBaseURL,
    auth: .apiKey("test-key"),
    transport: FixtureTransport(chunks: chunks)
  )
  var events: [StreamEvent] = []
  for try await event in api.stream(request: request, connection: connection) {
    events.append(event)
  }
  return events
}

/// Renders `events` as one deterministic line per event, to compare
/// against an inline expected literal (TEST-4).
private func dump(_ events: [StreamEvent]) -> String {
  events.map { event in
    switch event {
    case .start:
      return "start"
    case .textDelta(let index, let text):
      return "textDelta(\(index), \(String(reflecting: text)))"
    case .thinkingDelta(let index, let text):
      return "thinkingDelta(\(index), \(String(reflecting: text)))"
    case .toolCallStart(let index, let id, let name):
      return
        "toolCallStart(\(index), id: \(String(reflecting: id)), name: \(String(reflecting: name)))"
    case .toolCallDelta(let index, let delta):
      return "toolCallDelta(\(index), \(String(reflecting: delta)))"
    case .toolCallEnd(let index):
      return "toolCallEnd(\(index))"
    case .done(let usage, let stopReason):
      return "done(\(usage), \(stopReason))"
    case .error(let error):
      return "error(\(error.code), \(String(reflecting: error.message)))"
    @unknown default:
      return "unknown"
    }
  }.joined(separator: "\n")
}

/// Asserts the `PROV-1` shape: exactly one `.start` first, exactly one
/// terminal `.done`/`.error` last.
@Suite("AnthropicMessagesAPI")
struct AnthropicMessagesAPITests {

  // MARK: - Request shape

  @Test("builds the /v1/messages request with anthropic headers, auth, and a cache_control body")
  func requestShape() async throws {
    let log = RequestSpyLog()
    let api = AnthropicMessagesAPI()
    let connection = ProviderConnection(
      baseURL: exampleBaseURL,
      auth: .apiKey("secret-key"),
      transport: FixtureTransport(
        body: Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8), log: log)
    )
    let request = LLMRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [
        .user(UserMessage(content: [.text("What's the weather in Paris?")])),
        .assistant(
          AssistantMessage(
            content: [
              .toolCall(
                id: "toolu_01", name: "get_weather", argumentsJSON: "{\"location\":\"Paris\"}")
            ],
            stopReason: .toolUse,
            usage: Usage(inputTokens: 10, outputTokens: 5)
          )
        ),
        .toolResult(ToolResultMessage(toolCallID: "toolu_01", content: [.text("18C, cloudy")])),
      ],
      systemPrompt: "Be concise.",
      cacheBreakpoints: [0]
    )

    for try await _ in api.stream(request: request, connection: connection) {}

    let requests = await log.requests
    let httpRequest = try #require(requests.first)

    #expect(httpRequest.url == exampleBaseURL.appendingPathComponent("v1/messages"))
    #expect(httpRequest.method == "POST")
    #expect(httpRequest.headers["x-api-key"] == "secret-key")
    #expect(httpRequest.headers["anthropic-version"] == "2023-06-01")
    #expect(httpRequest.headers["Content-Type"] == "application/json")
    #expect(httpRequest.headers["Authorization"] == nil)

    let body = try #require(httpRequest.body)
    let json = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(json["model"] as? String == "claude-3-5-sonnet-20241022")
    #expect(json["system"] as? String == "Be concise.")
    #expect(json["stream"] as? Bool == true)
    #expect(json["max_tokens"] as? Int != nil)

    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 3)

    // Message 0 (user, a cache breakpoint) carries `cache_control` on its
    // one and only content block.
    #expect(messages[0]["role"] as? String == "user")
    let userBlocks = try #require(messages[0]["content"] as? [[String: Any]])
    #expect(userBlocks.count == 1)
    #expect(userBlocks[0]["type"] as? String == "text")
    #expect(userBlocks[0]["text"] as? String == "What's the weather in Paris?")
    let cacheControl = try #require(userBlocks[0]["cache_control"] as? [String: Any])
    #expect(cacheControl["type"] as? String == "ephemeral")

    // Message 1 (assistant tool call) is NOT a breakpoint: no cache_control.
    #expect(messages[1]["role"] as? String == "assistant")
    let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(assistantBlocks[0]["type"] as? String == "tool_use")
    #expect(assistantBlocks[0]["id"] as? String == "toolu_01")
    #expect(assistantBlocks[0]["name"] as? String == "get_weather")
    let input = try #require(assistantBlocks[0]["input"] as? [String: Any])
    #expect(input["location"] as? String == "Paris")
    #expect(assistantBlocks[0]["cache_control"] == nil)

    // Message 2 (tool result) renders as a user-role `tool_result` block.
    #expect(messages[2]["role"] as? String == "user")
    let toolResultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
    #expect(toolResultBlocks[0]["type"] as? String == "tool_result")
    #expect(toolResultBlocks[0]["tool_use_id"] as? String == "toolu_01")
    #expect(toolResultBlocks[0]["is_error"] == nil)
  }

  @Test("renders LLMRequest.tools as name/description/input_schema objects (R5)")
  func requestBodyRendersTools() async throws {
    let log = RequestSpyLog()
    let api = AnthropicMessagesAPI()
    let connection = ProviderConnection(
      baseURL: exampleBaseURL,
      auth: .apiKey("test-key"),
      transport: FixtureTransport(
        body: Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8), log: log)
    )
    let request = LLMRequest(
      model: "claude-3-5-sonnet-20241022",
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

    for try await _ in api.stream(request: request, connection: connection) {}

    let requests = await log.requests
    let httpRequest = try #require(requests.first)
    let body = try #require(httpRequest.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "get_weather")
    #expect(tools[0]["description"] as? String == "Look up the current weather for a city.")
    let inputSchema = try #require(tools[0]["input_schema"] as? [String: Any])
    #expect(inputSchema["type"] as? String == "object")
    let properties = try #require(inputSchema["properties"] as? [String: Any])
    let location = try #require(properties["location"] as? [String: Any])
    #expect(location["type"] as? String == "string")
    #expect(inputSchema["required"] as? [String] == ["location"])
  }

  @Test("an empty LLMRequest.tools omits the tools key entirely (R5)")
  func emptyToolsOmitsToolsKey() async throws {
    let plainLog = RequestSpyLog()
    let emptyLog = RequestSpyLog()
    let api = AnthropicMessagesAPI()
    let fixtureBody = Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8)

    let plainConnection = ProviderConnection(
      baseURL: exampleBaseURL,
      auth: .apiKey("test-key"),
      transport: FixtureTransport(body: fixtureBody, log: plainLog)
    )
    let emptyConnection = ProviderConnection(
      baseURL: exampleBaseURL,
      auth: .apiKey("test-key"),
      transport: FixtureTransport(body: fixtureBody, log: emptyLog)
    )

    let plainRequest = LLMRequest(model: "claude-3-5-sonnet-20241022", messages: [])
    let explicitlyEmptyRequest = LLMRequest(
      model: "claude-3-5-sonnet-20241022", messages: [], tools: [])

    for try await _ in api.stream(request: plainRequest, connection: plainConnection) {}
    for try await _ in api.stream(request: explicitlyEmptyRequest, connection: emptyConnection) {}

    let plainRequests = await plainLog.requests
    let emptyRequests = await emptyLog.requests
    let plainHTTPRequest = try #require(plainRequests.first)
    let emptyHTTPRequest = try #require(emptyRequests.first)

    // An empty `tools` array must be indistinguishable from a request that
    // never mentioned tools at all — a bare key-absence grep would miss a
    // mutant that renders `"tools": []` instead of omitting the key.
    #expect(emptyHTTPRequest.url == plainHTTPRequest.url)
    #expect(emptyHTTPRequest.method == plainHTTPRequest.method)
    #expect(emptyHTTPRequest.headers == plainHTTPRequest.headers)
    let plainJSON = try JSONSerialization.jsonObject(with: #require(plainHTTPRequest.body))
    let emptyJSON = try JSONSerialization.jsonObject(with: #require(emptyHTTPRequest.body))
    #expect(
      NSDictionary(dictionary: try #require(plainJSON as? [String: Any]))
        == NSDictionary(dictionary: try #require(emptyJSON as? [String: Any])))

    let body = try #require(emptyHTTPRequest.body)
    #expect((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["tools"] == nil)
  }

  @Test("auth .bearer renders an Authorization header instead of x-api-key")
  func bearerAuthRendersAuthorizationHeader() async throws {
    let log = RequestSpyLog()
    let api = AnthropicMessagesAPI()
    let connection = ProviderConnection(
      baseURL: exampleBaseURL,
      auth: .bearer("a-token"),
      transport: FixtureTransport(
        body: Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8), log: log)
    )
    let request = LLMRequest(model: "claude-3-5-sonnet-20241022", messages: [])

    for try await _ in api.stream(request: request, connection: connection) {}

    let requests = await log.requests
    let httpRequest = try #require(requests.first)
    #expect(httpRequest.headers["Authorization"] == "Bearer a-token")
    #expect(httpRequest.headers["x-api-key"] == nil)
  }

  // MARK: - Text-only turn

  @Test("a text-only turn decodes into unified StreamEvents, merging usage across events")
  func textResponseDecodes() async throws {
    let transcript = try Fixtures.transcript("text-response.sse", for: "anthropic-messages")
    let events = try await collectEvents(chunks: [transcript])

    #expect(
      dump(events) == """
        start
        textDelta(0, "Hello")
        textDelta(0, ", world!")
        done(Usage(inputTokens: 25, outputTokens: 12, cacheReadTokens: 10, cacheWriteTokens: 5), endTurn)
        """
    )
  }

  @Test("a text-only turn survives a chunk split at every byte offset")
  func textResponseSurvivesEverySplit() async throws {
    let transcript = try Fixtures.transcript("text-response.sse", for: "anthropic-messages")
    let reference = try await collectEvents(chunks: [transcript])
    assertPROV1Shape(reference)

    for offset in 0...transcript.count {
      let events = try await collectEvents(chunks: transcript.splitOnce(at: offset))
      #expect(events == reference, "split at byte offset \(offset) diverged from the whole replay")
    }
  }

  // MARK: - Tool-call turn

  @Test("a tool-call turn accumulates split argument fragments into valid JSON")
  func toolCallDecodes() async throws {
    let transcript = try Fixtures.transcript("tool-call.sse", for: "anthropic-messages")
    let events = try await collectEvents(chunks: [transcript])

    // The provider chopped its first fragment mid-key (`{"loc`); only the
    // `{` the accumulator has committed is forwarded, and the rest of the
    // key rides along with the next delta.
    #expect(
      dump(events) == """
        start
        textDelta(0, "Let me check that.")
        toolCallStart(1, id: "toolu_01", name: "get_weather")
        toolCallDelta(1, "{")
        toolCallDelta(1, "\\"location\\":\\"Paris")
        toolCallDelta(1, "\\"}")
        toolCallEnd(1)
        done(Usage(inputTokens: 40, outputTokens: 30, cacheReadTokens: 0, cacheWriteTokens: 0), toolUse)
        """
    )

    let argumentsJSON = events.compactMap { event -> String? in
      if case .toolCallDelta(_, let delta) = event { return delta }
      return nil
    }.joined()
    let decoded = try #require(
      try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any])
    #expect(decoded["location"] as? String == "Paris")
  }

  @Test("a tool-call turn survives a chunk split at every byte offset")
  func toolCallSurvivesEverySplit() async throws {
    let transcript = try Fixtures.transcript("tool-call.sse", for: "anthropic-messages")
    let reference = try await collectEvents(chunks: [transcript])
    assertPROV1Shape(reference)

    for offset in 0...transcript.count {
      let events = try await collectEvents(chunks: transcript.splitOnce(at: offset))
      #expect(events == reference, "split at byte offset \(offset) diverged from the whole replay")
    }
  }

  @Test("a stream cut mid-arguments still yields tool-call arguments that parse")
  func toolCallTruncatedMidArgumentsRepairsToValidJSON() async throws {
    let transcript = try Fixtures.transcript("tool-call-truncated.sse", for: "anthropic-messages")
    let events = try await collectEvents(chunks: [transcript])

    assertPROV1Shape(events)
    // The provider's last fragment was a lone `\` — the start of an
    // escape whose remainder never arrived. It is held back rather than
    // forwarded, and closing the block through the accumulator completes
    // the string and the object instead.
    #expect(
      dump(events) == """
        start
        toolCallStart(0, id: "toolu_02", name: "write_note")
        toolCallDelta(0, "{\\"note\\":\\"line one")
        toolCallDelta(0, "\\"}")
        toolCallEnd(0)
        error(decoding, "provider stream ended before a terminal event")
        """
    )

    let argumentsJSON = events.compactMap { event -> String? in
      if case .toolCallDelta(_, let delta) = event { return delta }
      return nil
    }.joined()
    let decoded = try #require(
      try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any])
    #expect(decoded["note"] as? String == "line one")
  }

  @Test("a stream cut mid-arguments survives a chunk split at every byte offset")
  func toolCallTruncatedSurvivesEverySplit() async throws {
    let transcript = try Fixtures.transcript("tool-call-truncated.sse", for: "anthropic-messages")
    let reference = try await collectEvents(chunks: [transcript])
    assertPROV1Shape(reference)

    for offset in 0...transcript.count {
      let events = try await collectEvents(chunks: transcript.splitOnce(at: offset))
      #expect(events == reference, "split at byte offset \(offset) diverged from the whole replay")
    }
  }

  // MARK: - Provider error

  @Test("a provider error event decodes into a terminal StreamEvent.error")
  func providerErrorDecodes() async throws {
    let transcript = try Fixtures.transcript("error.sse", for: "anthropic-messages")
    let events = try await collectEvents(chunks: [transcript])

    #expect(
      dump(events) == """
        start
        error(provider, "Overloaded")
        """
    )
  }

  @Test("a provider error survives a chunk split at every byte offset")
  func providerErrorSurvivesEverySplit() async throws {
    let transcript = try Fixtures.transcript("error.sse", for: "anthropic-messages")
    let reference = try await collectEvents(chunks: [transcript])
    assertPROV1Shape(reference)

    for offset in 0...transcript.count {
      let events = try await collectEvents(chunks: transcript.splitOnce(at: offset))
      #expect(events == reference, "split at byte offset \(offset) diverged from the whole replay")
    }
  }

  // MARK: - Malformed stream

  @Test("a transport failure still yields .start first, then exactly one terminal .error")
  func transportFailureStillStartsTheStream() async throws {
    let api = AnthropicMessagesAPI()
    let connection = ProviderConnection(
      baseURL: exampleBaseURL,
      auth: .apiKey("test-key"),
      transport: FixtureTransport(
        failing: StreamError(code: .transport, message: "HTTP 429"))
    )
    var events: [StreamEvent] = []
    for try await event in api.stream(
      request: LLMRequest(model: "claude-3-5-sonnet-20241022", messages: []),
      connection: connection
    ) {
      events.append(event)
    }

    assertPROV1Shape(events)
    #expect(
      dump(events) == """
        start
        error(transport, "HTTP 429")
        """
    )
  }

  @Test("an error event with no preceding message_start still yields .start first")
  func providerErrorWithoutMessageStartStillStartsTheStream() async throws {
    let events = try await collectEvents(
      chunks: [
        Data(
          """
          event: error
          data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


          """.utf8)
      ])

    assertPROV1Shape(events)
    #expect(
      dump(events) == """
        start
        error(provider, "Overloaded")
        """
    )
  }

  @Test("a byte stream that ends without a terminal event still yields exactly one terminal .error")
  func trunactedStreamYieldsTerminalError() async throws {
    let events = try await collectEvents(
      chunks: [Data("event: message_start\ndata: {\"type\":\"message_start\"}\n\n".utf8)])

    assertPROV1Shape(events)
    guard case .error(let error) = events.last else {
      Issue.record("expected a terminal .error, got \(String(describing: events.last))")
      return
    }
    #expect(error.code == .decoding)
  }
}
