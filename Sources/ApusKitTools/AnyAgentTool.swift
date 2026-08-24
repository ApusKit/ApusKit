internal import ApusKitCore
internal import Foundation
internal import JSONSchema

/// Type-erases a `Tool`, decoding its arguments from a JSON string and
/// converting any thrown error into an error `ToolResult`, so the agent
/// loop can invoke every registered tool through one uniform interface.
///
/// Sealed — construct one from a concrete `Tool` via `init(_:)` rather
/// than trying to conform to `AnyAgentTool` itself.
public struct AnyAgentTool: Sendable {
  /// The wrapped tool's name.
  public let name: String

  /// The wrapped tool's description.
  public let description: String

  private let run:
    @Sendable (String, String, ToolCancellationSignal, @Sendable (ToolUpdate) -> Void) async ->
      ToolResult

  /// Wraps `tool`, erasing its concrete `Arguments` type.
  public init<T: Tool>(_ tool: T) {
    self.name = tool.name
    self.description = tool.description
    self.run = { toolCallID, argumentsJSON, signal, onUpdate in
      do {
        let arguments = try JSONDecoder().decode(T.Arguments.self, from: Data(argumentsJSON.utf8))
        return try await tool.execute(
          toolCallID: toolCallID,
          arguments: arguments,
          signal: signal,
          onUpdate: onUpdate
        )
      } catch {
        return ToolResult(
          content: [.text("Tool \"\(tool.name)\" failed: \(error)")],
          details: ["error": .string("\(error)")]
        )
      }
    }
  }

  /// Executes the wrapped tool.
  ///
  /// Per `TOOL-2`, this never throws: argument decoding failure and any
  /// error thrown from the wrapped tool's `execute` both become an error
  /// `ToolResult` instead of propagating to the caller.
  @concurrent
  public func execute(
    toolCallID: String,
    argumentsJSON: String,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async -> ToolResult {
    await run(toolCallID, argumentsJSON, signal, onUpdate)
  }
}
