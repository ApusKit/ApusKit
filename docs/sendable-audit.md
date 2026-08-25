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
| `JSONLDecodeError` | struct (`Error`) | explicit |
| `JSONLDecodeError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `JSONLDecodeResult` | struct | explicit |
| `JSONLCodec` | enum (no cases — static namespace) | implicit (a case-less enum has nothing to check, so `Sendable` derives with no stored state to require it) |

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
| `ToolUpdate` | struct | explicit |
| `TruncatedText` | struct | explicit |

## ApusKitSessions

| Type | Kind | Sendable |
|---|---|---|
| `EntryIDError` | struct (`Error`) | explicit |
| `EntryIDError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `EntryID` | struct | explicit (also `Hashable`, `Codable`) |
| `SessionHeader` | struct | explicit (also `Codable`, `Equatable`) |
| `SessionMessage` | enum (`@nonexhaustive(warn)`) | explicit (also `Codable`, `Equatable`) |
| `SessionEntryKind` | enum (`@nonexhaustive(warn)`) | explicit (also `Codable`, `Equatable`) |
| `SessionEntry` | struct | explicit (also `Codable`, `Equatable`) |
| `SessionFileDecodeError` | struct (`Error`) | explicit |
| `SessionFileDecodeError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `SessionFileDecodeResult` | struct | explicit |
| `SessionFileCodec` | enum (no cases — static namespace) | implicit (a case-less enum has nothing to check, so `Sendable` derives with no stored state to require it) |
| `SessionTreeError` | struct (`Error`) | explicit |
| `SessionTreeError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `Session` | struct | explicit |
| `ContextItem` | enum | explicit |
| `CompactionError` | struct (`Error`) | explicit |
| `CompactionError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `CompactionSummary` | struct | explicit |
| `Compaction` | enum (no cases — static namespace) | implicit (a case-less enum has nothing to check, so `Sendable` derives with no stored state to require it) |
| `Compaction.CutPoint` | struct | explicit |
| `SessionStoreError` | struct (`Error`) | explicit |
| `SessionStoreError.Code` | enum (`@nonexhaustive(warn)`) | explicit |
| `SessionStore` | protocol | explicit (protocol refines `Sendable`) |
| `JSONLFileSessionStore` | struct | implicit (conforms to `SessionStore: Sendable`; its only stored property, `directoryURL: URL`, is `Sendable`) |

`CompactionSummarizer` (a `public typealias` for a `@Sendable` closure
type) is not a nominal type and so has no row of its own — the
`@Sendable` that makes it safe to pass to `Compaction.compact` is
already spelled in the alias itself.

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
rows beyond the six above.
