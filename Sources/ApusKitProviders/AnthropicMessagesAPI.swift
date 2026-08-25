public import ApusKitCore
internal import ApusKitWireFormat
internal import Foundation

/// Speaks the Anthropic Messages API wire protocol (`POST /v1/messages`,
/// `stream: true`), including `cache_control` prompt-caching passthrough
/// (`PROV-2`) rendered from `LLMRequest.cacheBreakpoints`.
///
/// Requests are streamed through the injected `StreamingHTTPTransport`;
/// the response body is decoded with `SSEParser` and re-assembled into
/// unified `StreamEvent`s satisfying `PROV-1` — exactly one `.start`
/// first, exactly one terminal `.done` or `.error` last, and
/// `contentIndex` on every `toolCall*` event. Tool-call argument
/// fragments (`input_json_delta`) are tracked through one
/// `PartialJSONAccumulator` per content index so a chunk boundary falling
/// anywhere in the transcript never corrupts them.
public struct AnthropicMessagesAPI: APIImplementation {
  /// The wire protocol identifier this instance reports.
  public let id: APIImplementationID = .anthropicMessages

  /// The Anthropic API version sent with every request.
  private static let apiVersion = "2023-06-01"

  /// `LLMRequest` carries no token-budget field (none of the three built-in
  /// wire protocols agree on one), so a fixed, generous ceiling is sent for
  /// Anthropic's mandatory `max_tokens` field.
  private static let defaultMaxTokens = 4096

  /// Creates an Anthropic Messages API adapter.
  public init() {}

  /// Streams a single conversational turn as unified `StreamEvent`s.
  public func stream(request: LLMRequest, connection: ProviderConnection) -> AsyncThrowingStream<
    StreamEvent, any Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let httpRequest = try Self.makeHTTPRequest(for: request, connection: connection)
          await Self.pump(connection.transport.stream(httpRequest), into: continuation)
        } catch {
          continuation.yield(.error(StreamError(code: .provider, message: "\(error)")))
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Request building

  private static func makeHTTPRequest(
    for request: LLMRequest,
    connection: ProviderConnection
  ) throws -> HTTPStreamRequest {
    let url = connection.baseURL.appendingPathComponent("v1/messages")

    var headers: [String: String] = [
      "Content-Type": "application/json",
      "anthropic-version": apiVersion,
    ]
    switch connection.auth {
    case .apiKey(let key):
      headers["x-api-key"] = key
    case .bearer(let token):
      headers["Authorization"] = "Bearer \(token)"
    case .headers(let extra):
      for (field, value) in extra {
        headers[field] = value
      }
    case .none:
      break
    }

    let body = makeRequestBody(for: request)
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return HTTPStreamRequest(url: url, method: "POST", headers: headers, body: data)
  }

  private static func makeRequestBody(for request: LLMRequest) -> [String: Any] {
    var body: [String: Any] = [
      "model": request.model,
      "max_tokens": defaultMaxTokens,
      "stream": true,
      "messages": request.messages.enumerated().map { index, message in
        renderMessage(message, cacheBreakpoint: request.cacheBreakpoints.contains(index))
      },
    ]
    if let systemPrompt = request.systemPrompt {
      body["system"] = systemPrompt
    }
    return body
  }

  private static func renderMessage(
    _ message: LLMRequestMessage,
    cacheBreakpoint: Bool
  ) -> [String: Any] {
    let role: String
    var blocks: [[String: Any]]
    switch message {
    case .user(let userMessage):
      role = "user"
      blocks = userMessage.content.map(renderContentBlock)
    case .assistant(let assistantMessage):
      role = "assistant"
      blocks = assistantMessage.content.map(renderContentBlock)
    case .toolResult(let toolResultMessage):
      role = "user"
      blocks = [renderToolResultBlock(toolResultMessage)]
    }

    // A cache breakpoint marks everything up to and including this
    // message as cacheable, rendered on the message's trailing block —
    // the shape Anthropic's `cache_control` passthrough expects.
    if cacheBreakpoint, var lastBlock = blocks.popLast() {
      lastBlock["cache_control"] = ["type": "ephemeral"]
      blocks.append(lastBlock)
    }

    return ["role": role, "content": blocks]
  }

  private static func renderContentBlock(_ block: ContentBlock) -> [String: Any] {
    switch block {
    case .text(let text):
      return ["type": "text", "text": text]
    case .image(let data, let mimeType):
      return [
        "type": "image",
        "source": [
          "type": "base64",
          "media_type": mimeType,
          "data": data.base64EncodedString(),
        ],
      ]
    case .thinking(let text):
      return ["type": "thinking", "thinking": text]
    case .toolCall(let id, let name, let argumentsJSON):
      let input =
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        ?? [:]
      return ["type": "tool_use", "id": id, "name": name, "input": input]
    }
  }

  private static func renderToolResultBlock(_ toolResult: ToolResultMessage) -> [String: Any] {
    var block: [String: Any] = [
      "type": "tool_result",
      "tool_use_id": toolResult.toolCallID,
      "content": toolResult.content.map(renderContentBlock),
    ]
    if toolResult.isError {
      block["is_error"] = true
    }
    return block
  }

  // MARK: - Response parsing

  /// Consumes `chunks` through an `SSEParser`, translating Anthropic's SSE
  /// event set into unified `StreamEvent`s and yielding them into
  /// `continuation`.
  ///
  /// Every exit path yields exactly one terminal event — `.done` on a
  /// well-formed `message_stop`, `.error` on a provider `error` event, a
  /// transport failure, a malformed SSE line, or the byte stream simply
  /// ending before a terminal event arrived — and then finishes the
  /// continuation, so callers never have to distinguish a thrown
  /// `AsyncThrowingStream` failure from a reported one.
  private static func pump(
    _ chunks: AsyncThrowingStream<HTTPStreamChunk, any Error>,
    into continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) async {
    var parser = SSEParser()
    var state = AnthropicStreamState()
    do {
      for try await chunk in chunks {
        let events = try parser.feed(chunk.data)
        for event in events {
          state.process(event, into: continuation)
          if state.isTerminal {
            continuation.finish()
            return
          }
        }
      }
    } catch let streamError as StreamError {
      continuation.yield(.error(streamError))
      continuation.finish()
      return
    } catch {
      continuation.yield(.error(StreamError(code: .decoding, message: "\(error)")))
      continuation.finish()
      return
    }

    if !state.isTerminal {
      continuation.yield(
        .error(
          StreamError(
            code: .decoding, message: "provider stream ended before a terminal event")))
    }
    continuation.finish()
  }

  /// Maps an Anthropic `stop_reason` string to the unified `StopReason`.
  fileprivate static func mapStopReason(_ reason: String) -> StopReason {
    switch reason {
    case "tool_use":
      return .toolUse
    case "max_tokens":
      return .length
    default:
      return .endTurn
    }
  }
}

