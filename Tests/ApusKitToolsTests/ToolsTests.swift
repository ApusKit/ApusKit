// ApusKitToolsTests
//
// Coverage for Tool/ToolResult/AnyAgentTool/ToolRegistry, including the
// TOOL-2 error-conversion path.

import ApusKitCore
import ApusKitTools
import Foundation
import JSONSchema
import JSONSchemaBuilder
import Testing

@Schemable
struct EchoArguments: Decodable, Sendable {
  var text: String
}

/// Arguments carrying a constraint (`count >= 10`) that only schema
/// validation can catch: `{"count":5}` decodes cleanly through
/// `JSONDecoder`, so a test using it fails unless `TOOL-1` validation
/// actually runs.
@Schemable
struct CountArguments: Decodable, Sendable {
  @NumberOptions(.minimum(10))
  var count: Int
}

/// Tracks whether a tool's `execute` was ever invoked, so a test can
/// prove a schema violation short-circuited before reaching it.
private actor CallTracker {
  private(set) var callCount = 0

  func record() {
    callCount += 1
  }
}

/// A tool whose `execute` records every call it receives via `CallTracker`.
private struct CountingTool: Tool {
  let name = "count"
  let description = "Records that it ran and echoes the count."
  let tracker: CallTracker

  func execute(
    toolCallID: String,
    arguments: CountArguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    await tracker.record()
    return ToolResult(content: [.text("\(arguments.count)")])
  }
}

/// A tool that returns a text block of `lineCount` lines, to exercise
/// `TRUNC-1` truncation of oversized output.
private struct BigOutputTool: Tool {
  let name = "big_output"
  let description = "Returns a text block with the given number of lines."
  let lineCount: Int

  func execute(
    toolCallID: String,
    arguments: EchoArguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    let text = (1...lineCount).map { "line \($0)" }.joined(separator: "\n")
    return ToolResult(content: [.text(text)])
  }
}

/// A tool that always succeeds, echoing its argument back.
private struct EchoTool: Tool {
  let name = "echo"
  let description = "Echoes the given text back."

  func execute(
    toolCallID: String,
    arguments: EchoArguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    ToolResult(content: [.text(arguments.text)])
  }
}

/// A tool that always throws, to exercise TOOL-2 error conversion.
private struct ExplodingTool: Tool {
  let name = "explode"
  let description = "Always throws."

  struct Failure: Error {}

  func execute(
    toolCallID: String,
    arguments: EchoArguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    throw Failure()
  }
}

