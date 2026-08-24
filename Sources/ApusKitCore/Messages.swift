/// A message from the user, sent to the model.
public struct UserMessage: Sendable, Codable, Equatable {
  /// The content blocks that make up this message.
  public var content: [ContentBlock]

  /// Creates a user message.
  public init(content: [ContentBlock]) {
    self.content = content
  }
}

/// A message produced by the model, possibly across many streamed
/// content blocks and possibly requesting tool calls.
public struct AssistantMessage: Sendable, Codable, Equatable {
  /// The content blocks the model produced, in order.
  public var content: [ContentBlock]

  /// Why the model stopped producing this message.
  public var stopReason: StopReason

  /// Token usage for the turn that produced this message.
  public var usage: Usage

  /// Creates an assistant message.
  public init(content: [ContentBlock], stopReason: StopReason, usage: Usage) {
    self.content = content
    self.stopReason = stopReason
    self.usage = usage
  }
}

/// The result of executing a tool call, sent back to the model.
public struct ToolResultMessage: Sendable, Codable, Equatable {
  /// The `id` of the `ContentBlock.toolCall` this message answers.
  public var toolCallID: String

  /// The result content, rendered as content blocks the model can read.
  public var content: [ContentBlock]

  /// Whether the tool execution failed.
  public var isError: Bool

  /// Creates a tool result message.
  public init(toolCallID: String, content: [ContentBlock], isError: Bool = false) {
    self.toolCallID = toolCallID
    self.content = content
    self.isError = isError
  }
}
