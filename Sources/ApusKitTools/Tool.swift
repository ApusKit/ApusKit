public import JSONSchemaBuilder

/// A typed capability the model can invoke mid-turn.
///
/// Shaped like Foundation Models' `Tool`, but self-contained — it has no
/// dependency on Foundation Models. Conform freely: `Tool` is the primary
/// extension point for exposing app/host capabilities to the agent loop.
public protocol Tool: Sendable {
  /// The argument type this tool decodes its call into.
  ///
  /// `Schemable` lets `@Schemable`-derived JSON Schema describe the
  /// arguments to the model.
  associatedtype Arguments: Schemable & Decodable & Sendable

  /// The tool's name, as the model will reference it in a `toolCall`.
  var name: String { get }

  /// A description of what the tool does, shown to the model.
  var description: String { get }

  /// Executes one invocation of this tool.
  ///
  /// - Parameters:
  ///   - toolCallID: The id of the `ContentBlock.toolCall` being answered.
  ///   - arguments: The decoded call arguments.
  ///   - onUpdate: Reports progress before the result is ready.
  ///
  /// A thrown error never reaches the agent loop: `AnyAgentTool` converts
  /// it into an error `ToolResult` (`TOOL-2`).
  ///
  /// Cancellation is ordinary structured-concurrency cancellation
  /// (`LOOP-6`): `abort()` cancels the task running this method, so check
  /// `Task.isCancelled` between units of long-running work, or wrap a
  /// suspension in `withTaskCancellationHandler`, and return a partial
  /// `ToolResult`.
  @concurrent
  func execute(
    toolCallID: String,
    arguments: Arguments,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult
}
