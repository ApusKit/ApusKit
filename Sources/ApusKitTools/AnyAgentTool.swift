internal import ApusKitCore
internal import Foundation
public import JSONSchema
internal import JSONSchemaBuilder

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

  /// The JSON Schema describing the wrapped tool's `Arguments`, derived
  /// from its `Schemable` conformance (`R1`).
  ///
  /// This is the same schema `execute` validates arguments against
  /// (`TOOL-1`) — expose it to tell a model, provider-neutrally, what
  /// shape a call to this tool must take.
  public let schema: JSONValue

  private let run: @Sendable (String, String, @Sendable (ToolUpdate) -> Void) async -> ToolResult

  /// Wraps `tool`, erasing its concrete `Arguments` type.
  public init<T: Tool>(_ tool: T) {
    self.name = tool.name
    self.description = tool.description
    self.schema = T.Arguments.schema.schemaValue.value
    self.run = { toolCallID, argumentsJSON, onUpdate in
      do {
        // Schema's Sendable conformance is unconfirmed, so the schema is
        // rebuilt here from `T.Arguments.schema` rather than captured as
        // a stored `Schema` value.
        let validation = try T.Arguments.schema.definition().validate(instance: argumentsJSON)
        guard validation.isValid else {
          let reasons = AnyAgentTool.violations(in: validation.errors ?? []).joined(separator: "; ")
          let message =
            reasons.isEmpty ? "arguments do not satisfy the tool's schema" : reasons
          return ToolResult(
            content: [.text("Tool \"\(tool.name)\" received invalid arguments: \(message)")],
            details: ["error": .string(message)],
            isError: true
          )
        }
        let arguments = try JSONDecoder().decode(T.Arguments.self, from: Data(argumentsJSON.utf8))
        let result = try await tool.execute(
          toolCallID: toolCallID,
          arguments: arguments,
          onUpdate: onUpdate
        )
        return AnyAgentTool.truncatingOutput(of: result)
      } catch {
        return ToolResult(
          content: [.text("Tool \"\(tool.name)\" failed: \(error)")],
          details: ["error": .string("\(error)")],
          isError: true
        )
      }
    }
  }

  /// Executes the wrapped tool.
  ///
  /// Per `TOOL-1`, `argumentsJSON` is validated against `schema` before
  /// the wrapped tool ever runs; a violation short-circuits into an error
  /// `ToolResult` naming it. Per `TOOL-2`, this never throws: that
  /// validation failure, argument decoding failure, and any error thrown
  /// from the wrapped tool's `execute` all become an error `ToolResult`
  /// instead of propagating to the caller.
  @concurrent
  public func execute(
    toolCallID: String,
    argumentsJSON: String,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async -> ToolResult {
    await run(toolCallID, argumentsJSON, onUpdate)
  }

  /// Flattens a validation failure into one human-readable line per
  /// violated keyword, so the error `ToolResult` names what was wrong
  /// (`TOOL-1`).
  ///
  /// Nested errors are followed to their leaves: a failing property
  /// reports as the enclosing `"Validation failed for keyword
  /// 'properties'"` whose real cause ("`#/count`: … is below minimum …")
  /// only appears one level down.
  private static func violations(in errors: [ValidationError]) -> [String] {
    errors.flatMap { error -> [String] in
      let nested = violations(in: error.errors ?? [])
      guard nested.isEmpty else { return nested }
      guard !error.message.isEmpty else { return [] }
      let location = error.instanceLocation.description
      return location == "#" ? [error.message] : ["\(location): \(error.message)"]
    }
  }

  /// Head-truncates every text block in `result.content` (`TRUNC-1`),
  /// recording the truncation and each block's original size in
  /// `details` when truncation actually occurred.
  private static func truncatingOutput(of result: ToolResult) -> ToolResult {
    var wasTruncated = false
    var originalLineCount = 0
    var originalByteCount = 0

    let content = result.content.map { block -> ContentBlock in
      guard case .text(let text) = block else { return block }
      let truncated = headTruncate(text)
      guard truncated.isTruncated else { return block }
      wasTruncated = true
      originalLineCount += truncated.originalLineCount
      originalByteCount += truncated.originalByteCount
      return .text(truncated.text)
    }

    guard wasTruncated else { return result }

    var details = result.details
    details["truncated"] = .boolean(true)
    details["originalLineCount"] = .integer(originalLineCount)
    details["originalByteCount"] = .integer(originalByteCount)
    return ToolResult(
      content: content, details: details, isError: result.isError, terminate: result.terminate)
  }
}
