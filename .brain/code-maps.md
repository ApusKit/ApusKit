# Code maps

Last reviewed: 2026-08-26
Source of truth: `Sources`, `Tests`

Where code actually lives after M1's typed-tools slice. Only paths that exist today appear in
backticks; planned targets are named in plain text with the milestone that creates them.

## Summary

- Six source targets, ~2040 lines of production Swift total — the tree is small enough to read
  end to end, and this page exists so you usually don't have to.
- The test suite is larger than the sources (~2330 lines): `Tests/Shared` alone is 575 lines of
  fakes, and it is the first place to look before writing a new one.
- One test target per source target, named `<Target>Tests`, all depending on the shared
  `TestSupport` library target — except `ApusKitWireFormatTests`, which depends only on
  `ApusKitWireFormat`: the kernels need no fakes.

## Subsystem map

| Subsystem | Path | Holds |
|---|---|---|
| Core | `Sources/ApusKitCore` | Message/event/usage value types. No I/O, no networking, no reflection |
| Wire format | `Sources/ApusKitWireFormat` | The two incremental parse kernels. The only target where typed `throws` is allowed (WIRE-1) and the nightly fuzz target (WIRE-2) |
| Providers | `Sources/ApusKitProviders` | `APIImplementation`, transport seam + `URLSessionTransport`, model catalog, registry, `ScriptedProvider` |
| Tools | `Sources/ApusKitTools` | `Tool` protocol, type erasure, registry, results |
| Agent | `Sources/ApusKitAgent` | The `Agent` actor and the pi-ported run loop |
| Umbrella | `Sources/ApusKit` | Five `@_exported public import` lines. No logic |
| Test fakes | `Tests/Shared` | The `TestSupport` target — every fake, shared by the four test targets that need one |
| Consumers | `Examples/consumers` | Seven one-product packages proving each target stands alone |

Replace the stale "planned targets" paragraph with:

```
Planned targets, absent today: ApusKitMCP (M4), ApusKitWorkflows (M5), plus the Evals, Benchmarks
and Examples/apuskit-cli trees. TRD §1 has the full intended layout — do not treat its absence here
as drift.
```

And correct the counts that moved with it: **seven** source targets (≈5 120 lines by `wc -l`, tests
≈6 540 with `Tests/Shared` at ≈890); the umbrella is **six** `@_exported public import` lines; the
`TestSupport` target is shared by **five** test targets (`ApusKitWireFormatTests` is still the only
one that does not depend on it).

Add to the subsystem map:

```
| Sessions | `Sources/ApusKitSessions` | pi-v3 JSONL session tree: entries, branching, leaf-to-root context rebuild, compaction, `SessionStore` |
```

Add to the feature map:

```
| JSONL kernel | `Sources/ApusKitWireFormat/JSONLCodec.swift` | `Tests/ApusKitWireFormatTests/JSONLCodecTests.swift` | `JSONLCodec.decode(_:)` / `.encode(_:)`. `JSONLDecodeResult.trailing` hands back the bytes after the last terminator (`:36`), so an unterminated final line is data, not an error |
| Session entry model | `Sources/ApusKitSessions/SessionEntry.swift`, `Sources/ApusKitSessions/EntryID.swift`, `Sources/ApusKitSessions/SessionHeader.swift` | `Tests/ApusKitSessionsTests/SessionCodecTests.swift` | pi v3 wire shape — `SessionHeader.currentVersion == 3`. `EntryID` is a validated hex string; `random(using:)` takes an injected generator (DI-1) |
| Session file codec | `Sources/ApusKitSessions/SessionFileCodec.swift` | `Tests/ApusKitSessionsTests/SessionCodecTests.swift` | `encode(header:entries:)` / `decode(_:)` over `JSONLCodec`; `SessionFileDecodeResult.trailing` carries an unterminated final line back to the caller |
| Session tree | `Sources/ApusKitSessions/Session.swift` | `Tests/ApusKitSessionsTests/SessionTreeTests.swift` | Branch and fork are both just `append(_:)` with an existing id as `parentID` — nothing is ever rewritten. `history(from:)` is **leaf-to-root** (`:102`); `leaves()` / `children(of:)` are append-ordered (API-4) |
| Context rebuild | `Sources/ApusKitSessions/ContextRebuild.swift` | `Tests/ApusKitSessionsTests/ContextRebuildTests.swift` | `buildContext(leaf:)` stops at the compaction nearest the leaf — `firstIndex` over a leaf-to-root array (`:32`) — and substitutes `summary` + `retainedTail`. `Session(header:entries:)` has no test: see `gotchas.md` |
| Compaction | `Sources/ApusKitSessions/Compaction.swift` | `Tests/ApusKitSessionsTests/CompactionTests.swift` | Oldest-first input, unlike the tree walks. `defaultReserve` 16 384 and `defaultRetainedTokens` 20 000 are normative pi numbers, not knobs. The summarizer is an injected `@Sendable` closure (`CompactionSummarizer`), so the target never imports `ApusKitProviders` (PKG-6) and ACC-2's conformable set is not widened. The token counter is the second closure seam (`CompactionTokenCounter`): `compactIfNeeded` counts each message once and reuses those counts for both trigger and cut; the `tokenCounts:` functions remain the pure kernel it delegates to |
| Session store | `Sources/ApusKitSessions/SessionStore.swift`, `Sources/ApusKitSessions/JSONLFileSessionStore.swift` | `Tests/ApusKitSessionsTests/SessionStoreTests.swift` | `SessionStore` is client-conformable (ACC-2). The file store is `public import Foundation` — `URL` is on its public surface, so DEP-2's `internal import` does not apply. `appendEntry` opens `FileHandle(forUpdating:)`, not `forWritingTo:`, because a write-only handle cannot read the last byte back to detect a missing `LF` (`:61`) |
```

