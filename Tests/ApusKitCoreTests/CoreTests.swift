// ApusKitCoreTests
//
// Codable round-trip and equality coverage for every ApusKitCore type.

import ApusKitCore
import Foundation
import Testing

/// Encodes `value`, decodes it back, and asserts both round-trip equality
/// and the original equality contract.
private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
  let data = try JSONEncoder().encode(value)
  let decoded = try JSONDecoder().decode(T.self, from: data)
  #expect(decoded == value)
}

@Suite("ContentBlock")
struct ContentBlockTests {
  @Test("text round-trips")
  func textRoundTrips() throws {
    try assertRoundTrips(ContentBlock.text("hello"))
  }

  @Test("image round-trips")
  func imageRoundTrips() throws {
    let block = ContentBlock.image(data: Data([0x01, 0x02, 0x03]), mimeType: "image/png")
    try assertRoundTrips(block)
  }

  @Test("thinking round-trips")
  func thinkingRoundTrips() throws {
    try assertRoundTrips(ContentBlock.thinking("reasoning..."))
  }

  @Test("toolCall round-trips")
  func toolCallRoundTrips() throws {
    let block = ContentBlock.toolCall(
      id: "call_1",
      name: "search",
      argumentsJSON: "{\"q\":\"swift\"}"
    )
    try assertRoundTrips(block)
  }

  @Test("distinct cases are not equal")
  func distinctCasesNotEqual() {
    #expect(ContentBlock.text("a") != ContentBlock.text("b"))
    #expect(ContentBlock.text("a") != ContentBlock.thinking("a"))
  }
}

@Suite("StopReason")
struct StopReasonTests {
  @Test(
    "every case round-trips",
    arguments: [
      StopReason.endTurn, .toolUse, .length, .aborted, .error,
    ]
  )
  func caseRoundTrips(_ reason: StopReason) throws {
    try assertRoundTrips(reason)
  }
}

@Suite("Usage")
struct UsageTests {
  @Test("round-trips and preserves fields")
  func roundTrips() throws {
    let usage = Usage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 10, cacheWriteTokens: 5)
    try assertRoundTrips(usage)
  }

  @Test("cost is computed from pricing, not hardcoded")
  func costIsComputedFromPricing() {
    let usage = Usage(
      inputTokens: 1_000_000,
      outputTokens: 1_000_000,
      cacheReadTokens: 1_000_000,
      cacheWriteTokens: 1_000_000
    )
    let pricing = Pricing(
      inputPerMillion: 3,
      outputPerMillion: 15,
      cacheReadPerMillion: 0.3,
      cacheWritePerMillion: 3.75
    )
    // Hoisted into a typed constant rather than written inline. As
    // `#expect(usage.cost(at: pricing) == 3 + 15 + 0.3 + 3.75)` the four
    // untyped literals leave the type checker enumerating numeric overloads
    // inside the macro expansion: Swift 6.3 copes, Swift 6.2 -- the version
    // `Package.swift` declares and CI runs -- gives up with "unable to
    // type-check this expression in reasonable time" and fails the build.
    // One term per pricing component: input + output + cache read + cache write.
    let expectedCost: Double = 3 + 15 + 0.3 + 3.75
    #expect(usage.cost(at: pricing) == expectedCost)

    let zeroPricing = Pricing(inputPerMillion: 0, outputPerMillion: 0)
    #expect(usage.cost(at: zeroPricing) == 0)
  }
}

@Suite("StreamError")
struct StreamErrorTests {
  @Test(
    "every code round-trips",
    arguments: [
      StreamError.Code.transport, .provider, .decoding, .cancelled,
    ]
  )
  func codeRoundTrips(_ code: StreamError.Code) throws {
    let error = StreamError(code: code, message: "boom")
    try assertRoundTrips(error)
  }
}

@Suite("StreamEvent")
struct StreamEventTests {
  @Test("start round-trips")
  func startRoundTrips() throws {
    try assertRoundTrips(StreamEvent.start)
  }

  @Test("textDelta carries contentIndex and round-trips")
  func textDeltaRoundTrips() throws {
    try assertRoundTrips(StreamEvent.textDelta(contentIndex: 0, text: "hi"))
  }

  @Test("thinkingDelta round-trips")
  func thinkingDeltaRoundTrips() throws {
    try assertRoundTrips(StreamEvent.thinkingDelta(contentIndex: 0, text: "hmm"))
  }

  @Test("toolCallStart carries contentIndex and round-trips")
  func toolCallStartRoundTrips() throws {
    try assertRoundTrips(StreamEvent.toolCallStart(contentIndex: 1, id: "call_1", name: "search"))
  }

  @Test("toolCallDelta round-trips")
  func toolCallDeltaRoundTrips() throws {
    try assertRoundTrips(StreamEvent.toolCallDelta(contentIndex: 1, argumentsJSONDelta: "{\"q\":"))
  }

  @Test("toolCallEnd round-trips")
  func toolCallEndRoundTrips() throws {
    try assertRoundTrips(StreamEvent.toolCallEnd(contentIndex: 1))
  }

  @Test("done round-trips")
  func doneRoundTrips() throws {
    let usage = Usage(inputTokens: 10, outputTokens: 5)
    try assertRoundTrips(StreamEvent.done(usage: usage, stopReason: .endTurn))
  }

  @Test("error round-trips")
  func errorRoundTrips() throws {
    let error = StreamError(code: .transport, message: "connection reset")
    try assertRoundTrips(StreamEvent.error(error))
  }
}

@Suite("Messages")
struct MessagesTests {
  @Test("UserMessage round-trips")
  func userMessageRoundTrips() throws {
    try assertRoundTrips(UserMessage(content: [.text("hello")]))
  }

  @Test("AssistantMessage round-trips")
  func assistantMessageRoundTrips() throws {
    let message = AssistantMessage(
      content: [.text("hi there")],
      stopReason: .endTurn,
      usage: Usage(inputTokens: 10, outputTokens: 5)
    )
    try assertRoundTrips(message)
  }

  @Test("ToolResultMessage round-trips")
  func toolResultMessageRoundTrips() throws {
    let message = ToolResultMessage(toolCallID: "call_1", content: [.text("42")], isError: false)
    try assertRoundTrips(message)
  }

  @Test("ToolResultMessage default isError is false")
  func toolResultMessageDefaultIsError() {
    let message = ToolResultMessage(toolCallID: "call_1", content: [.text("42")])
    #expect(!message.isError)
  }
}
