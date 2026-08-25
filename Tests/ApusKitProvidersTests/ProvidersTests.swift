// ApusKitProvidersTests
//
// Coverage for the provider seams, the registry, and PROV-1/PROV-3
// guarantees via ScriptedProvider.

import ApusKitCore
import ApusKitProviders
import Foundation
import TestSupport
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

  @Test("replays a PROV-1-shaped script with its ordering and contentIndex intact")
  func replaysProv1ShapedScriptFaithfully() async throws {
    // Scope, stated honestly: ScriptedProvider is a pure replayer and
    // validates nothing, so this asserts REPLAY FIDELITY for a script that
    // is already PROV-1-shaped — it cannot prove PROV-1 conformance of a
    // provider in general. PROV-1's substantive clause, that the
    // accumulator survives argument JSON split across arbitrary chunk
    // boundaries, is pinned end-to-end against the real agent loop in
    // ApusKitAgentTests ("argument JSON split across chunk boundaries is
    // accumulated intact"), because in M0 the accumulator lives there.
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

    registry.register(provider: provider)

    #expect(registry.provider(id: "custom")?.id == "custom")
    #expect(registry.provider(id: "missing") == nil)
  }

  @Test("registers and looks up an APIImplementation by id")
  func registersAPIImplementation() {
    var registry = ProviderRegistry()
    let implementation = ScriptedProvider(scripts: [])

    registry.register(implementation: implementation)

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
    // Asymmetric on BOTH axes on purpose: with equal token counts, or
    // equal rates, a cost function that transposes the input and output
    // rates produces the identical total and the test never notices.
    let usage = Usage(inputTokens: 3_000_000, outputTokens: 1_000_000)

    #expect(usage.cost(at: model.pricing) == 25)

    // Transposing the rates must change the answer, or the assertion above
    // is not actually pinning which rate applies to which token count.
    let transposed = Pricing(inputPerMillion: 10, outputPerMillion: 5)
    #expect(usage.cost(at: transposed) == 35)
  }
}

/// Streams one turn for `model` through the real `APIImplementation`
/// named by `provider.api` and returns the URL the transport was actually
/// asked to POST to.
private func postedURL(for provider: ModelProvider, model: String) async throws -> String {
  var registry = ProviderRegistry()
  registry.register(provider: provider)
  registry.register(implementation: AnthropicMessagesAPI())
  registry.register(implementation: OpenAICompletionsAPI())
  registry.register(implementation: OpenAIResponsesAPI())

  let log = RequestSpyLog()
  let resolved = try registry.resolve(
    model: model, transport: FixtureTransport(body: Data(), log: log))
  let stream = resolved.implementation.stream(
    request: LLMRequest(model: model, messages: []), connection: resolved.connection)
  for try await _ in stream {}

  let requests = await log.requests
  let request = try #require(requests.first)
  return request.url.absoluteString
}

@Suite("Built-in provider catalog (R4)")
struct ProviderCatalogTests {
  @Test("anthropic() speaks anthropic-messages, authenticates with an API key, and lists models")
  func anthropicFactory() {
    let provider = ModelProvider.anthropic(apiKey: "test-key")

    #expect(provider.id == "anthropic")
    #expect(provider.api == .anthropicMessages)
    #expect(provider.auth == .apiKey("test-key"))
    #expect(!provider.models.isEmpty)
    for model in provider.models {
      #expect(model.contextWindow > 0)
    }
  }

  @Test("openAI() speaks openai-responses and authenticates with a bearer token")
  func openAIFactory() {
    let provider = ModelProvider.openAI(apiKey: "test-key")

    #expect(provider.id == "openai")
    #expect(provider.api == .openAIResponses)
    #expect(provider.auth == .bearer("test-key"))
    #expect(!provider.models.isEmpty)
  }

