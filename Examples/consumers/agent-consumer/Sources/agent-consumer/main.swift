import ApusKitAgent
import ApusKitCore
import ApusKitProviders
import ApusKitTools
import Foundation

// Proves `ApusKitAgent` is usable with `ApusKitAgent` as the package's
// only product dependency. Driving `Agent` for real still needs concrete
// `ApusKitCore`/`ApusKitProviders`/`ApusKitTools` values (a provider, a
// connection, a tool registry) — those modules are part of the build
// graph transitively through `ApusKitAgent` and so remain importable here
// without adding a second product dependency in Package.swift.
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
