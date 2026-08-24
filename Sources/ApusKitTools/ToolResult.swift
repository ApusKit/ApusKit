public import ApusKitCore
public import JSONSchema

/// The outcome of executing a tool call.
///
/// There is no separate boolean "did this fail" field: per `TOOL-2`, a
/// thrown error is converted into a `ToolResult` whose `details` carries
/// an `"error"` entry describing the failure (see `AnyAgentTool`), so
/// success and failure share the same shape the agent loop already knows
/// how to forward to the model.
public struct ToolResult: Sendable, Equatable {
  /// The result content, rendered as content blocks the model can read.
  public var content: [ContentBlock]

  /// Structured, non-visible metadata about this result.
  public var details: [String: JSONValue]

  /// Whether this result should end the current batch of parallel tool
  /// calls (`LOOP-7`), even if other calls in the batch are still running.
  public var terminate: Bool

  /// Creates a tool result.
  public init(content: [ContentBlock], details: [String: JSONValue] = [:], terminate: Bool = false)
  {
    self.content = content
    self.details = details
    self.terminate = terminate
  }
}
