public import ApusKitCore
internal import ApusKitWireFormat
internal import Foundation
internal import JSONSchema

/// Speaks the OpenAI Chat Completions streaming wire protocol.
///
/// Builds a `POST <baseURL>/chat/completions` request with `"stream": true`
/// and `"stream_options": {"include_usage": true}`, and parses the
/// resulting Server-Sent Events into unified `StreamEvent`s via
/// `SSEParser`. Because it only assumes the Chat Completions wire shape —
/// never a specific vendor — this implementation works unchanged against
/// any OpenAI-compatible `baseURL` (OpenAI itself, Groq, OpenRouter,
/// Ollama, a local proxy, ...).
///
/// `LLMRequest`'s cache hint is silently ignored: Chat Completions has no
/// prompt-caching passthrough, unlike the Anthropic Messages API. Ignoring
/// rather than rejecting it keeps context provider-neutral (`PROV-2`) — a
/// consumer can switch a session from Anthropic to an OpenAI-compatible
/// provider mid-conversation with no adapter-specific branching.
public struct OpenAICompletionsAPI: APIImplementation {
  /// Always `.openAICompletions`.
  public let id: APIImplementationID = .openAICompletions

  /// Creates an OpenAI Chat Completions API implementation.
  public init() {}

  /// Streams a single conversational turn as unified `StreamEvent`s.
  ///
  /// Per `PROV-1`, exactly one `.start` is yielded first and exactly one
  /// terminal `.done` or `.error` is yielded last, however the underlying
  /// HTTP body happens to be chunked — `SSEParser` reassembles lines
  /// across arbitrary chunk boundaries, and every `tool_calls` delta is
  /// routed by its wire `index` to a stable `contentIndex`.
  public func stream(request: LLMRequest, connection: ProviderConnection) -> AsyncThrowingStream<
    StreamEvent, any Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield(.start)

        let httpRequest: HTTPStreamRequest
        do {
          httpRequest = try Self.makeHTTPRequest(for: request, connection: connection)
        } catch {
          continuation.yield(
            .error(
              StreamError(code: .decoding, message: "failed to encode request body: \(error)")))
          continuation.finish()
          return
        }

        // `state` lives entirely inside this Task, never shared and never
        // locked (CC-4).
        var parser = SSEParser()
        var state = ChunkState()
        do {
          for try await chunk in connection.transport.stream(httpRequest) {
            let events: [SSEEvent]
            do {
              events = try parser.feed(chunk.data)
            } catch {
              continuation.yield(
                .error(
                  StreamError(code: .decoding, message: "malformed SSE stream: \(error)")))
              continuation.finish()
              return
            }
            for event in events where state.apply(event, continuation: continuation) {
              // The `[DONE]` sentinel or a decode failure already produced
              // the terminal event.
              continuation.finish()
              return
            }
          }
        } catch let streamError as StreamError {
          continuation.yield(.error(streamError))
          continuation.finish()
          return
        } catch {
          continuation.yield(.error(StreamError(code: .transport, message: "\(error)")))
          continuation.finish()
          return
        }

        // The transport closed without a `[DONE]` sentinel line (some
        // OpenAI-compatible endpoints omit it): still finish with exactly
        // one terminal event, per PROV-1.
        state.finish(continuation: continuation)
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

// MARK: - Stream decode state

/// Accumulates per-request decode state for a single `stream(request:connection:)`
/// call: which wire `tool_calls` index maps to which unified `contentIndex`,
/// and the usage/stop reason seen so far. A plain value type living inside
/// the call's own `Task` (`CC-4`) — never shared, never locked.
private struct ChunkState {
  private var nextContentIndex = 0
  private var textContentIndex: Int?
  private var toolContentIndexes: [Int: Int] = [:]
  private var openToolContentIndexes: [Int] = []
  private var stopReason: StopReason?
  private var usage = Usage(inputTokens: 0, outputTokens: 0)

  /// Applies one decoded SSE event, yielding the `StreamEvent`s it implies.
  ///
  /// - Returns: `true` once the terminal event has already been yielded —
  ///   either because the `[DONE]` sentinel was seen or because the chunk
  ///   could not be decoded — meaning the caller must stop iterating.
  mutating func apply(
    _ event: SSEEvent,
    continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) -> Bool {
    let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !data.isEmpty else { return false }
    if data == "[DONE]" {
      finish(continuation: continuation)
      return true
    }

    guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(data.utf8)) else {
      continuation.yield(
        .error(
          StreamError(code: .decoding, message: "could not decode chat completions chunk")))
      return true
    }

