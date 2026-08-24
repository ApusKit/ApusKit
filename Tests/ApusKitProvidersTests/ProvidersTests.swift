// ApusKitProvidersTests
//
// Coverage for the provider seams, the registry, and PROV-1/PROV-3
// guarantees via ScriptedProvider.

import ApusKitCore
import ApusKitProviders
import Foundation
import Testing

/// A connection good enough to hand to `ScriptedProvider`, which ignores
/// it entirely.
private func unusedConnection() -> ProviderConnection {
  // Force-unwrap justified: "https://example.invalid" is a fixed, valid URL literal.
  // swift-format-ignore: NeverForceUnwrap
  let baseURL = URL(string: "https://example.invalid")!
  return ProviderConnection(
    baseURL: baseURL,
    auth: .none,
    transport: NeverCalledTransport()
  )
}

/// A `StreamingHTTPTransport` that fails the test if it is ever called —
/// `ScriptedProvider` must never touch the network.
private struct NeverCalledTransport: StreamingHTTPTransport {
  func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, any Error> {
    Issue.record("StreamingHTTPTransport must not be invoked by ScriptedProvider")
    return AsyncThrowingStream { $0.finish() }
  }
}

/// Collects every event a stream yields, in order.
private func collect(_ stream: AsyncThrowingStream<StreamEvent, any Error>) async throws
  -> [StreamEvent]
{
  var events: [StreamEvent] = []
  for try await event in stream {
    events.append(event)
  }
  return events
}

@Suite("ScriptedProvider")
struct ScriptedProviderTests {
  @Test("replays events in order for a single turn")
  func replaysEventsInOrder() async throws {
    let script: [StreamEvent] = [
      .start,
      .textDelta(contentIndex: 0, text: "hi"),
      .done(usage: Usage(inputTokens: 1, outputTokens: 1), stopReason: .endTurn),
    ]
    let provider = ScriptedProvider(scripts: [script])
    let request = LLMRequest(model: "test-model", messages: [])

    let events = try await collect(
      provider.stream(request: request, connection: unusedConnection()))

    #expect(events == script)
  }

  @Test("PROV-1: exactly one start first and one terminal event last")
  func satisfiesProv1Ordering() async throws {
    let script: [StreamEvent] = [
      .start,
      .toolCallStart(contentIndex: 0, id: "call_1", name: "search"),
      .toolCallDelta(contentIndex: 0, argumentsJSONDelta: "{}"),
      .toolCallEnd(contentIndex: 0),
      .done(usage: Usage(inputTokens: 1, outputTokens: 1), stopReason: .toolUse),
    ]
    let provider = ScriptedProvider(scripts: [script])
    let request = LLMRequest(model: "test-model", messages: [])

    let events = try await collect(
      provider.stream(request: request, connection: unusedConnection()))

    #expect(events.first == .start)
    guard case .done = events.last else {
      Issue.record(
        "expected the last event to be a terminal .done, got \(String(describing: events.last))")
      return
    }
    #expect(
      events.filter {
        if case .start = $0 { return true }; return false
      }.count == 1)

    for event in events {
      switch event {
      case .toolCallStart(let contentIndex, _, _),
        .toolCallDelta(let contentIndex, _),
        .toolCallEnd(let contentIndex):
        #expect(contentIndex == 0)
      default:
        break
      }
    }
  }

  @Test("replays one sequence per successive call, so multi-turn works")
  func replaysOneSequencePerCall() async throws {
    let firstTurn: [StreamEvent] = [
      .start,
      .toolCallStart(contentIndex: 0, id: "call_1", name: "search"),
      .toolCallEnd(contentIndex: 0),
      .done(usage: Usage(inputTokens: 1, outputTokens: 1), stopReason: .toolUse),
    ]
    let secondTurn: [StreamEvent] = [
      .start,
      .textDelta(contentIndex: 0, text: "done"),
      .done(usage: Usage(inputTokens: 1, outputTokens: 2), stopReason: .endTurn),
    ]
    let provider = ScriptedProvider(scripts: [firstTurn, secondTurn])
    let request = LLMRequest(model: "test-model", messages: [])

    let first = try await collect(provider.stream(request: request, connection: unusedConnection()))
    let second = try await collect(
      provider.stream(request: request, connection: unusedConnection()))

    #expect(first == firstTurn)
    #expect(second == secondTurn)
  }

  @Test("throws once every scripted turn has been consumed")
  func throwsWhenScriptExhausted() async throws {
    let provider = ScriptedProvider(scripts: [
      [.start, .done(usage: Usage(inputTokens: 1, outputTokens: 1), stopReason: .endTurn)]
    ])
    let request = LLMRequest(model: "test-model", messages: [])

    _ = try await collect(provider.stream(request: request, connection: unusedConnection()))

    await #expect(throws: (any Error).self) {
      _ = try await collect(provider.stream(request: request, connection: unusedConnection()))
    }
  }

  @Test("reports the .scripted id by default")
  func reportsDefaultID() {
    let provider = ScriptedProvider(scripts: [])
    #expect(provider.id == .scripted)
  }
}

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
  @Test("registers and looks up a ModelProvider by id")
  func registersModelProvider() {
    var registry = ProviderRegistry()
    // Force-unwrap justified: "https://example.invalid" is a fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://example.invalid")!
    let provider = ModelProvider(
      id: "custom",
      baseURL: baseURL,
      api: .openAICompletions,
      auth: .bearer("token"),
      models: [
        ModelInfo(
          id: "test-model", contextWindow: 128_000,
          pricing: Pricing(inputPerMillion: 1, outputPerMillion: 2))
      ]
    )

    registry.register(provider)

    #expect(registry.provider(id: "custom")?.id == "custom")
    #expect(registry.provider(id: "missing") == nil)
  }

  @Test("registers and looks up an APIImplementation by id")
  func registersAPIImplementation() {
    var registry = ProviderRegistry()
    let provider = ScriptedProvider(scripts: [])

    registry.register(provider)

    #expect(registry.implementation(id: .scripted)?.id == .scripted)
    #expect(registry.implementation(id: .anthropicMessages) == nil)
  }
}

@Suite("Usage cost via ModelInfo pricing")
struct ProviderCostTests {
  @Test("PROV-3: cost is derived from ModelInfo pricing, never hardcoded")
  func costDerivesFromModelInfoPricing() {
    let model = ModelInfo(
      id: "test-model",
      contextWindow: 128_000,
      pricing: Pricing(inputPerMillion: 5, outputPerMillion: 10)
    )
    let usage = Usage(inputTokens: 1_000_000, outputTokens: 1_000_000)

    #expect(usage.cost(at: model.pricing) == 15)
  }
}
