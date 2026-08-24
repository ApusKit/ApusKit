// ApusKitToolsTests
//
// Coverage for Tool/ToolResult/AnyAgentTool/ToolRegistry, including the
// TOOL-2 error-conversion path.

import ApusKitCore
import ApusKitTools
import JSONSchema
import JSONSchemaBuilder
import Testing

@Schemable
struct EchoArguments: Decodable, Sendable {
  var text: String
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
