# Sendable audit

Every public type across ApusKit's targets (CC-3), and how it
gets its `Sendable` conformance. "Explicit" means the declaration itself
lists `Sendable`; "implicit" means it is `Sendable` without saying so —
an `actor` (always `Sendable`), or a struct whose declaration conforms to
a `Sendable`-refining protocol and whose stored properties are all
`Sendable`, so the compiler derives the conformance.

This audit freezes at M6, per TRD §8 ("freeze Sendable audit (CC-3)").
Until then, update this table in the same PR that adds or changes a
public type.

## ApusKitCore

| Type | Kind | Sendable |
|---|---|---|
| `UserMessage` | struct | explicit |
| `AssistantMessage` | struct | explicit |
| `ToolResultMessage` | struct | explicit |
| `ContentBlock` | enum | explicit |
| `StopReason` | enum (`@nonexhaustive(warn)`) | explicit |
| `StreamError` | struct (`Error`) | explicit |
| `StreamError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `StreamEvent` | enum (`@nonexhaustive(warn)`) | explicit |
| `Usage` | struct | explicit |
| `Pricing` | struct | explicit |

## ApusKitWireFormat

| Type | Kind | Sendable |
|---|---|---|
| `SSEEvent` | struct | explicit |
| `SSEParseError` | struct (`Error`) | explicit |
| `SSEParseError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `SSEParser` | struct | explicit |
| `PartialJSONAccumulator` | struct | explicit |

## ApusKitProviders

| Type | Kind | Sendable |
|---|---|---|
| `APIImplementationID` | struct | explicit |
| `LLMRequestMessage` | enum | explicit |
| `LLMRequest` | struct | explicit |
| `ToolDefinition` | struct | explicit |
| `ProviderConnection` | struct | explicit |
| `APIImplementation` | protocol | explicit (protocol refines `Sendable`) |
| `ModelInfo` | struct | explicit |
| `ModelProvider` | struct | explicit |
| `ProviderAuth` | enum | explicit |
| `ProviderRegistry` | struct | explicit |
| `ProviderRegistryError` | struct (`Error`) | explicit |
| `ProviderRegistryError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `ScriptedProvider` | struct | implicit (conforms to `APIImplementation: Sendable`; both stored properties — `APIImplementationID` and a private `actor` script cursor — are `Sendable`) |
| `AnthropicMessagesAPI` | struct | implicit (conforms to `APIImplementation: Sendable`; its only stored property, `APIImplementationID`, is `Sendable`) |
| `OpenAICompletionsAPI` | struct | implicit (conforms to `APIImplementation: Sendable`; its only stored property, `APIImplementationID`, is `Sendable`) |
| `OpenAIResponsesAPI` | struct | implicit (conforms to `APIImplementation: Sendable`; its only stored property, `APIImplementationID`, is `Sendable`) |
| `HTTPStreamRequest` | struct | explicit |
| `HTTPStreamChunk` | struct | explicit |
| `StreamingHTTPTransport` | protocol | explicit (protocol refines `Sendable`) |
| `URLSessionTransport` | struct | implicit (conforms to `StreamingHTTPTransport: Sendable`; its only stored property, `URLSession`, is `Sendable`) |

## ApusKitTools

| Type | Kind | Sendable |
|---|---|---|
| `Tool` | protocol | explicit (protocol refines `Sendable`) |
| `AnyAgentTool` | struct | explicit (now also exposes a public `schema: JSONValue`, derived the same way `execute` validates arguments against it) |
| `ToolRegistry` | struct | explicit |
| `ToolResult` | struct | explicit |
| `ToolCancellationSignal` | struct | explicit |
| `ToolUpdate` | struct | explicit |
| `TruncatedText` | struct | explicit |

## ApusKitAgent

| Type | Kind | Sendable |
|---|---|---|
| `Agent` | actor | implicit (actors are always `Sendable`) |
| `AgentError` | struct (`Error`) | explicit |
| `AgentError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `AgentEvent` | enum (deliberately exhaustive, not `@nonexhaustive`) | explicit |

## ApusKit

The umbrella target declares no types of its own — `Exports.swift` is
`@_exported public import` statements only (TRD §3.9), so it adds no
rows beyond the five above.