    for choice in chunk.choices {
      if let content = choice.delta.content, !content.isEmpty {
        continuation.yield(.textDelta(contentIndex: textIndex(), text: content))
      }
      for toolCall in choice.delta.toolCalls ?? [] {
        let (index, isNew) = toolIndex(for: toolCall.index)
        if isNew {
          continuation.yield(
            .toolCallStart(
              contentIndex: index, id: toolCall.id ?? "", name: toolCall.function?.name ?? ""))
        }
        if let argumentsDelta = toolCall.function?.arguments, !argumentsDelta.isEmpty {
          continuation.yield(
            .toolCallDelta(contentIndex: index, argumentsJSONDelta: argumentsDelta))
        }
      }
      if let finishReason = choice.finishReason {
        stopReason = Self.stopReason(for: finishReason)
      }
    }

    if let wireUsage = chunk.usage {
      usage = Self.usage(from: wireUsage)
    }

    return false
  }

  /// Emits the outstanding `.toolCallEnd`s, in the order their tool calls
  /// started, followed by the terminal `.done`. Called at most once per
  /// request.
  func finish(continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation) {
    for index in openToolContentIndexes {
      continuation.yield(.toolCallEnd(contentIndex: index))
    }
    continuation.yield(.done(usage: usage, stopReason: stopReason ?? .endTurn))
  }

  private mutating func textIndex() -> Int {
    if let existing = textContentIndex { return existing }
    let index = nextContentIndex
    nextContentIndex += 1
    textContentIndex = index
    return index
  }

  private mutating func toolIndex(for wireIndex: Int) -> (index: Int, isNew: Bool) {
    if let existing = toolContentIndexes[wireIndex] { return (existing, false) }
    let index = nextContentIndex
    nextContentIndex += 1
    toolContentIndexes[wireIndex] = index
    openToolContentIndexes.append(index)
    return (index, true)
  }

  private static func stopReason(for finishReason: String) -> StopReason {
    switch finishReason {
    case "stop": return .endTurn
    case "tool_calls", "function_call": return .toolUse
    case "length": return .length
    case "content_filter": return .error
    default: return .endTurn
    }
  }

  private static func usage(from wireUsage: Chunk.WireUsage) -> Usage {
    let cachedTokens = wireUsage.promptTokensDetails?.cachedTokens ?? 0
    let promptTokens = wireUsage.promptTokens ?? 0
    return Usage(
      inputTokens: max(0, promptTokens - cachedTokens),
      outputTokens: wireUsage.completionTokens ?? 0,
      cacheReadTokens: cachedTokens,
      cacheWriteTokens: 0
    )
  }
}

/// The JSON shape of one Chat Completions streaming chunk (a `data:` line's
/// payload).
private struct Chunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      struct ToolCallDelta: Decodable {
        struct Function: Decodable {
          var name: String?
          var arguments: String?
        }
        var index: Int
        var id: String?
        var function: Function?
      }

      var content: String?
      var toolCalls: [ToolCallDelta]?

      private enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
      }
    }

    var delta: Delta
    var finishReason: String?

    private enum CodingKeys: String, CodingKey {
      case delta
      case finishReason = "finish_reason"
    }
  }

  struct WireUsage: Decodable {
    struct PromptTokensDetails: Decodable {
      var cachedTokens: Int?
      private enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
      }
    }

    var promptTokens: Int?
    var completionTokens: Int?
    var promptTokensDetails: PromptTokensDetails?

    private enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case promptTokensDetails = "prompt_tokens_details"
    }
  }

  var choices: [Choice]
  var usage: WireUsage?
}

// MARK: - Request building

extension OpenAICompletionsAPI {
  /// Builds the HTTP request for `request` against `connection`.
  ///
  /// Appending `"chat/completions"` to `connection.baseURL` preserves any
  /// path prefix already present, so both `https://api.openai.com/v1` and
  /// an arbitrary OpenAI-compatible proxy resolve correctly. `connection.auth`
  /// is always rendered as a bearer `Authorization` header — Chat
  /// Completions and the OpenAI-compatible endpoints in the built-in
  /// catalog have no other auth shape. Package-access so the request-shape
  /// test can exercise it with no network (`TEST-2`).
  package static func makeHTTPRequest(
    for request: LLMRequest,
    connection: ProviderConnection
  ) throws -> HTTPStreamRequest {
    let url = connection.baseURL.appendingPathComponent("chat/completions")

    var headers: [String: String] = ["Content-Type": "application/json"]
    switch connection.auth {
    case .apiKey(let key), .bearer(let key):
      headers["Authorization"] = "Bearer \(key)"
    case .headers(let extra):
      for (field, value) in extra {
        headers[field] = value
      }
    case .none:
      break
    }

    let body = RequestBody(
      model: request.model,
      messages: Self.makeMessages(for: request),
      stream: true,
      streamOptions: RequestBody.StreamOptions(includeUsage: true),
      // Chat Completions rejects an empty `tools` array, and a request
      // with no tools must be indistinguishable from one that never
      // mentioned them: `nil` omits the key entirely (R5).
      tools: request.tools.isEmpty ? nil : request.tools.map(Self.makeTool)
    )
    let bodyData = try JSONEncoder().encode(body)

    return HTTPStreamRequest(url: url, method: "POST", headers: headers, body: bodyData)
  }

