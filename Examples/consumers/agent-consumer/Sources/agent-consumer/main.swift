import ApusKitAgent
import ApusKitCore
import ApusKitProviders
import ApusKitTools
import Foundation

// Proves `ApusKitAgent` is usable with `ApusKitAgent` as the package's
// only product dependency — which is what DOC-3 gates. The sibling
// imports above are required, not accidental: `public import` propagates
// API-surface diagnostics but NOT transitive bare-name visibility, so a
// consumer doing real work with `Agent` must still import the modules
// declaring the types it spells. Only the `ApusKit` umbrella's
// `@_exported public import` re-exports transitively — see
// umbrella-consumer for that. Package.swift still declares exactly one
// ApusKit product.
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
  tools: ToolRegistry()
)

let result = await agent.run(UserMessage(content: [.text("hello")]))
print(result.stopReason)
