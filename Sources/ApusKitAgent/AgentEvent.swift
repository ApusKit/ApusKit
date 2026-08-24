public import ApusKitCore
public import ApusKitTools

/// A notification produced by `Agent`'s run loop as it drives a
/// conversation forward.
///
/// Not wire-facing — this is an in-process observation stream, not a
/// persisted format — so unlike `StreamEvent`/`StopReason` it is a plain
/// (exhaustive) public enum.
public enum AgentEvent: Sendable, Equatable {
  /// A run has started processing its queued messages.
  case agentStart

  /// A run has finished; carries the last final assistant message produced.
  case agentEnd(AssistantMessage)

  /// A new turn (one provider request/response cycle, plus any tool
  /// execution it triggers) has started.
  case turnStart

  /// A turn has finished; carries the assistant message it produced.
  case turnEnd(AssistantMessage)

  /// The provider has started streaming a new assistant message.
  case messageStart

  /// A raw event from the provider's stream, forwarded for consumers that
  /// want live deltas.
  case messageUpdate(StreamEvent)

  /// The assistant message finished streaming; carries the complete message.
  case messageEnd(AssistantMessage)

  /// A tool call has started executing.
  case toolExecutionStart(toolCallID: String, name: String)

  /// A tool reported progress before finishing.
  case toolExecutionUpdate(toolCallID: String, update: ToolUpdate)

  /// A tool call finished; carries its result.
  case toolExecutionEnd(toolCallID: String, result: ToolResult)
}