  @Test("google(), openRouter(), and groq() all reach their vendor through openai-completions")
  func openAICompatibleFactories() {
    let google = ModelProvider.google(apiKey: "test-key")
    let openRouter = ModelProvider.openRouter(apiKey: "test-key")
    let groq = ModelProvider.groq(apiKey: "test-key")

    for provider in [google, openRouter, groq] {
      #expect(provider.api == .openAICompletions)
      #expect(provider.auth == .bearer("test-key"))
      #expect(!provider.models.isEmpty)
    }
    #expect(google.id == "google")
    #expect(openRouter.id == "openrouter")
    #expect(groq.id == "groq")
  }

  @Test("ollama() defaults to no auth and an overridable base URL")
  func ollamaFactory() throws {
    let provider = ModelProvider.ollama()

    #expect(provider.id == "ollama")
    #expect(provider.api == .openAICompletions)
    #expect(provider.auth == .none)
    #expect(provider.baseURL == ModelProvider.defaultOllamaBaseURL)

    let customURL = try #require(URL(string: "http://example.invalid:1234/v1"))
    let overridden = ModelProvider.ollama(baseURL: customURL)
    #expect(overridden.baseURL == customURL)
  }

  @Test("every ModelProvider and ModelInfo field is overridable after construction")
  func fieldsAreOverridable() {
    // R4: no factory-returned value is opaque — a consumer must be able
    // to override base URL, auth, or the model list before registering.
    var provider = ModelProvider.anthropic(apiKey: "test-key")
    // swift-format-ignore: NeverForceUnwrap
    let customURL = URL(string: "https://proxy.example.invalid")!

    provider.baseURL = customURL
    provider.auth = .none
    provider.models = []

    #expect(provider.baseURL == customURL)
    #expect(provider.auth == .none)
    #expect(provider.models.isEmpty)
  }

  @Test("every catalog baseURL composes into its vendor's real endpoint through its own adapter")
  func catalogBaseURLsComposeIntoRealEndpoints() async throws {
    // A catalog entry is only usable if its `baseURL` lines up with the
    // path its `APIImplementation` appends: `AnthropicMessagesAPI` adds
    // `v1/messages`, the OpenAI-shaped adapters add version-less paths.
    // Asserting the URL actually POSTed catches a doubled (or missing)
    // version segment that no field-by-field check would see.
    let ollamaModel = ModelInfo(
      id: "llama3.2",
      contextWindow: 128_000,
      pricing: Pricing(inputPerMillion: 0, outputPerMillion: 0))
    let cases: [(provider: ModelProvider, model: String, expected: String)] = [
      (
        ModelProvider.anthropic(apiKey: "k"), "claude-sonnet-4-5-20250929",
        "https://api.anthropic.com/v1/messages"
      ),
      (ModelProvider.openAI(apiKey: "k"), "gpt-5", "https://api.openai.com/v1/responses"),
      (
        ModelProvider.google(apiKey: "k"), "gemini-2.5-flash",
        "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
      ),
      (
        ModelProvider.openRouter(apiKey: "k"), "openai/gpt-5",
        "https://openrouter.ai/api/v1/chat/completions"
      ),
      (
        ModelProvider.groq(apiKey: "k"), "llama-3.3-70b-versatile",
        "https://api.groq.com/openai/v1/chat/completions"
      ),
      (
        ModelProvider.ollama(models: [ollamaModel]), "llama3.2",
        "http://localhost:11434/v1/chat/completions"
      ),
    ]

    for testCase in cases {
      let posted = try await postedURL(for: testCase.provider, model: testCase.model)
      #expect(posted == testCase.expected)
    }
  }

  @Test("constructing a catalog provider registers nothing by itself (TRD §0)")
  func catalogConstructionHasNoSideEffect() {
    // The library never invokes these factories itself, and neither does
    // this test: a `ProviderRegistry` populated with nothing else must
    // still fail to resolve a model these factories describe.
    let registry = ProviderRegistry()

    #expect(throws: ProviderRegistryError.self) {
      _ = try registry.resolve(
        model: "claude-sonnet-4-5-20250929", transport: FixtureTransport(body: Data()))
    }
  }
}

