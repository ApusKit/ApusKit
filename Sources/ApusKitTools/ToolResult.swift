public import ApusKitCore
public import JSONSchema

/// The outcome of executing a tool call.
///
/// Success and failure share one shape, because the agent loop forwards
/// both to the model the same way (`TOOL-2`): a failing tool produces a
/// result the model can read and react to, never a thrown error.
public struct ToolResult: Sendable, Equatable {
  /// The result content, rendered as content blocks the model can read.
  public var content: [ContentBlock]

  /// Structured, non-visible metadata about this result.
  ///
  /// Purely descriptive. Nothing in the loop keys behaviour off a
  /// particular entry here — whether this result is a failure is
  /// `isError`, and only `isError`.
  public var details: [String: JSONValue]

  /// Whether this result represents a failure.
  ///
  /// Forwarded verbatim to `ToolResultMessage.isError`, so it is what the
  /// model sees. `AnyAgentTool` sets it when argument validation fails or
  /// the wrapped tool throws (`TOOL-1`, `TOOL-2`); a tool that completes
  /// but wants to report failure sets it itself.
  public var isError: Bool

  /// Whether this result should end the current batch of parallel tool
  /// calls (`LOOP-7`), even if other calls in the batch are still running.
  public var terminate: Bool

  /// Creates a tool result.
  public init(
    content: [ContentBlock],
    details: [String: JSONValue] = [:],
    isError: Bool = false,
    terminate: Bool = false
  ) {
    self.content = content
    self.details = details
    self.isError = isError
    self.terminate = terminate
  }
}