@Suite("AnyAgentTool")
struct AnyAgentToolTests {
  @Test("decodes JSON arguments and returns the tool's result")
  func decodesArgumentsAndExecutes() async {
    let tool = AnyAgentTool(EchoTool())

    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"text":"hello"}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    #expect(result.content == [.text("hello")])
    #expect(result.details["error"] == nil)
  }

  @Test("TOOL-2: a thrown error becomes an error ToolResult, never a crash")
  func thrownErrorBecomesErrorResult() async {
    let tool = AnyAgentTool(ExplodingTool())

    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"text":"hello"}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    #expect(result.details["error"] != nil)
  }

  @Test("invalid argument JSON becomes an error ToolResult, never a crash")
  func invalidArgumentsBecomeErrorResult() async {
    let tool = AnyAgentTool(EchoTool())

    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: "not json",
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    #expect(result.details["error"] != nil)
  }

  @Test("exposes the wrapped tool's name and description")
  func exposesNameAndDescription() {
    let tool = AnyAgentTool(EchoTool())
    #expect(tool.name == "echo")
    #expect(tool.description == "Echoes the given text back.")
  }

  @Test("R1: exposes the JSON Schema derived from the wrapped tool's Arguments")
  func exposesDerivedSchema() {
    let tool = AnyAgentTool(EchoTool())

    guard case .object(let keywords) = tool.schema else {
      Issue.record("expected an object schema, got \(tool.schema)")
      return
    }
    #expect(keywords["type"] == .string("object"))
    guard case .object(let properties)? = keywords["properties"] else {
      Issue.record("expected a \"properties\" keyword, got \(keywords["properties"] as Any)")
      return
    }
    #expect(properties["text"] != nil)
  }

  @Test("TOOL-1: a schema violation becomes an error ToolResult, and execute is never invoked")
  func schemaViolationNeverReachesExecute() async {
    let tracker = CallTracker()
    let tool = AnyAgentTool(CountingTool(tracker: tracker))

    // `{"count":5}` is well-formed JSON that decodes into CountArguments
    // without complaint; only the derived schema's `minimum` rejects it,
    // so this fails outright if TOOL-1 validation is skipped.
    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"count":5}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    guard case .string(let message)? = result.details["error"] else {
      Issue.record("expected an \"error\" detail, got \(result.details)")
      return
    }
    // The error names the violation, not just "something went wrong":
    // the offending property and the constraint it broke.
    #expect(message.contains("count"))
    #expect(message.contains("minimum"))
    #expect(result.content == [.text("Tool \"count\" received invalid arguments: \(message)")])

    let callCount = await tracker.callCount
    #expect(callCount == 0)
  }

  @Test("TOOL-1: arguments of the wrong JSON type never reach execute either")
  func mistypedArgumentsNeverReachExecute() async {
    let tracker = CallTracker()
    let tool = AnyAgentTool(CountingTool(tracker: tracker))

    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"count":"not-a-number"}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    #expect(result.details["error"] != nil)
    let callCount = await tracker.callCount
    #expect(callCount == 0)
  }

  @Test("TOOL-1: arguments satisfying the schema do reach execute")
  func validArgumentsReachExecute() async {
    let tracker = CallTracker()
    let tool = AnyAgentTool(CountingTool(tracker: tracker))

    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"count":42}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    #expect(result.content == [.text("42")])
    #expect(result.details["error"] == nil)
    let callCount = await tracker.callCount
    #expect(callCount == 1)
  }

  @Test("TRUNC-1: oversized output from execute is head-truncated, original size recorded")
  func oversizedOutputIsTruncated() async {
    let tool = AnyAgentTool(BigOutputTool(lineCount: 2500))

    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"text":"go"}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    guard case .text(let text)? = result.content.first else {
      Issue.record("expected a text content block, got \(result.content)")
      return
    }
    #expect(text.components(separatedBy: "\n").count == 2000)
    #expect(result.details["truncated"] == .boolean(true))
    #expect(result.details["originalLineCount"] == .integer(2500))
    #expect(result.details["error"] == nil)
  }

  @Test("small text output from execute is unaffected by truncation")
  func smallOutputIsNotTruncated() async {
    let tool = AnyAgentTool(EchoTool())

    let result = await tool.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"text":"hello"}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )

    #expect(result.details["truncated"] == nil)
  }

  @Test("the exposed schema and definition() encode the same JSON Schema for Arguments")
  func schemaValueAgreesWithDefinition() throws {
    let viaSchemaProperty = AnyAgentTool(EchoTool()).schema
    let data = try JSONEncoder().encode(EchoArguments.schema.definition())
    let viaDefinition = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(viaSchemaProperty == viaDefinition)
  }
}

@Suite("ToolRegistry")
struct ToolRegistryTests {
  @Test("registers a concrete Tool and looks it up by name")
  func registersConcreteTool() async {
    var registry = ToolRegistry()
    registry.register(EchoTool())

    let tool = registry.tool(named: "echo")
    #expect(tool != nil)

    let result = await tool?.execute(
      toolCallID: "call_1",
      argumentsJSON: #"{"text":"hi"}"#,
      signal: ToolCancellationSignal(),
      onUpdate: { _ in }
    )
    #expect(result?.content == [.text("hi")])
  }

  @Test("returns nil for an unregistered name")
  func returnsNilForUnknownName() {
    let registry = ToolRegistry()
    #expect(registry.tool(named: "missing") == nil)
  }

  @Test("allTools reflects every registered tool")
  func allToolsReflectsRegistrations() {
    var registry = ToolRegistry()
    registry.register(EchoTool())
    registry.register(ExplodingTool())

    #expect(registry.allTools.count == 2)
    #expect(Set(registry.allTools.map(\.name)) == ["echo", "explode"])
  }
}

@Suite("ToolResult")
struct ToolResultTests {
  @Test("default terminate is false")
  func defaultTerminateIsFalse() {
    let result = ToolResult(content: [.text("ok")])
    #expect(!result.terminate)
  }

  @Test("terminate: true is preserved")
  func terminateIsPreserved() {
    let result = ToolResult(content: [.text("stop")], terminate: true)
    #expect(result.terminate)
  }
}
