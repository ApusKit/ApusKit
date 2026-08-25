# ApusKit

**A Swift-native agent harness — a reimplementation of Mario Zechner's pi**

ApusKit is an open-source Swift framework for building AI agents into
Apple-platform apps and command-line tools. It is a faithful Swift
reimplementation of the core of the **pi coding agent**
([earendil-works/pi](https://github.com/earendil-works/pi), MIT) — the same
battle-tested loop semantics and session format — delivered as a modular kit
for the Apple ecosystem.

Consumers inject their own providers through public protocols; the library
never hardcodes a vendor.

## Status

**Current status: 🔨 M1 in progress — **M0 is complete** (2026-08-25): its gate is green in CI — `AgentGateTests/multiTurnToolRoundTrip` round-trips a scripted multi-turn conversation through a fake tool, including the return leg, in [Tests run 32883395354](https://github.com/ApusKit/ApusKit/actions/runs/32883395354) (165 tests, 28 suites on Swift 6.2). All five §7 workflows — Tests, TSan, Docs, Format and Consumer simulation — are green, including the Tests matrix's nightly-toolchain leg as of [run 32887225558](https://github.com/ApusKit/ApusKit/actions/runs/32887225558): `swift-snapshot-testing` was dropped for plain `#expect` (TEST-4, PKG-5), which removed the AppKit/UIKit surface a text-only assertion never needed and with it the only thing breaking that leg. M1's wire-format foundation (the `ApusKitWireFormat` target, the incremental SSE parser, the partial-JSON accumulator, and the default `URLSessionTransport`) is landed, as are its three built-in `APIImplementation`s — `anthropic-messages` (including `cache_control` prompt-caching passthrough via `LLMRequest.cacheBreakpoints`, `docs/proposals/0002`), `openai-completions`, `openai-responses` (F1.1) — plus the built-in provider catalog (`ModelProvider.anthropic`/`.openAI`/`.google`/`.openRouter`/`.groq`/`.ollama`), `ProviderRegistry` resolution to a streaming `ProviderConnection`, and per-request usage/cost accounting via `Usage.cost(at:)` (F1.4); typed tools (F2.1–F2.4, `docs/proposals/0003`) are also in place — `AnyAgentTool` validates a tool call's arguments against its `Schemable`-derived JSON Schema before executing it and turns a schema violation or a thrown tool failure into an error `ToolResult` instead of a crash (TOOL-1, TOOL-2), oversized tool output is head-truncated at 2000 lines / 50 KB with an offset/limit continuation helper (`headTruncate`, TRUNC-1), tools report progress and observe cancellation against the real `Agent` (F2.4), and a provider-neutral `ToolDefinition` carries a request's tools through the `LLMRequest.tools` field, which all three built-in adapters render on the wire, each omitting the `tools` key entirely when a request carries none (R5). M1's own gate stays open: it needs a live smoke against Anthropic and OpenAI and a consumer-injected custom-endpoint provider (F1.2), which needs credentials, so M1 is not flipped (PROG-2).**

**M2 Sessions (F3.1, F3.3, F3.4) is also substantially landed (2026-08-26): the `ApusKitSessions` target ships as its own library target and product, depending only on `ApusKitCore` and `ApusKitWireFormat` (`PKG-6`) — `EntryID`, `SessionHeader`, `SessionEntry`/`SessionEntryKind`/`SessionMessage`, and `SessionFileCodec` give a session file its pi-v3 wire shape, layered on `ApusKitWireFormat`'s new `JSONLCodec` line-splitting kernel, which completes `WIRE-2`'s three-kernel fuzz trio (`docs/ci-deferrals.md`); `Session` is an in-memory branching tree where `append(_:)` alone does both branching and forking, and `buildContext(leaf:)` rebuilds a leaf's context, substituting a compaction's summary and retained tail at the first compaction entry the walk meets (F3.1); `Compaction` ports pi's iterative-summarization algorithm — the normative 16 384-token reserve and 20 000-token retained budget, and a self-contained `retainedTail` that never strands an unanswered tool call — as `shouldCompact`/`cutPoint`/`compact` (F3.3); and storage is pluggable behind the conformable `SessionStore` protocol (`ACC-2`), with `JSONLFileSessionStore` as the built-in file-backed implementation and an in-memory `InMemorySessionStore` test fake (F3.4). The public API family is proposed in `docs/proposals/0004-session-tree-and-store.md`, and a standalone `Examples/consumers/sessions-consumer` proves the target builds with exactly one ApusKit product dependency (DOC-3). A `Tests/Fixtures/sessions/pi-v3-session.jsonl` fixture, authored from pi's public v3 format rather than a real pi session file (none is available under a settled licence — see `SessionConformanceTests.swift`'s own provenance comment), exercises `SessionFileCodec`/`Session`/`buildContext(leaf:)` end to end. M2's own gate stays open: `SESS-1`/F3.2 requires a *real* pi v3 session file to replay, which the authored fixture cannot stand in for, so M2 is not flipped (PROG-2).**

Legend: ⬜ planned · 🔨 in progress · ✅ done

| Milestone | Status | Gate evidence |
|---|---|---|
| M0 Skeleton | ✅ | [Tests run 32883395354](https://github.com/ApusKit/ApusKit/actions/runs/32883395354) — `multiTurnToolRoundTrip` green, 165 tests / 28 suites (2026-08-25) |
| M1 Real streaming | 🔨 | — |
| M2 Sessions | 🔨 | — |
| M3 Public 0.1.0 | ⬜ | — |
| M4 MCP | ⬜ | — |
| M5 Workflows | ⬜ | — |
| M6 Hardening → 1.0 | ⬜ | — |

See `PRD.md` §5 for the single source of truth on project state, and
`TRD.md` for the technical design this implementation follows.

## License

MIT. See `LICENSE`. Portions ported from pi are copyright Mario Zechner /
earendil-works (MIT).
