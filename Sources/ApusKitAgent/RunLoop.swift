internal import ApusKitCore
internal import ApusKitProviders
internal import ApusKitTools
internal import JSONSchema

/// `Agent`'s pi-ported run loop (TRD §3.6, `LOOP-1..7`).
extension Agent {
  /// Outer loop (`LOOP-1`): drains `followUpQueue` one message at a time,
  /// running the inner turn loop for each, until the queue is empty.
  func drainFollowUpQueue() async -> AssistantMessage {
    eventContinuation.yield(.agentStart)

    var lastMessage = AssistantMessage(
      content: [],
      stopReason: .aborted,
      usage: Usage(inputTokens: 0, outputTokens: 0)
    )

    while !followUpQueue.isEmpty {
      let next = followUpQueue.removeFirst()
      history.append(.user(next))
      lastMessage = await runTurns()

      if Task.isCancelled {
        break
      }
    }

    eventContinuation.yield(.agentEnd(lastMessage))
    return lastMessage
  }

  /// Inner loop (`LOOP-1`): keeps requesting turns while the model keeps
  /// asking for tool calls, per turn following `LOOP-2`'s sequence.
  func runTurns() async -> AssistantMessage {
    while true {
      eventContinuation.yield(.turnStart)

      if Task.isCancelled {
        let aborted = AssistantMessage(
          content: [],
          stopReason: .aborted,
          usage: Usage(inputTokens: 0, outputTokens: 0)
        )
        eventContinuation.yield(.turnEnd(aborted))
        return aborted
      }

      let contextForProvider = transformContext(history)
      // R6: sorted by name first — ToolRegistry.allTools' order is
      // nondeterministic (dictionary-backed), and an unsorted mapping
      // would make the tools sent on the wire flap from turn to turn.
      let toolDefinitions = tools.allTools
        .sorted { $0.name < $1.name }
        .map { tool in
          ToolDefinition(name: tool.name, description: tool.description, parameters: tool.schema)
        }
      let request = LLMRequest(
        model: model, messages: contextForProvider, systemPrompt: systemPrompt,
        tools: toolDefinitions)

      let message: AssistantMessage
      do {
        message = try await streamTurn(request: request)
      } catch {
        // LOOP-3: errors never throw out of the loop.
        let errorMessage = finalMessage(for: error)
        eventContinuation.yield(.turnEnd(errorMessage))
        return errorMessage
      }

      history.append(.assistant(message))
      eventContinuation.yield(.turnEnd(message))

      // LOOP-4: a .length stop fails all of this message's tool calls,
      // unexecuted — truncated arguments are unsafe to run.
      if message.stopReason == .length {
        failToolCalls(in: message)
        return message
      }

      // LOOP-1: the inner loop continues while tool calls remain, so the
      // decision keys on the message's tool-call blocks rather than on its
      // stop reason. LOOP-2 orders this check last: execute tools ->
      // prepareNextTurn -> shouldStopAfterTurn.
      guard !toolCalls(in: message).isEmpty else {
        return message
      }

      await executeToolCalls(in: message)
      prepareNextTurn()

      if shouldStopAfterTurn(message) {
        return message
      }
    }
  }

  /// Streams one provider turn, mutating a partial `AssistantMessage` as
  /// each `StreamEvent` arrives, per `LOOP-2`.
  func streamTurn(request: LLMRequest) async throws -> AssistantMessage {
    eventContinuation.yield(.messageStart)

    var texts: [Int: String] = [:]
    var thinkingTexts: [Int: String] = [:]
    var toolCalls: [Int: (id: String, name: String, argumentsJSON: String)] = [:]
    var contentIndices: Set<Int> = []
    var usage = Usage(inputTokens: 0, outputTokens: 0)
    var stopReason = StopReason.error

    let stream = apiImplementation.stream(request: request, connection: connection)

    for try await event in stream {
      eventContinuation.yield(.messageUpdate(event))

      switch event {
      case .start:
        break
      case .textDelta(let contentIndex, let text):
        contentIndices.insert(contentIndex)
        texts[contentIndex, default: ""] += text
      case .thinkingDelta(let contentIndex, let text):
        contentIndices.insert(contentIndex)
        thinkingTexts[contentIndex, default: ""] += text
      case .toolCallStart(let contentIndex, let id, let name):
        contentIndices.insert(contentIndex)
        toolCalls[contentIndex] = (id: id, name: name, argumentsJSON: "")
      case .toolCallDelta(let contentIndex, let argumentsJSONDelta):
        toolCalls[contentIndex]?.argumentsJSON += argumentsJSONDelta
      case .toolCallEnd:
        break
      case .done(let doneUsage, let doneStopReason):
        usage = doneUsage
        stopReason = doneStopReason
      case .error(let streamError):
        throw streamError
      }
    }

    // LOOP-6: a cancelled consumer sees the provider's stream *finish*
    // rather than throw, so without this check an aborted turn would be
    // reported as whatever partial message had accumulated. Surface the
    // cancellation instead, so it lands on `finalMessage(for:)`'s
    // `.aborted` path.
    try Task.checkCancellation()

    let content: [ContentBlock] = contentIndices.sorted().compactMap { index in
      if let text = texts[index] {
        return .text(text)
      }
      if let thinking = thinkingTexts[index] {
        return .thinking(thinking)
      }
      if let call = toolCalls[index] {
        return .toolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON)
      }
      return nil
    }