Add to the fakes table:

```
| `InMemorySessionStore` | actor | a `SessionStore` with no filesystem (`Tests/Shared/InMemorySessionStore.swift`) |
```

## Feature map

| Feature | Key files | Tests | Notes |
|---|---|---|---|
| Message & content model | `Sources/ApusKitCore/Messages.swift`, `Sources/ApusKitCore/ContentBlock.swift` | `Tests/ApusKitCoreTests/CoreTests.swift` | `ContentBlock.image` is raw `Data` + MIME string; there is deliberately no URL case |
| Stream events & errors | `Sources/ApusKitCore/StreamEvent.swift`, `Sources/ApusKitCore/StreamError.swift`, `Sources/ApusKitCore/StopReason.swift` | `Tests/ApusKitCoreTests/CoreTests.swift` | Wire-facing enums are `@nonexhaustive(warn)` until M6 (ENUM-1) |
| Usage & cost | `Sources/ApusKitCore/Usage.swift` | `Tests/ApusKitCoreTests/CoreTests.swift` | Core owns `Pricing`; cost derives from `ModelInfo`, never hardcoded (PROV-3) |
| Provider protocol & request shape | `Sources/ApusKitProviders/APIImplementation.swift` | `Tests/ApusKitProvidersTests/ProvidersTests.swift` | `LLMRequest`, `LLMRequestMessage`, `ProviderConnection`, `APIImplementationID` all live here |
| Deterministic provider | `Sources/ApusKitProviders/ScriptedProvider.swift` | `Tests/ApusKitProvidersTests/ProvidersTests.swift` | The only provider at M0. Drives every loop test with zero network |
| Transport seam | `Sources/ApusKitProviders/StreamingHTTPTransport.swift` | — | Protocol + `HTTPStreamRequest`/`HTTPStreamChunk`. `method` defaults to `"POST"` — a GET-only fixture answers 501 |
| Incremental SSE parser | `Sources/ApusKitWireFormat/SSEParser.swift` | `Tests/ApusKitWireFormatTests/SSEParserTests.swift` | `struct` with `mutating func feed(_:) throws(SSEParseError) -> [SSEEvent]`. Accepts LF, CRLF and bare CR; a trailing bare CR is held back (see `gotchas.md`). Lines are retired by offset and the buffer drained once per call — per-line `removeFirst` made it quadratic |
| Partial-JSON accumulator | `Sources/ApusKitWireFormat/PartialJSON.swift` | `Tests/ApusKitWireFormatTests/PartialJSONTests.swift` | `PartialJSONAccumulator.append(_:)` / `snapshot() -> String`. Defines no JSON value type — decoding is the caller's job, since `JSONValue` is swift-json-schema's and PKG-6 puts it out of reach |
| Default HTTP transport | `Sources/ApusKitProviders/URLSessionTransport.swift` | `Tests/ApusKitProvidersTests/URLSessionTransportTests.swift` | Yields **one `HTTPStreamChunk` per byte** on purpose — `URLSession.AsyncBytes` cannot report "nothing more buffered", so coalescing needs a size threshold (stalls slow bodies) or an injected clock. `Data` stores a 1-byte payload inline |
| Anthropic wire adapter | `Sources/ApusKitProviders/AnthropicMessagesAPI.swift` | `Tests/ApusKitProvidersTests/AnthropicMessagesAPITests.swift` | `POST <baseURL>/v1/messages` — the adapter appends the whole `v1/messages` path itself. The only adapter that gates tool-call deltas through a repair buffer (`:419`), so its deltas are *not* verbatim wire fragments |
| OpenAI Chat Completions adapter | `Sources/ApusKitProviders/OpenAICompletionsAPI.swift` | `Tests/ApusKitProvidersTests/OpenAICompletionsAPITests.swift` | `POST <baseURL>/chat/completions` with `stream_options.include_usage`; `[DONE]` sentinel and index-keyed `tool_calls`. Works unchanged against any OpenAI-compatible baseURL |
| OpenAI Responses adapter | `Sources/ApusKitProviders/OpenAIResponsesAPI.swift` | `Tests/ApusKitProvidersTests/OpenAIResponsesAPITests.swift` | `POST <baseURL>/responses`; named SSE event types (`response.output_item.added`, `response.function_call_arguments.delta`, …). Forwards argument deltas verbatim |
| Built-in provider catalog | `Sources/ApusKitProviders/ProviderCatalog.swift` | `Tests/ApusKitProvidersTests/ProvidersTests.swift` | Six opt-in factories — `ModelProvider.anthropic`/`.openAI`/`.google`/`.openRouter`/`.groq`/`.ollama` (`:29`–`:160`). Nothing in `Sources` calls one: a vendor exists only once a consumer invokes a factory and registers the result (TRD §0) |
| Registry resolution & cost | `Sources/ApusKitProviders/ProviderRegistry.swift` | `Tests/ApusKitProvidersTests/ProvidersTests.swift` | `resolve(model:transport:)` returns provider + implementation + `ProviderConnection` (`:78`); `cost(of:model:)` derives from `ModelInfo.pricing` via `Usage.cost(at:)` (`:103`, PROV-3). Failures are `ProviderRegistryError` + `@nonexhaustive` `Code` (ERR-2, `:9`). Still a value type with `mutating` registration |
| Wire fixtures | `Tests/Fixtures` | — | Ten `.sse` transcripts in three per-implementation directories, plus `conformance-baseline.yml` — which nothing reads (see `gotchas.md`) |
| Tool protocol & erasure | `Sources/ApusKitTools/Tool.swift`, `Sources/ApusKitTools/AnyAgentTool.swift` | `Tests/ApusKitToolsTests/ToolsTests.swift` | `AnyAgentTool` is where a thrown error becomes an error `ToolResult` (TOOL-2) |
| Typed tool schema & validation | `Sources/ApusKitTools/AnyAgentTool.swift` | `Tests/ApusKitToolsTests/ToolsTests.swift` | `schema` is `T.Arguments.schema.schemaValue.value` captured once at `init` (`:35`) — a `JSONValue`, cheap; validation rebuilds `definition()` fresh inside the closure on every call (`:41`) because `Schema`'s `Sendable` conformance is unconfirmed. TOOL-1 violations short-circuit before `execute`, flattened to leaf messages (`:94`) |
| Output truncation | `Sources/ApusKitTools/Truncation.swift` | `Tests/ApusKitToolsTests/TruncationTests.swift` | `headTruncate(_:offset:limit:maxBytes:) -> TruncatedText`, defaults 2000 lines / 50 000 bytes (TRUNC-1). The byte cap ends on a **line** boundary and reports `linesReturned`, which is the continuation step — not `limit` (see `gotchas.md`). Applied per text block to **every** result — success and error alike — in `AnyAgentTool.execute`, the one call every registered tool passes through; `truncatingOutput` records `truncated`/`originalLineCount`/`originalByteCount` in `details` |
| Provider-neutral tool definitions | `Sources/ApusKitProviders/ToolDefinition.swift` | `Tests/ApusKitProvidersTests/ToolDefinitionTests.swift` | `ToolDefinition(name:description:parameters:)` with `parameters: JSONValue`; `LLMRequest.tools` defaults `[]` (`APIImplementation.swift:74`, `:82`). The in-module `JSONValue.jsonSerializationValue` (`:33`) erases to `Any` for the two dict-building adapters |
| Tool definitions on the wire | `Sources/ApusKitProviders/AnthropicMessagesAPI.swift`, `Sources/ApusKitProviders/OpenAICompletionsAPI.swift`, `Sources/ApusKitProviders/OpenAIResponsesAPI.swift` | the three per-adapter suites in `Tests/ApusKitProvidersTests` | All three render `LLMRequest.tools` and omit the key entirely when empty: Anthropic `name`/`description`/`input_schema` (`:106`), Chat Completions nested `{"type":"function","function":{…}}` (`:314`), Responses flat `type`/`name`/`description`/`parameters` (`:141`) |
| Registry → wire tool list | `Sources/ApusKitAgent/RunLoop.swift` | `Tests/ApusKitAgentTests/AgentTests.swift:459` | `:53` maps `ToolRegistry.allTools` into `[ToolDefinition]` **sorted by name** — `allTools` is dictionary-backed (`ToolRegistry.swift:26`), so an unsorted mapping makes the tools sent upstream flap from turn to turn |
| Tool registry & results | `Sources/ApusKitTools/ToolRegistry.swift`, `Sources/ApusKitTools/ToolResult.swift`, `Sources/ApusKitTools/ToolSupport.swift` | `Tests/ApusKitToolsTests/ToolsTests.swift` | Registry is sealed — populate the value, don't conform |
| Agent actor | `Sources/ApusKitAgent/Agent.swift` | `Tests/ApusKitAgentTests/AgentTests.swift` | Holds history, follow-up queue, running task, event continuation |
| Run loop | `Sources/ApusKitAgent/RunLoop.swift` | `Tests/ApusKitAgentTests/AgentTests.swift` | 289 lines, every LOOP-n rule cited inline. The densest file in the repo |
| Agent events & errors | `Sources/ApusKitAgent/AgentEvent.swift`, `Sources/ApusKitAgent/AgentError.swift` | `Tests/ApusKitAgentTests/AgentTests.swift` | `AgentError` follows ERR-2: struct + `@nonexhaustive` `Code` |

