import ApusKit
import Foundation
import JSONSchemaBuilder

// Proves the `ApusKit` umbrella re-exports every target through a single
// `import ApusKit` (Exports.swift's `@_exported public import`s).
// `JSONSchemaBuilder` is imported separately for `@Schemable`: the
// umbrella re-exports ApusKit's own four targets, not their third-party
// dependencies.
struct NeverCalledTransport: StreamingHTTPTransport {
  func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, any Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

// swift-format-ignore: NeverForceUnwrap
let baseURL = URL(string: "https://example.invalid")!

let provider = ScriptedProvider(
  scripts: [
    [.start, .done(usage: Usage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)]
  ]
)

var tools = ToolRegistry()
tools.register(AnyAgentTool(EchoTool()))

let agent = Agent(
  apiImplementation: provider,
  connection: ProviderConnection(baseURL: baseURL, auth: .none, transport: NeverCalledTransport()),
  model: "example-model",
  pricing: Pricing(inputPerMillion: 1, outputPerMillion: 2),
  tools: tools
)

let result = await agent.run(UserMessage(content: [.text("hello")]))
print(result.stopReason)

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
