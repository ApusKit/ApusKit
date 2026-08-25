public import ApusKitCore
internal import ApusKitWireFormat
internal import Foundation

/// The `APIImplementation` conformance for OpenAI's Responses API.
///
/// Builds a `POST <baseURL>/responses` streaming request and parses the
/// Responses API's named SSE event types — `response.created`,
/// `response.output_item.added`, `response.function_call_arguments.delta`,
/// `response.output_text.delta`, `response.completed`, `response.failed` —
/// into unified `StreamEvent`s satisfying `PROV-1`. Any other event type on
/// the wire is ignored.
///
/// `request.cacheBreakpoints` (`PROV-2`) is silently ignored: the Responses
/// API has no equivalent wire concept, unlike Anthropic's `cache_control`.
///
/// Per `CC-4`, all per-stream state (the SSE parser, which tool calls are
/// still open, the per-index argument accumulators) lives in local
/// variables captured by the single stream `Task` — no lock or actor.
public struct OpenAIResponsesAPI: APIImplementation {
  /// The wire protocol identifier this implementation reports.
  public let id: APIImplementationID = .openAIResponses

  /// Creates an OpenAI Responses API implementation.
  public init() {}

  /// Streams a single conversational turn as unified `StreamEvent`s.
  ///
  /// Per `PROV-1`, exactly one `.start` is yielded first and exactly one
  /// terminal `.done` or `.error` is yielded last. A transport failure or
  /// a malformed/incomplete response is surfaced as a terminal
  /// `.error(StreamError)` event rather than a thrown error.
  public func stream(request: LLMRequest, connection: ProviderConnection) -> AsyncThrowingStream<
    StreamEvent, any Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        // `.start` is yielded unconditionally, before anything can fail,
        // so PROV-1's "exactly one `.start` first" holds on every exit
        // path — including a transport failure and a `response.failed`
        // event that arrives without a preceding `response.created`.
        continuation.yield(.start)
        do {
          let httpRequest = Self.makeHTTPRequest(for: request, connection: connection)
          var parser = SSEParser()
          var state = ResponseStreamState()
          var reachedTerminalEvent = false

          streamLoop: for try await chunk in connection.transport.stream(httpRequest) {
            let events: [SSEEvent]
            do {
              events = try parser.feed(chunk.data)
            } catch let parseError as SSEParseError {
              continuation.yield(.error(StreamError(code: .decoding, message: parseError.message)))
              reachedTerminalEvent = true
              break streamLoop
            }
            for sseEvent in events {
              if Self.handle(sseEvent, state: &state, continuation: continuation) {
                reachedTerminalEvent = true
                break streamLoop
              }
            }
          }

          if !reachedTerminalEvent {
            continuation.yield(
              .error(
                StreamError(
                  code: .decoding,
                  message: "OpenAI Responses stream ended before a terminal event")))
          }
          continuation.finish()
        } catch {
          if let streamError = error as? StreamError {
            continuation.yield(.error(streamError))
          } else {
            continuation.yield(
              .error(StreamError(code: .transport, message: "\(error)")))
          }
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

// MARK: - Request building

extension OpenAIResponsesAPI {
  /// Builds the `POST <baseURL>/responses` request for `request`,
  /// preserving any existing path prefix on `connection.baseURL`.
  static func makeHTTPRequest(for request: LLMRequest, connection: ProviderConnection)
    -> HTTPStreamRequest
  {
    let url = connection.baseURL.appendingPathComponent("responses")
    var headers: [String: String] = ["Content-Type": "application/json"]
    switch connection.auth {
    case .bearer(let token):
      headers["Authorization"] = "Bearer \(token)"
    case .apiKey(let key):
      headers["Authorization"] = "Bearer \(key)"
    case .headers(let extra):
      for (field, value) in extra {
        headers[field] = value
      }
    case .none:
      break
    }
    // Construction is entirely from fixed literals and caller-supplied
    // strings, so encoding cannot fail; `try?` is not swallowing a
    // reachable error path.
    let body = try? JSONSerialization.data(
      withJSONObject: Self.makeRequestBody(for: request), options: [.sortedKeys])
    return HTTPStreamRequest(url: url, method: "POST", headers: headers, body: body)
  }

  /// Builds the JSON request body for `request`.
  static func makeRequestBody(for request: LLMRequest) -> [String: Any] {
    var body: [String: Any] = [
      "model": request.model,
      "stream": true,
      "input": request.messages.flatMap(makeInputItems(for:)),
    ]
    if let systemPrompt = request.systemPrompt {
      body["instructions"] = systemPrompt
    }
    // No tools means no `tools` key at all — an empty array would be an
    // extra, provider-visible difference from a request that never
    // mentioned tools (R5).
    if !request.tools.isEmpty {
      body["tools"] = request.tools.map(renderToolDefinition)
    }
    return body
  }

  /// Renders one provider-neutral `ToolDefinition` in the Responses API's
  /// flat function shape — `type`/`name`/`description`/`parameters` at the
  /// top level, unlike Chat Completions' nested `function` object (R5).
  static func renderToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
    [
      "type": "function",
      "name": tool.name,
      "description": tool.description,
      "parameters": tool.parameters.jsonSerializationValue,
    ]
  }

  /// Renders one `LLMRequestMessage` as the Responses API's `input` items.
  ///
  /// A user message becomes one `"role": "user"` item. An assistant
  /// message becomes a `"role": "assistant"` message item for its text,
  /// interleaved with one `"function_call"` item per tool call, in order.
  /// A tool result becomes one `"function_call_output"` item. Thinking and
  /// image content in assistant messages is dropped: the Responses API has
  /// no wire representation for replaying prior reasoning, and image
  /// output never appears in an assistant turn.
  static func makeInputItems(for message: LLMRequestMessage) -> [[String: Any]] {
    switch message {
    case .user(let userMessage):
      return [
        [
          "role": "user",
          "content": userMessage.content.compactMap(makeInputContentPart(for:)),
        ]
      ]

    case .assistant(let assistantMessage):
      var items: [[String: Any]] = []
      var pendingText: [[String: Any]] = []
      for block in assistantMessage.content {
        switch block {
        case .text(let text):
          pendingText.append(["type": "output_text", "text": text])
        case .toolCall(let id, let name, let argumentsJSON):
          if !pendingText.isEmpty {
            items.append(["role": "assistant", "content": pendingText])
            pendingText = []
          }
          items.append([
            "type": "function_call",
            "call_id": id,
            "name": name,
            "arguments": argumentsJSON,
          ])
        case .thinking, .image:
          continue
        }
      }
      if !pendingText.isEmpty {
        items.append(["role": "assistant", "content": pendingText])
      }
      return items

    case .toolResult(let toolResultMessage):
      let output = toolResultMessage.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text
      }.joined(separator: "\n")
      return [
        [
          "type": "function_call_output",
          "call_id": toolResultMessage.toolCallID,
          "output": output,
        ]
      ]
    }
  }