/// Mutable, per-stream state for decoding one Anthropic Messages API
/// response into unified `StreamEvent`s.
///
/// Lives entirely inside the single `Task` driving `pump(_:into:)` — never
/// shared across tasks, so no lock or actor is needed (`CC-4`).
private struct AnthropicStreamState {
  private var didEmitStart = false
  private(set) var isTerminal = false

  private var toolCallIndices: Set<Int> = []
  private var accumulators: [Int: PartialJSONAccumulator] = [:]

  private var inputTokens = 0
  private var cacheReadTokens = 0
  private var cacheWriteTokens = 0
  private var outputTokens = 0
  private var stopReason: StopReason = .endTurn

  mutating func process(
    _ event: SSEEvent,
    into continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) {
    guard let type = event.event else { return }
    let payload = Self.jsonObject(from: event.data)

    switch type {
    case "message_start":
      emitStartIfNeeded(into: continuation)
      if let message = payload?["message"] as? [String: Any],
        let usage = message["usage"] as? [String: Any]
      {
        inputTokens = Self.int(usage, "input_tokens") ?? 0
        cacheReadTokens = Self.int(usage, "cache_read_input_tokens") ?? 0
        cacheWriteTokens = Self.int(usage, "cache_creation_input_tokens") ?? 0
      }

    case "content_block_start":
      guard
        let index = Self.int(payload, "index"),
        let block = payload?["content_block"] as? [String: Any],
        let blockType = block["type"] as? String
      else { return }
      if blockType == "tool_use" {
        toolCallIndices.insert(index)
        accumulators[index] = PartialJSONAccumulator()
        let id = block["id"] as? String ?? ""
        let name = block["name"] as? String ?? ""
        continuation.yield(.toolCallStart(contentIndex: index, id: id, name: name))
      }

    case "content_block_delta":
      guard
        let index = Self.int(payload, "index"),
        let delta = payload?["delta"] as? [String: Any],
        let deltaType = delta["type"] as? String
      else { return }
      switch deltaType {
      case "text_delta":
        if let text = delta["text"] as? String {
          continuation.yield(.textDelta(contentIndex: index, text: text))
        }
      case "thinking_delta":
        if let text = delta["thinking"] as? String {
          continuation.yield(.thinkingDelta(contentIndex: index, text: text))
        }
      case "input_json_delta":
        if let fragment = delta["partial_json"] as? String {
          accumulators[index, default: PartialJSONAccumulator()].append(fragment)
          continuation.yield(.toolCallDelta(contentIndex: index, argumentsJSONDelta: fragment))
        }
      default:
        break
      }

    case "content_block_stop":
      guard let index = Self.int(payload, "index") else { return }
      if toolCallIndices.contains(index) {
        continuation.yield(.toolCallEnd(contentIndex: index))
      }

    case "message_delta":
      if let delta = payload?["delta"] as? [String: Any],
        let reason = delta["stop_reason"] as? String
      {
        stopReason = AnthropicMessagesAPI.mapStopReason(reason)
      }
      if let usage = payload?["usage"] as? [String: Any],
        let tokens = Self.int(usage, "output_tokens")
      {
        outputTokens = tokens
      }

    case "message_stop":
      isTerminal = true
      let usage = Usage(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens
      )
      continuation.yield(.done(usage: usage, stopReason: stopReason))

    case "error":
      isTerminal = true
      let message = (payload?["error"] as? [String: Any])?["message"] as? String
      continuation.yield(
        .error(StreamError(code: .provider, message: message ?? "the provider reported an error"))
      )

    case "ping":
      break

    default:
      break
    }
  }

  /// Yields `.start` at most once, the first time the stream produces any
  /// content — defends `PROV-1`'s "exactly one `.start` first" even
  /// against a malformed transcript that repeats `message_start`.
  private mutating func emitStartIfNeeded(
    into continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) {
    guard !didEmitStart else { return }
    didEmitStart = true
    continuation.yield(.start)
  }

  private static func jsonObject(from data: String) -> [String: Any]? {
    guard let bytes = data.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
  }

  private static func int(_ dictionary: [String: Any]?, _ key: String) -> Int? {
    dictionary?[key] as? Int
  }
}