    let message = AssistantMessage(content: content, stopReason: stopReason, usage: usage)
    eventContinuation.yield(.messageEnd(message))
    return message
  }

  /// Executes every tool call in `message` in parallel (`LOOP-7`),
  /// appending a `ToolResultMessage` to `history` for each and stopping
  /// the batch early if any result carries `terminate: true`.
  func executeToolCalls(in message: AssistantMessage) async {
    let calls = toolCalls(in: message)

    guard !calls.isEmpty else { return }

    let continuation = eventContinuation
    let resolvedCalls = calls.map { call in (call: call, tool: tools.tool(named: call.name)) }

    await withTaskGroup(of: (String, ToolResult).self) { group in
      for (call, tool) in resolvedCalls {
        group.addTask {
          continuation.yield(.toolExecutionStart(toolCallID: call.id, name: call.name))

          guard let tool else {
            let result = ToolResult(
              content: [.text("No tool named \"\(call.name)\" is registered.")],
              details: ["error": .string("unknown tool")]
            )
            continuation.yield(.toolExecutionEnd(toolCallID: call.id, result: result))
            return (call.id, result)
          }

          let result = await tool.execute(
            toolCallID: call.id,
            argumentsJSON: call.argumentsJSON,
            signal: ToolCancellationSignal(),
            onUpdate: { update in
              continuation.yield(.toolExecutionUpdate(toolCallID: call.id, update: update))
            }
          )
          continuation.yield(.toolExecutionEnd(toolCallID: call.id, result: result))
          return (call.id, result)
        }
      }

      for await (id, result) in group {
        history.append(
          .toolResult(
            ToolResultMessage(
              toolCallID: id,
              content: result.content,
              isError: result.details["error"] != nil
            )
          )
        )
        if result.terminate {
          group.cancelAll()
        }
      }
    }
  }

  /// Fails every tool call in `message` without executing it (`LOOP-4`).
  ///
  /// A `.length` stop means the model was cut off mid-serialization, so
  /// the arguments are unsafe to run — but each call still has to be
  /// answered, or the next request would carry an assistant tool call
  /// with no matching tool result.
  func failToolCalls(in message: AssistantMessage) {
    for call in toolCalls(in: message) {
      history.append(
        .toolResult(
          ToolResultMessage(
            toolCallID: call.id,
            content: [
              .text(
                """
                Tool "\(call.name)" was not executed: the model hit its length \
                limit mid-response, so the call's arguments are truncated.
                """)
            ],
            isError: true
          )
        )
      )
    }
  }

  /// Every tool call `message` requested, in content-block order.
  func toolCalls(in message: AssistantMessage) -> [(
    id: String, name: String, argumentsJSON: String
  )] {
    message.content.compactMap { block in
      if case .toolCall(let id, let name, let argumentsJSON) = block {
        return (id, name, argumentsJSON)
      }
      return nil
    }
  }

  /// Extension point: transforms conversation history into the context
  /// sent to the provider ("convert to LLM form, filtering UI-only
  /// entries" per `LOOP-2`). `ApusKitCore` has no UI-only entry kinds yet
  /// (those arrive with the session layer), so this is the identity
  /// transform in M0.
  func transformContext(_ history: [LLMRequestMessage]) -> [LLMRequestMessage] {
    history
  }

  /// Extension point called after tool execution, before the inner loop
  /// requests another turn. No-op in M0.
  func prepareNextTurn() {}

  /// Whether the inner loop should stop after this turn's tool calls have
  /// been executed, rather than requesting another turn. `LOOP-2` evaluates
  /// this last; `LOOP-1` has already established that tool calls remained.
  /// No-op stop in M0 — the loop continues while tool calls keep arriving.
  func shouldStopAfterTurn(_ message: AssistantMessage) -> Bool {
    false
  }

  /// Converts a caught error into a final `AssistantMessage` (`LOOP-3`),
  /// wrapping it in `AgentError` on the way.
  func finalMessage(for error: any Error) -> AssistantMessage {
    // LOOP-6: an aborted run ends in `.aborted`, whether the failure
    // surfaced as `CancellationError` or as whatever error the provider
    // reported on its way down.
    if error is CancellationError || Task.isCancelled {
      return AssistantMessage(
        content: [], stopReason: .aborted, usage: Usage(inputTokens: 0, outputTokens: 0))
    }

    let description = (error as? StreamError)?.message ?? "\(error)"
    let agentError = AgentError(code: .providerStream, message: description)
    return AssistantMessage(
      content: [.text(agentError.message)],
      stopReason: .error,
      usage: Usage(inputTokens: 0, outputTokens: 0)
    )
  }
}
