// CustomProviderInjectionTests
//
// The permanent PROV-4 loop-level integration test (TRD:131, TRD:306): a
// consumer-defined `ModelProvider` speaking the built-in `openai-completions`
// wire protocol, registered and resolved through public API only, streams a
// real multi-turn tool round-trip through the actual `Agent` actor — never
// an adapter tested in isolation. No `@testable` import anywhere in this
// file: everything exercised here is what a library consumer could write.

import ApusKitAgent
import ApusKitCore
import ApusKitProviders
import ApusKitTools
import Foundation
import JSONSchemaBuilder
import TestSupport
import Testing

/// A tool matching the `get_weather` calls recorded in the
/// `openai-completions` fixture transcripts: `{"location": "..."}`.
///
/// An actor so recorded calls can be inspected safely after the agent loop
/// has run it, without locks (`CC-4`).
private actor WeatherTool: Tool {
  /// The arguments `WeatherTool` decodes its calls into.
  @Schemable
  struct Arguments: Decodable, Sendable, Equatable {
    var location: String

    init(location: String) {
      self.location = location
    }
  }

  nonisolated let name = "get_weather"
  nonisolated let description = "Looks up the weather for a location."

  /// Every call this tool has received, in order.
  private(set) var recordedCalls: [Arguments] = []

  func execute(
    toolCallID: String,
    arguments: Arguments,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    recordedCalls.append(arguments)
    return ToolResult(content: [.text("72F and sunny")])
  }
}

/// Records each `HTTPStreamRequest` this transport is asked to perform and
/// its position in the replay order.
///
/// An actor rather than a lock-protected variable, per `CC-4`.
private actor SequencedFixtureState {
  private(set) var requests: [HTTPStreamRequest] = []
  private var nextIndex = 0

  func recordAndAdvance(_ request: HTTPStreamRequest) -> Int {
    requests.append(request)
    defer { nextIndex += 1 }
    return nextIndex
  }
}

/// A `StreamingHTTPTransport` that replays one fixture transcript per call,
/// in order — the multi-turn analog of `FixtureTransport`, which replays a
/// single fixed body from every call. `Agent`'s inner loop calls
/// `stream(request:connection:)` once per provider turn, so a tool-call
/// turn followed by a final-text turn needs two distinct transcripts
/// delivered in sequence.
private struct SequencedFixtureTransport: StreamingHTTPTransport {
  private let transcripts: [Data]
  private let state: SequencedFixtureState

  init(transcripts: [Data], state: SequencedFixtureState) {
    self.transcripts = transcripts
    self.state = state
  }

  func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, any Error> {
    let transcripts = transcripts
    let state = state
    return AsyncThrowingStream { continuation in
      let task = Task {
        let index = await state.recordAndAdvance(request)
        guard index < transcripts.count else {
          continuation.finish(
            throwing: StreamError(
              code: .transport,
              message: "SequencedFixtureTransport has no more scripted turns to replay."))
          return
        }
        continuation.yield(HTTPStreamChunk(data: transcripts[index]))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

@Suite("PROV-4: custom provider injection drives the real Agent loop")
struct CustomProviderInjectionTests {
  @Test(
    """
    a consumer-defined ModelProvider(id: "custom", api: .openAICompletions) completes a \
    multi-turn tool round-trip through the real Agent over FixtureTransport
    """
  )
  func customProviderMultiTurnToolRoundTrip() async throws {
    let toolCallTranscript = try Fixtures.transcript("tool-call.sse", for: "openai-completions")
    let textOnlyTranscript = try Fixtures.transcript("text-only.sse", for: "openai-completions")

    let state = SequencedFixtureState()
    let transport = SequencedFixtureTransport(
      transcripts: [toolCallTranscript, textOnlyTranscript], state: state)

    // Force-unwrap justified: "https://custom-provider.example/v1" is a
    // fixed, valid URL literal.
    // swift-format-ignore: NeverForceUnwrap
    let baseURL = URL(string: "https://custom-provider.example/v1")!

    // A consumer-defined provider under a consumer-chosen id, speaking a
    // built-in wire protocol — never one of the library's own catalog
    // factories (PROV-4: TRD §0 "never hardcodes a vendor").
    var registry = ProviderRegistry()
    registry.register(
      ModelProvider(
        id: "custom",
        baseURL: baseURL,
        api: .openAICompletions,
        auth: .bearer("test-token"),
        models: [
          ModelInfo(
            id: "custom-model",
            contextWindow: 128_000,
            pricing: Pricing(inputPerMillion: 1, outputPerMillion: 2)
          )
        ]
      )
    )
    registry.register(OpenAICompletionsAPI())

    let resolved = try registry.resolve(model: "custom-model", transport: transport)

    var tools = ToolRegistry()
    let weatherTool = WeatherTool()
    tools.register(weatherTool)

    let agent = Agent(
      apiImplementation: resolved.implementation,
      connection: resolved.connection,
      model: "custom-model",
      tools: tools
    )

    let final = await agent.run(UserMessage(content: [.text("What's the weather in SF?")]))

    // The RETURN leg of the round-trip: the loop ran a second turn after
    // the tool executed, and that turn's text is the final message.
    #expect(final.stopReason == .endTurn)
    #expect(final.content == [.text("Hello, world!")])

    let calls = await weatherTool.recordedCalls
    #expect(calls == [WeatherTool.Arguments(location: "SF")])

    // Two provider turns went out on the wire: the tool-call turn and the
    // follow-up turn, both through the same resolved connection.
    let requests = await state.requests
    #expect(requests.count == 2)
    for request in requests {
      #expect(request.url == baseURL.appendingPathComponent("chat/completions"))
      #expect(request.headers["Authorization"] == "Bearer test-token")
    }
  }
}