  /// Renders one user-message `ContentBlock` as a Responses API input
  /// content part, or `nil` if the block has no input representation.
  static func makeInputContentPart(for block: ContentBlock) -> [String: Any]? {
    switch block {
    case .text(let text):
      return ["type": "input_text", "text": text]
    case .image(let data, let mimeType):
      return [
        "type": "input_image",
        "image_url": "data:\(mimeType);base64,\(data.base64EncodedString())",
      ]
    case .thinking, .toolCall:
      return nil
    }
  }
}

// MARK: - Response parsing

/// Per-stream mutable state accumulated while parsing one Responses API
/// SSE stream. Lives entirely inside the single stream `Task` (`CC-4`).
fileprivate struct ResponseStreamState {
  /// Content indices of tool calls that have started but not yet ended,
  /// in the order they started. Closed out at `response.completed`.
  var openToolCallIndices: [Int] = []

  /// Whether any tool call was produced this turn, used to infer
  /// `stopReason` at `response.completed`.
  var producedToolCall = false
}

extension OpenAIResponsesAPI {
  /// Decodes and dispatches one SSE event, yielding the unified
  /// `StreamEvent`(s) it implies.
  ///
  /// - Returns: `true` if `sseEvent` was terminal (`response.completed` or
  ///   `response.failed`) and the caller should stop reading the stream.
  fileprivate static func handle(
    _ sseEvent: SSEEvent,
    state: inout ResponseStreamState,
    continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) -> Bool {
    let data = Data(sseEvent.data.utf8)
    let kind = sseEvent.event ?? decodeTypeField(data)

    switch kind {
    case "response.created":
      // `.start` was already yielded by `stream(request:connection:)`;
      // this event carries nothing else the unified stream represents.
      return false

    case "response.output_item.added":
      guard let event = try? JSONDecoder().decode(OutputItemAddedEvent.self, from: data) else {
        return false
      }
      guard event.item.type == "function_call" else { return false }
      let contentIndex = event.outputIndex
      state.openToolCallIndices.append(contentIndex)
      state.producedToolCall = true
      continuation.yield(
        .toolCallStart(
          contentIndex: contentIndex,
          id: event.item.callID ?? event.item.id ?? "",
          name: event.item.name ?? ""
        ))
      return false

    case "response.function_call_arguments.delta":
      guard
        let event = try? JSONDecoder().decode(FunctionCallArgumentsDeltaEvent.self, from: data)
      else { return false }
      let contentIndex = event.outputIndex ?? 0
      // Forwarded verbatim: `.toolCallDelta` is an append-only contract —
      // `RunLoop` concatenates the fragments — so this adapter must not
      // rewrite them. Repairing a partial arguments snapshot is a reader's
      // concern, not the wire adapter's.
      continuation.yield(
        .toolCallDelta(contentIndex: contentIndex, argumentsJSONDelta: event.delta))
      return false

    case "response.output_text.delta":
      guard let event = try? JSONDecoder().decode(OutputTextDeltaEvent.self, from: data) else {
        return false
      }
      continuation.yield(.textDelta(contentIndex: event.outputIndex ?? 0, text: event.delta))
      return false

    case "response.completed":
      for contentIndex in state.openToolCallIndices {
        continuation.yield(.toolCallEnd(contentIndex: contentIndex))
      }
      guard let event = try? JSONDecoder().decode(ResponseCompletedEvent.self, from: data) else {
        continuation.yield(
          .error(StreamError(code: .decoding, message: "could not decode response.completed")))
        return true
      }
      continuation.yield(
        .done(
          usage: Self.makeUsage(from: event.response.usage),
          stopReason: state.producedToolCall ? .toolUse : .endTurn))
      return true

    case "response.failed":
      let message =
        (try? JSONDecoder().decode(ResponseFailedEvent.self, from: data))?
        .response.error?.message ?? "OpenAI Responses request failed"
      continuation.yield(.error(StreamError(code: .provider, message: message)))
      return true

    default:
      return false
    }
  }