  /// Renders one provider-neutral `ToolDefinition` in the Chat
  /// Completions shape: `{"type": "function", "function": {...}}` (R5).
  private static func makeTool(_ tool: ToolDefinition) -> RequestBody.Tool {
    RequestBody.Tool(
      function: RequestBody.Tool.Function(
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      ))
  }

  private static func makeMessages(for request: LLMRequest) -> [RequestBody.Message] {
    var messages: [RequestBody.Message] = []
    if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
      messages.append(RequestBody.Message(role: "system", content: .text(systemPrompt)))
    }
    for message in request.messages {
      switch message {
      case .user(let user):
        messages.append(
          RequestBody.Message(role: "user", content: Self.makeContent(user.content)))
      case .assistant(let assistant):
        let text = assistant.content.compactMap { block -> String? in
          guard case .text(let text) = block else { return nil }
          return text
        }.joined()
        let toolCalls: [RequestBody.ToolCall] = assistant.content.compactMap { block in
          guard case .toolCall(let id, let name, let argumentsJSON) = block else { return nil }
          return RequestBody.ToolCall(
            id: id, function: RequestBody.ToolCall.Function(name: name, arguments: argumentsJSON))
        }
        messages.append(
          RequestBody.Message(
            role: "assistant",
            content: text.isEmpty ? nil : .text(text),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
          ))
      case .toolResult(let result):
        let text = result.content.compactMap { block -> String? in
          guard case .text(let text) = block else { return nil }
          return text
        }.joined()
        messages.append(
          RequestBody.Message(role: "tool", content: .text(text), toolCallID: result.toolCallID))
      }
    }
    return messages
  }

  private static func makeContent(_ blocks: [ContentBlock]) -> RequestBody.MessageContent {
    if blocks.count == 1, case .text(let text) = blocks[0] {
      return .text(text)
    }
    let parts: [RequestBody.ContentPart] = blocks.compactMap { block in
      switch block {
      case .text(let text):
        return RequestBody.ContentPart(type: "text", text: text)
      case .image(let data, let mimeType):
        let url = "data:\(mimeType);base64,\(data.base64EncodedString())"
        return RequestBody.ContentPart(type: "image_url", imageURL: .init(url: url))
      case .thinking, .toolCall:
        // Not meaningful in a user turn's content; the request-shape
        // contract has nothing to say about them, so they are dropped
        // rather than guessed at.
        return nil
      }
    }
    return .parts(parts)
  }
}

/// The JSON shape POSTed to `<baseURL>/chat/completions`.
private struct RequestBody: Encodable {
  var model: String
  var messages: [Message]
  var stream: Bool
  var streamOptions: StreamOptions
  var tools: [Tool]?

  private enum CodingKeys: String, CodingKey {
    case model, messages, stream, tools
    case streamOptions = "stream_options"
  }

  struct StreamOptions: Encodable {
    var includeUsage: Bool
    private enum CodingKeys: String, CodingKey {
      case includeUsage = "include_usage"
    }
  }

  struct Message: Encodable {
    var role: String
    var content: MessageContent?
    var toolCalls: [ToolCall]?
    var toolCallID: String?

    init(
      role: String,
      content: MessageContent? = nil,
      toolCalls: [ToolCall]? = nil,
      toolCallID: String? = nil
    ) {
      self.role = role
      self.content = content
      self.toolCalls = toolCalls
      self.toolCallID = toolCallID
    }

    private enum CodingKeys: String, CodingKey {
      case role, content
      case toolCalls = "tool_calls"
      case toolCallID = "tool_call_id"
    }
  }

  enum MessageContent: Encodable {
    case text(String)
    case parts([ContentPart])

    func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .text(let text):
        try container.encode(text)
      case .parts(let parts):
        try container.encode(parts)
      }
    }
  }

  struct ContentPart: Encodable {
    var type: String
    var text: String?
    var imageURL: ImageURL?

    init(type: String, text: String? = nil, imageURL: ImageURL? = nil) {
      self.type = type
      self.text = text
      self.imageURL = imageURL
    }

    private enum CodingKeys: String, CodingKey {
      case type, text
      case imageURL = "image_url"
    }
  }

  struct ImageURL: Encodable {
    var url: String
  }

  struct Tool: Encodable {
    var type = "function"
    var function: Function

    struct Function: Encodable {
      var name: String
      var description: String
      var parameters: JSONValue
    }
  }

  struct ToolCall: Encodable {
    var id: String
    var type = "function"
    var function: Function

    struct Function: Encodable {
      var name: String
      var arguments: String
    }
  }
}
