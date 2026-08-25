# Code maps

Last reviewed: 2026-08-25
Source of truth: `Sources`, `Tests`

Where code actually lives at M0. Only paths that exist today appear in backticks; planned
targets are named in plain text with the milestone that creates them.

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

Planned targets, absent today: ApusKitSessions (M2), ApusKitMCP (M4),
ApusKitWorkflows (M5), plus the Evals, Benchmarks and Examples/apuskit-cli trees. TRD §1 has the
full intended layout — do not treat its absence here as drift.

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
| Model catalog & registry | `Sources/ApusKitProviders/ModelProvider.swift`, `Sources/ApusKitProviders/ProviderRegistry.swift` | `Tests/ApusKitProvidersTests/ProvidersTests.swift` | `ProviderRegistry` is a value type with `mutating` registration |
| Tool protocol & erasure | `Sources/ApusKitTools/Tool.swift`, `Sources/ApusKitTools/AnyAgentTool.swift` | `Tests/ApusKitToolsTests/ToolsTests.swift` | `AnyAgentTool` is where a thrown error becomes an error `ToolResult` (TOOL-2) |
| Tool registry & results | `Sources/ApusKitTools/ToolRegistry.swift`, `Sources/ApusKitTools/ToolResult.swift`, `Sources/ApusKitTools/ToolSupport.swift` | `Tests/ApusKitToolsTests/ToolsTests.swift` | Registry is sealed — populate the value, don't conform |
| Agent actor | `Sources/ApusKitAgent/Agent.swift` | `Tests/ApusKitAgentTests/AgentTests.swift` | Holds history, follow-up queue, running task, event continuation |
| Run loop | `Sources/ApusKitAgent/RunLoop.swift` | `Tests/ApusKitAgentTests/AgentTests.swift` | 289 lines, every LOOP-n rule cited inline. The densest file in the repo |
| Agent events & errors | `Sources/ApusKitAgent/AgentEvent.swift`, `Sources/ApusKitAgent/AgentError.swift` | `Tests/ApusKitAgentTests/AgentTests.swift` | `AgentError` follows ERR-2: struct + `@nonexhaustive` `Code` |

## Test fakes — check here before writing a new one

All in `Tests/Shared/TestSupport.swift`, all `public`, injected through public seams (TEST-2 —
never URLProtocol stubbing):

| Fake | Kind | Use it for |
|---|---|---|
| `RecordingTool` | actor | asserting a tool ran, and with what arguments |
| `ThrowingTool` | struct | TOOL-2 — a thrown error becoming an error result |
| `ConcurrencyProbe` / `ConcurrencyProbeTool` | actor / struct | LOOP-7 — proving tool calls overlap |
| `FollowUpGate` / `GateTool` | actor / struct | LOOP-1 — holding a turn open while a message is queued |
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

`swift test` (94 tests / 17 suites). For one test see `commands.md` — the filter syntax has
a trap.

## Open questions

See `open-questions.md`.