  /// Decodes the `"type"` field from a raw SSE data payload, for use when
  /// the SSE `event:` field itself is absent.
  private static func decodeTypeField(_ data: Data) -> String {
    struct TypeField: Decodable { let type: String }
    return (try? JSONDecoder().decode(TypeField.self, from: data))?.type ?? ""
  }

  /// Converts a decoded `response.completed` usage payload into `Usage`.
  ///
  /// OpenAI reports `input_tokens` as the *total* input token count and
  /// `input_tokens_details.cached_tokens` as the subset served from
  /// cache, whereas `Usage.inputTokens` documents only the non-cached
  /// count — so the cached count is subtracted out here.
  private static func makeUsage(from usage: ResponseCompletedEvent.UsageBody?) -> Usage {
    guard let usage else {
      return Usage(inputTokens: 0, outputTokens: 0)
    }
    let cacheReadTokens = usage.inputTokensDetails?.cachedTokens ?? 0
    return Usage(
      inputTokens: max(usage.inputTokens - cacheReadTokens, 0),
      outputTokens: usage.outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: 0
    )
  }
}

// MARK: - Wire event payloads

/// The decoded payload of a `response.output_item.added` event.
private struct OutputItemAddedEvent: Decodable {
  struct Item: Decodable {
    var id: String?
    var type: String
    var callID: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
      case id, type, name
      case callID = "call_id"
    }
  }

  var outputIndex: Int
  var item: Item

  enum CodingKeys: String, CodingKey {
    case outputIndex = "output_index"
    case item
  }
}

/// The decoded payload of a `response.function_call_arguments.delta` event.
private struct FunctionCallArgumentsDeltaEvent: Decodable {
  var outputIndex: Int?
  var delta: String

  enum CodingKeys: String, CodingKey {
    case outputIndex = "output_index"
    case delta
  }
}

/// The decoded payload of a `response.output_text.delta` event.
private struct OutputTextDeltaEvent: Decodable {
  var outputIndex: Int?
  var delta: String

  enum CodingKeys: String, CodingKey {
    case outputIndex = "output_index"
    case delta
  }
}

/// The decoded payload of a `response.completed` event.
private struct ResponseCompletedEvent: Decodable {
  struct ResponseBody: Decodable {
    var usage: UsageBody?
  }

  struct UsageBody: Decodable {
    struct InputTokensDetails: Decodable {
      var cachedTokens: Int?
      enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
      }
    }

    var inputTokens: Int
    var outputTokens: Int
    var inputTokensDetails: InputTokensDetails?

    enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
      case inputTokensDetails = "input_tokens_details"
    }
  }

  var response: ResponseBody
}

/// The decoded payload of a `response.failed` event.
private struct ResponseFailedEvent: Decodable {
  struct ResponseBody: Decodable {
    struct ErrorBody: Decodable {
      var message: String?
    }
    var error: ErrorBody?
  }

  var response: ResponseBody
}
