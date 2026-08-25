import ApusKitTools
import JSONSchemaBuilder

// Proves `ApusKitTools` is usable with no other ApusKit target imported.
@Schemable
struct EchoArguments: Decodable, Sendable {
  var value: String
}

struct EchoTool: Tool {
  let name = "echo"
  let description = "Echoes its input."

  func execute(
    toolCallID: String,
    arguments: EchoArguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    ToolResult(content: [.text(arguments.value)])
  }
}

var registry = ToolRegistry()
registry.register(EchoTool())
print(registry.allTools.map(\.name))