## Test fakes — check here before writing a new one

In `Tests/Shared/TestSupport.swift` and `Tests/Shared/FixtureTransport.swift`, all `public`,
injected through public seams (TEST-2 — never URLProtocol stubbing):

| `Fixtures` | enum | loading a recorded transcript from `Tests/Fixtures` by file name + implementation directory (`FixtureTransport.swift:17`) |
| `FixtureTransport` | struct | replaying a transcript through the transport seam — whole, or pre-split at a byte offset for the PROV-1 chunk-boundary sweep. `init(failing:)` (`:82`) records the request then fails the stream, so the transport-failure path needs no new fake |
| `RequestSpyLog` | actor | asserting the URL, headers and JSON body an adapter actually POSTed (`FixtureTransport.swift:117`) |

`FixtureTransport` replays the **same** bytes on every `stream(_:)` call
(`Tests/Shared/FixtureTransport.swift:100`), so it cannot represent a multi-turn conversation —
the loop calls `stream` once per turn and would replay turn 1 forever. A multi-turn test needs a
cursor-based fake: `Tests/ApusKitAgentTests/CustomProviderInjectionTests.swift:73` holds a private
`SequencedFixtureTransport` (one transcript per successive call, cursor in an actor per CC-4).
Promote it to `Tests/Shared` the second time someone needs it.

