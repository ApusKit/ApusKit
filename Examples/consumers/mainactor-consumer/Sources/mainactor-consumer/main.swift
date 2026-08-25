import ApusKit
import Foundation

// Proves `ApusKit` compiles under an app-shaped default isolation
// (`-default-isolation MainActor` + `NonisolatedNonsendingByDefault`),
// simulating a consumer app rather than a library (DOC-3).
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

let agent = Agent(
  apiImplementation: provider,
  connection: ProviderConnection(baseURL: baseURL, auth: .none, transport: NeverCalledTransport()),
  model: "example-model",
  pricing: Pricing(inputPerMillion: 1, outputPerMillion: 2),
  tools: ToolRegistry()
)

let result = await agent.run(UserMessage(content: [.text("hello")]))
print(result.stopReason)
