// ToolDefinitionTests
//
// Proves `ToolDefinition` is Equatable and that `LLMRequest.tools`
// defaults to empty so every existing caller stays source-compatible
// (R4).

import ApusKitProviders
import Foundation
import JSONSchema
import Testing

@Suite("ToolDefinition")
struct ToolDefinitionTests {
  @Test("LLMRequest.tools defaults to empty")
  func toolsDefaultsToEmpty() {
    let request = LLMRequest(model: "claude-3-5-sonnet-20241022", messages: [])

    #expect(request.tools == [])
  }

  @Test("equal name, description, and parameters compare equal")
  func equatableWhenFieldsMatch() {
    let lhs = ToolDefinition(
      name: "get_weather",
      description: "Look up the current weather for a city.",
      parameters: .object(["type": .string("object")])
    )
    let rhs = ToolDefinition(
      name: "get_weather",
      description: "Look up the current weather for a city.",
      parameters: .object(["type": .string("object")])
    )

    #expect(lhs == rhs)
  }

  @Test("a differing parameters schema compares unequal")
  func inequalWhenParametersDiffer() {
    let lhs = ToolDefinition(
      name: "get_weather",
      description: "Look up the current weather for a city.",
      parameters: .object(["type": .string("object")])
    )
    let rhs = ToolDefinition(
      name: "get_weather",
      description: "Look up the current weather for a city.",
      parameters: .object(["type": .string("string")])
    )

    #expect(lhs != rhs)
  }

  @Test("LLMRequest.tools round-trips a provided list")
  func toolsRoundTrips() {
    let tool = ToolDefinition(
      name: "get_weather",
      description: "Look up the current weather for a city.",
      parameters: .object(["type": .string("object")])
    )
    let request = LLMRequest(
      model: "claude-3-5-sonnet-20241022",
      messages: [],
      tools: [tool]
    )

    #expect(request.tools == [tool])
  }
}

@Suite("APIImplementationID")
struct APIImplementationIDTests {
  @Test("encodes as a bare string, not a keyed object")
  func encodesAsBareString() throws {
    let encoded = try JSONEncoder().encode(APIImplementationID.anthropicMessages)

    // `RawRepresentable` gives single-value Codable synthesis. Without it,
    // the synthesized form is `{"rawValue":"anthropic-messages"}` — a shape
    // nobody wants persisted, and CORE-2 makes it expensive to change once
    // M2 starts writing session files.
    #expect(String(decoding: encoded, as: UTF8.self) == "\"anthropic-messages\"")
  }

  @Test("round-trips through its raw value")
  func roundTripsThroughRawValue() throws {
    let encoded = try JSONEncoder().encode(APIImplementationID.openAIResponses)
    let decoded = try JSONDecoder().decode(APIImplementationID.self, from: encoded)

    #expect(decoded == .openAIResponses)
    #expect(decoded.rawValue == "openai-responses")
  }
}