| Fake | Kind | Use it for |
|---|---|---|
| `RecordingTool` | actor | asserting a tool ran, and with what arguments |
| `ThrowingTool` | struct | TOOL-2 — a thrown error becoming an error result |
| `ConcurrencyProbe` / `ConcurrencyProbeTool` | actor / struct | LOOP-7 — proving tool calls overlap |
| `FollowUpGate` / `GateTool` | actor / struct | LOOP-1 — holding a turn open while a message is queued |
| `CancellationObservation` / `CancellationObservingTool` | actor / struct | F2.4 — a tool that reports one `onUpdate`, opens a `FollowUpGate`, then polls `Task.isCancelled` until it observes an abort |
| `HangingProvider` | struct | abort/cancellation paths |
| `RequestRecordingProvider` / `RequestLog` | struct / actor | asserting what the loop sent upstream |
| `ThrowingStreamProvider` | struct | LOOP-3 — stream failure ending as `.error` |
| `ScriptedTurn` | enum | scripting multi-turn conversations |

## Consumer packages

`Examples/consumers` holds seven packages, each declaring **exactly one** ApusKit product (DOC-3):
`core-consumer`, `wireformat-consumer`, `providers-consumer`, `tools-consumer`, `agent-consumer`,
`umbrella-consumer`, and `mainactor-consumer` — the last built with `.defaultIsolation(MainActor.self)` to simulate
an app consumer. See `Examples/consumers/mainactor-consumer/Package.swift`.

## Validation

`swift test` (counts move every run — read the output rather than trusting a number written here). For one test see `commands.md` — the filter syntax has
a trap.

## Open questions

See `open-questions.md`.