@Suite("ProviderRegistry end-to-end resolution (R5)")
struct ProviderRegistryResolutionTests {
  @Test("resolves a registered model to its provider, implementation, and connection")
  func resolvesRegisteredModel() throws {
    var registry = ProviderRegistry()
    let provider = ModelProvider.anthropic(apiKey: "test-key")
    registry.register(provider: provider)
    registry.register(implementation: ScriptedProvider(id: .anthropicMessages, scripts: []))
    let transport = FixtureTransport(body: Data())

    let resolved = try registry.resolve(
      model: "claude-sonnet-4-5-20250929", transport: transport)

    #expect(resolved.provider.id == "anthropic")
    #expect(resolved.implementation.id == .anthropicMessages)
    #expect(resolved.connection.baseURL == provider.baseURL)
    #expect(resolved.connection.auth == provider.auth)
  }

  @Test("throws unknownModel when no registered provider lists the model")
  func throwsUnknownModel() {
    var registry = ProviderRegistry()
    registry.register(provider: ModelProvider.anthropic(apiKey: "test-key"))
    registry.register(implementation: ScriptedProvider(id: .anthropicMessages, scripts: []))

    do {
      _ = try registry.resolve(model: "does-not-exist", transport: FixtureTransport(body: Data()))
      Issue.record("expected resolve(model:transport:) to throw")
    } catch let error as ProviderRegistryError {
      #expect(error.code == .unknownModel)
    } catch {
      Issue.record("expected a ProviderRegistryError, got \(error)")
    }
  }

  @Test(
    "throws unregisteredImplementation when the provider's api has no registered APIImplementation")
  func throwsUnregisteredImplementation() {
    var registry = ProviderRegistry()
    registry.register(provider: ModelProvider.anthropic(apiKey: "test-key"))
    // Deliberately no APIImplementation registered under .anthropicMessages.

    do {
      _ = try registry.resolve(
        model: "claude-sonnet-4-5-20250929", transport: FixtureTransport(body: Data()))
      Issue.record("expected resolve(model:transport:) to throw")
    } catch let error as ProviderRegistryError {
      #expect(error.code == .unregisteredImplementation)
    } catch {
      Issue.record("expected a ProviderRegistryError, got \(error)")
    }
  }
}

@Suite("ProviderRegistry cost accounting (PROV-3/R6)")
struct ProviderRegistryCostTests {
  @Test("cost(of:model:) derives from the resolved catalog entry's own Pricing")
  func costUsesResolvedCatalogPricing() throws {
    var registry = ProviderRegistry()
    let provider = ModelProvider.anthropic(apiKey: "test-key")
    registry.register(provider: provider)
    let modelID = "claude-sonnet-4-5-20250929"
    let info = try #require(provider.models.first { $0.id == modelID })
    // Asymmetric on both axes so a cost function transposing input/output,
    // or read/write cache rates, cannot pass by accident.
    let usage = Usage(
      inputTokens: 2_000_000, outputTokens: 1_000_000,
      cacheReadTokens: 500_000, cacheWriteTokens: 100_000)

    let cost = try registry.cost(of: usage, model: modelID)

    // Pinned against Core's own cost formula, so a `ProviderRegistry.cost`
    // that hardcoded a rate instead of reading `ModelInfo.pricing` fails
    // this even though it never touches `Usage.cost(at:)` at all.
    #expect(cost == usage.cost(at: info.pricing))
    #expect(cost != usage.cost(at: Pricing(inputPerMillion: 1, outputPerMillion: 1)))
  }

  @Test("cost(of:model:) throws unknownModel for an unregistered model")
  func costThrowsForUnknownModel() {
    let registry = ProviderRegistry()

    #expect(throws: ProviderRegistryError.self) {
      _ = try registry.cost(of: Usage(inputTokens: 1, outputTokens: 1), model: "missing")
    }
  }
}
