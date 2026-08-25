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
/// fragments (`input_json_delta`) run through one
/// `PartialJSONAccumulator` per content index, which decides how much of
/// each fragment is safe to emit and completes the arguments into valid
/// JSON when the block ends — so concatenating a content index's
/// `toolCallDelta` payloads always parses, wherever the provider chopped
/// its fragments and wherever an HTTP chunk boundary fell.
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
        // `.start` is yielded unconditionally, before anything can fail,
        // so PROV-1's "exactly one `.start` first" holds on every exit
        // path — including a transport failure and an `error` SSE event
        // that arrives without a preceding `message_start`.
        continuation.yield(.start)
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
    if !request.tools.isEmpty {
      body["tools"] = request.tools.map(renderToolDefinition)
    }
    return body
  }

  private static func renderToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
    [
      "name": tool.name,
      "description": tool.description,
      "input_schema": tool.parameters.jsonSerializationValue,
    ]
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
      state.flushOpenToolCalls(into: continuation)
      continuation.yield(.error(streamError))
      continuation.finish()
      return
    } catch {
      state.flushOpenToolCalls(into: continuation)
      continuation.yield(.error(StreamError(code: .decoding, message: "\(error)")))
      continuation.finish()
      return
    }

    if !state.isTerminal {
      state.flushOpenToolCalls(into: continuation)
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
  private(set) var isTerminal = false

  private var toolCallIndices: Set<Int> = []
  /// Tool-call content indices that have started but not yet been closed,
  /// in the order they started.
  private var openToolCallIndices: [Int] = []
  private var arguments: [Int: ToolCallArgumentBuffer] = [:]

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
      // `.start` was already yielded by `stream(request:connection:)`;
      // `message_start` only carries the prompt-side usage counters.
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
        openToolCallIndices.append(index)
        arguments[index] = ToolCallArgumentBuffer()
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
        if let fragment = delta["partial_json"] as? String,
          let committed = arguments[index, default: ToolCallArgumentBuffer()].append(fragment)
        {
          continuation.yield(.toolCallDelta(contentIndex: index, argumentsJSONDelta: committed))
        }
      default:
        break
      }

    case "content_block_stop":
      guard let index = Self.int(payload, "index") else { return }
      if toolCallIndices.contains(index) {
        closeToolCall(index, into: continuation)
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
      flushOpenToolCalls(into: continuation)
      let usage = Usage(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens
      )
      continuation.yield(.done(usage: usage, stopReason: stopReason))

    case "error":
      isTerminal = true
      flushOpenToolCalls(into: continuation)
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

  /// Closes the tool-call block at `index`, emitting whatever the
  /// accumulator still owes to make its arguments valid JSON before the
  /// `.toolCallEnd`.
  mutating func closeToolCall(
    _ index: Int,
    into continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) {
    openToolCallIndices.removeAll { $0 == index }
    if let completion = arguments[index]?.finish() {
      continuation.yield(.toolCallDelta(contentIndex: index, argumentsJSONDelta: completion))
    }
    arguments[index] = nil
    continuation.yield(.toolCallEnd(contentIndex: index))
  }

  /// Closes every tool-call block the provider left open.
  ///
  /// A stream can end — normally, on a provider `error`, or by simply
  /// dying mid-transcript — with a tool call still receiving argument
  /// fragments. Closing the block through the accumulator repairs the
  /// truncated arguments into valid JSON, so a consumer that concatenated
  /// the `toolCallDelta` payloads can still parse them.
  mutating func flushOpenToolCalls(
    into continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
  ) {
    for index in openToolCallIndices {
      closeToolCall(index, into: continuation)
    }
    openToolCallIndices = []
  }

  private static func jsonObject(from data: String) -> [String: Any]? {
    guard let bytes = data.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
  }

  private static func int(_ dictionary: [String: Any]?, _ key: String) -> Int? {
    dictionary?[key] as? Int
  }
}

/// Accumulates one tool call's streamed `input_json_delta` fragments
/// through a `PartialJSONAccumulator`.
///
/// The accumulator decides what may be emitted: after each fragment, only
/// the bytes its repaired snapshot still agrees with — the arguments text
/// committed so far — is handed on as a `toolCallDelta`, and the rest is
/// held back. A fragment ending mid-token (an unterminated string, a
/// dangling `\` escape, half a `\uXXXX`) therefore never reaches a
/// consumer as an un-completable tail; when the block ends, ``finish()``
/// emits exactly what the repair adds on top of what was already sent.
/// Concatenating a content index's deltas is consequently always valid
/// JSON, even when the provider stopped mid-arguments.
private struct ToolCallArgumentBuffer {
  private var accumulator = PartialJSONAccumulator()
  private var raw: [UInt8] = []
  private var emitted = 0

  /// Appends `fragment` and returns the argument text that has become
  /// safe to emit, or `nil` if the repair committed nothing new.
  mutating func append(_ fragment: String) -> String? {
    accumulator.append(fragment)
    raw.append(contentsOf: fragment.utf8)
    let repaired = Array(accumulator.snapshot().utf8)

    // The longest prefix the raw text and its repair agree on is exactly
    // the raw text the repair kept; anything past it is either a closer
    // the repair synthesized or a tail it dropped, neither of which can
    // be emitted as a delta yet.
    var committed = 0
    while committed < raw.count, committed < repaired.count, raw[committed] == repaired[committed] {
      committed += 1
    }
    // Never cut a multi-byte scalar in half.
    while committed > 0, committed < raw.count, raw[committed] & 0xC0 == 0x80 {
      committed -= 1
    }

    guard committed > emitted else { return nil }
    defer { emitted = committed }
    return String(decoding: raw[emitted..<committed], as: UTF8.self)
  }

  /// Returns whatever completes the emitted text into valid JSON, or
  /// `nil` if nothing is outstanding.
  mutating func finish() -> String? {
    // No fragments at all means a tool call with no arguments; the
    // accumulator would repair that to `null`, which is not what an empty
    // argument list means, so nothing is emitted.
    guard !raw.isEmpty else { return nil }
    let repaired = Array(accumulator.snapshot().utf8)
    guard emitted < repaired.count else { return nil }
    defer { emitted = repaired.count }
    return String(decoding: repaired[emitted...], as: UTF8.self)
  }
}
