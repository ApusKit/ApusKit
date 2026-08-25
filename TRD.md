## 0. Technical mission (read once, then build)

ApusKit is an **open-source Swift framework**: a faithful reimplementation of the core of the **pi coding agent** (earendil-works/pi, MIT) — message model, multi-provider streaming LLM layer, typed tool system, agent loop, JSONL session tree, extension hooks — plus an MCP layer (client AND server) and a deterministic multi-agent workflow layer built on top.

Three design principles govern every technical decision:

1. **A pi port, not an invention.** Loop contracts, session wire format and truncation rules are ported 1:1 from pi. Where pi has decided something, we do not re-decide it. We innovate only where Swift requires it (actors, structured concurrency, `AsyncSequence`).
2. **A library-first kit, not just an engine.** Every target is a standalone product usable WITHOUT the agent loop. A consumer may use only the provider layer, only the session codec, or only the MCP server — and that must feel first-class.
3. **A public-API-only extension platform.** Everything above the core (MCP, workflows, any plugin) is built exclusively on the public API surface. ApusKit's own upper targets prove this daily.

Consumers inject their own providers through public protocols; the library never hardcodes a vendor.

## 1. Repository layout (create exactly this)

```
apuskit/
├── Package.swift
├── TRD.md                       // this file
├── PRD.md                       // the paired PRD: capabilities, delivery plan, §5 Progress (single source of truth for state)
├── README.md                    // subtitle: "A Swift-native agent harness — a reimplementation of Mario Zechner's pi"; status section mirrors PRD §5
├── LICENSE                      // MIT + "Portions copyright (c) 2025 Mario Zechner / earendil-works (MIT)" block
├── CONTRIBUTING.md              // core-minimalism rule + "you must understand your code" + DCO
├── CHANGELOG.md                 // Keep-a-Changelog shape, maintainer-curated only
├── SECURITY.md
├── .swift-format
├── .spi.yml
├── .github/workflows/           // §7
├── Sources/
│   ├── ApusKitCore/
│   ├── ApusKitWireFormat/
│   ├── ApusKitProviders/
│   ├── ApusKitTools/
│   ├── ApusKitSessions/
│   ├── ApusKitAgent/
│   ├── ApusKitMCP/              // behind `MCP` trait
│   ├── ApusKitWorkflows/
│   └── ApusKit/                 // umbrella re-export only
├── Tests/
│   ├── <TargetName>Tests/       // one test target per source target
│   ├── Shared/                  // fakes: ScriptedProvider helpers, ToolSpy, FixtureLoader
│   └── Fixtures/                // recorded pi SSE transcripts + real pi v3 session files + conformance-baseline.yml
├── Evals/                       // non-default target: scenario suites driving the REAL loop on ScriptedProvider
├── Benchmarks/                  // package-benchmark target: SSE parse, session rebuild, loop overhead
├── Examples/
│   ├── apuskit-cli/             // reference macOS CLI (ArgumentParser): chat loop + MCP server mode
│   └── consumers/               // one minimal per-target consumer each (compiled by CI, §7)
└── docs/
    └── proposals/               // NNNN-*.md — every new public API family gets a short proposal first
```

## 2. Package manifest rules

- **PKG-1** `swift-tools-version: 6.2`; Swift 6 language mode; `StrictConcurrency` on every target; `treatAllWarnings(as: .error)`.
- **PKG-2** Platforms: `.macOS(.v14)`, `.iOS(.v17)`, `.macCatalyst(.v17)`, `.tvOS(.v17)`, `.visionOS(.v1)`. Nothing else. No Linux CI, but MUST NOT introduce code that would block Linux (see FORB-3/FORB-4).
- **PKG-3** Upcoming features enabled on all targets: `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`.
- **PKG-4** Package **traits**: `NIO` (pulls `async-http-client`, enables the NIO transport backend), `MCP` (pulls `modelcontextprotocol/swift-sdk`, enables `ApusKitMCP`). Default traits: none. Everything else must build with zero traits enabled.
- **PKG-5** Dependencies (exact-pin anything 0.x): `swift-json-schema` (@Schemable), `modelcontextprotocol/swift-sdk` (trait `MCP`), `async-http-client` (trait `NIO`), `swift-argument-parser` (Examples only), `package-benchmark` (Benchmarks only), `swift-docc-plugin`.
- **PKG-6** Dependency DAG (arrows = "may import"; anything not listed is forbidden):

  ```
  Core ← WireFormat ← Providers          Core ← Tools
  Core, WireFormat ← Sessions
  Core, WireFormat, Providers, Tools, Sessions ← Agent
  Agent (+ mcp swift-sdk) ← MCP          Agent ← Workflows
  everything ← ApusKit (umbrella)
  ```

  **No lower target ever imports `ApusKitAgent`. `ApusKitAgent` never imports `ApusKitMCP`/`ApusKitWorkflows`.**
- **PKG-7** Every target is exposed as its own library product; `ApusKit` (umbrella) additionally re-exports all of them.
- **PKG-8** Cross-target internals use the **`package` access level** — never `@_spi`.

## 3. Target specifications

For each target: purpose, public surface (signatures are normative in shape — exact parameter spelling may be refined via `docs/proposals/`), and hard constraints.

### 3.1 ApusKitCore — messages & events (transport-free)

Public types, all `Sendable & Codable & Equatable`:

- Messages: `UserMessage`, `AssistantMessage`, `ToolResultMessage` (+ session-only kinds surfaced in §3.5).
- `ContentBlock`: `text | image | thinking | toolCall` (tool call = id, name, arguments-JSON).
- `StopReason` (`@nonexhaustive`): `endTurn, toolUse, length, aborted, error`.
- `Usage`: input/output/cacheRead/cacheWrite token counts + computed cost.
- `StreamEvent` (`@nonexhaustive`): `start`, `textDelta`, `thinkingDelta`, `toolCallStart/Delta/End` (each carrying `contentIndex`), `done(Usage, StopReason)`, `error`.

Constraints: **CORE-1** no networking imports, no I/O, no reflection. **CORE-2** every type versioned-stable for wire-compat (changing a `Codable` shape is SemVer-major).

### 3.2 ApusKitWireFormat — parse kernels

- Incremental **SSE parser**: feed arbitrary byte chunks, emit complete events; MUST survive event boundaries split anywhere (mid-UTF-8, mid-field).
- **JSONL codec** for session files (encode/decode line-by-line, tolerant of trailing partial line on read).
- **Partial-JSON accumulator**: builds tool-call argument JSON from streamed fragments; MUST produce a best-effort parse at any prefix.
- **WIRE-1** This is the ONLY target where **typed `throws`** is allowed. **WIRE-2** These parsers are the fuzz targets (§7); write them allocation-conscious.

### 3.3 ApusKitProviders — the multi-provider layer

```swift
/// Wire adapter: builds requests, parses the stream into unified events. PUBLIC, conformable.
public protocol APIImplementation: Sendable {
  var id: APIImplementationID { get }        // .anthropicMessages, .openAICompletions, .openAIResponses, ...
  func stream(request: LLMRequest, connection: ProviderConnection)
      -> AsyncThrowingStream<StreamEvent, Error>
}

/// Catalog entry: where/how to reach models. PUBLIC — anyone can inject one.
public struct ModelProvider: Sendable {
  public var id: String                      // "anthropic", "openai", "my-proxy", ...
  public var baseURL: URL
  public var api: APIImplementationID
  public var auth: ProviderAuth              // .apiKey, .bearer, .headers([:]), .none
  public var models: [ModelInfo]             // id, context window, pricing → Usage cost
}

public struct ProviderRegistry: Sendable {   // runtime injection (pi's models.json/registerProvider analog)
  public mutating func register(_ provider: ModelProvider)
  public mutating func register(_ impl: any APIImplementation)
}

/// Transport seam. PUBLIC, conformable.
public protocol StreamingHTTPTransport: Sendable {
  func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, Error>
}
```

- Shipped transports: `URLSessionTransport` (default, zero deps) and, behind trait `NIO`, `AsyncHTTPClientTransport`.
- Built-in API implementations — M1: `anthropic-messages` (incl. `cache_control` prompt-caching passthrough), `openai-completions`, `openai-responses`. Built-in provider catalog: Anthropic, OpenAI, Google, OpenRouter, Groq, Ollama/local (any OpenAI-compatible baseURL).
- `ScriptedProvider` — a deterministic `APIImplementation` playing back scripted event sequences — is **public** and documented (testing is first-class).
- **PROV-1** Event stream guarantees per request: exactly one `start` first; exactly one terminal `done` or `error` last; every `toolCall*` event carries `contentIndex`; the accumulator MUST survive argument JSON split across arbitrary chunk boundaries.
- **PROV-2** Context is provider-neutral: switching provider mid-session MUST work (no provider-specific state in messages).
- **PROV-3** Cost is computed from `ModelInfo` pricing — never hardcoded.
- **PROV-4** Acceptance proof of injectability: a consumer-defined provider `ModelProvider(id:"custom", baseURL: <any URL>, api: .openAICompletions, auth: .bearer(token))` streams through the loop with zero library changes. This exact case is a permanent integration test.

### 3.4 ApusKitTools — typed tools

```swift
/// Shaped like Foundation Models' Tool, but self-contained (no FM dependency).
public protocol Tool: Sendable {
  associatedtype Arguments: Schemable & Decodable & Sendable
  var name: String { get }
  var description: String { get }
  func execute(toolCallID: String, arguments: Arguments,
               onUpdate: @Sendable (ToolUpdate) -> Void) async throws -> ToolResult
}
public struct ToolResult: Sendable { public var content: [ContentBlock]; public var details: [String: JSONValue]; public var isError: Bool; public var terminate: Bool }
```

- JSON Schema derived via `swift-json-schema` `@Schemable`; a type-erased `AnyAgentTool` backs the registry.
- **TOOL-1** Arguments are validated against the schema BEFORE `execute` is called; invalid args become an error `ToolResult`, never a crash.
- **TOOL-2** Errors thrown from `execute` become error `ToolResult`s — a tool can never take the loop down. Failure is carried by `ToolResult.isError` and forwarded to `ToolResultMessage.isError`; `details` is descriptive metadata only, and **nothing in the loop keys behaviour off a `details` entry**.
- **TOOL-4** Cancellation is ordinary structured-concurrency cancellation (`LOOP-6`) — `Task.isCancelled` and `withTaskCancellationHandler` inside `execute`. The library ships no cancellation-token type: Swift already has the concept, and a wrapper around `Task.isCancelled` reports the reading task's state rather than the tool's.
- **TRUNC-1** Output truncation ported 1:1 from pi: head-truncate at **2000 lines or 50 KB, whichever comes first**; continuation supported via offset/limit parameters. Spilling oversized payloads to files is the CONSUMER's job (core stays sandbox-neutral).
- **TOOL-3** No built-in app tools in this target. Reference tools require a `docs/proposals/` entry first.

### 3.5 ApusKitSessions — JSONL tree, pi v3 wire-compatible

- File format: header line + entries; entry `id`/`parentId` are 8-hex → in-place branching, forking, tree walk. Entry types: `message, compaction, branch_summary, custom, custom_message, label, model_change, thinking_level_change`.
- `buildContext(leaf:)` walks leaf→root honoring compaction entries.
- **Compaction** (numbers are normative, ported from pi): trigger when `contextTokens > contextWindow − reserve` (default reserve **16 384**); cut-point keeps ~**20 000** recent tokens; iterative LLM summary + self-contained `retainedTail`.
- `public protocol SessionStore` (conformable); built-in `JSONLFileSessionStore`.
- **SESS-1** Wire-compat is a tested guarantee: a real pi v3 session file loads, rebuilds context equivalently, and round-trips losslessly (fixtures in `Tests/Fixtures/`, deviations only via `conformance-baseline.yml`).

### 3.6 ApusKitAgent — the loop

`Agent` is an **actor** owning: message state, steering + follow-up queues, `makeEventStream(bufferingPolicy:) -> AsyncStream<AgentEvent>` (`agentStart/End, turnStart/End, messageStart/Update/End, toolExecutionStart/Update/End`), `abort()`.

- **EVENT-1** Each call to `makeEventStream` returns an **independent** stream, so a UI, a logger and a session journal (`WF-1`) can observe one agent without competing for events. A single shared stream would let one observer consume what another never sees.
- **EVENT-2** Streams are **bounded by default** (`.bufferingNewest`); an absent or slow consumer must not grow the agent's memory without limit. `.unbounded` is opt-in, for a consumer that cannot lose an event.
- **EVENT-3** A stream spans the **agent's** lifetime, not one run — `run(_:)` may be called repeatedly, and runs are delimited by `.agentStart`/`.agentEnd`. Every stream is finished when the agent is deinitialized, so `for await` always terminates.

`runLoop` semantics — **ported from pi 1:1, normative**:

- **LOOP-1** Two nested loops: inner while tool calls or steering messages exist; outer while the follow-up queue is non-empty.
- **LOOP-2** Per turn: inject steering → `transformContext` → convert to LLM form (filtering UI-only entries) → provider stream → mutate the partial `AssistantMessage` per event → execute tools → `prepareNextTurn` → `shouldStopAfterTurn`.
- **LOOP-3** **Errors never throw out of the loop.** Any failure becomes a final message with `stopReason == .error` (or `.aborted`).
- **LOOP-4** **`stopReason == .length` fails ALL tool calls of that message** — truncated arguments are unsafe to execute.
- **LOOP-5** Steering messages are injected BETWEEN turns, never mid-stream; queue modes `all | oneAtATime`.
- **LOOP-6** Interruption = structured-concurrency cancellation → clean `.aborted` final state. No detached tasks.
- **LOOP-7** Tools execute in parallel by default; a tool may declare a serial `executionMode`; a `ToolResult` with `terminate: true` ends the batch.

**Hook bus** — registration points: `toolCall` (can block/deny), `toolResult` (can modify), `beforeProviderRequest`, `afterProviderResponse`, `sessionBeforeCompact`, `sessionStart`, `sessionShutdown`, `modelSelect`.

**Extension packaging:**

```swift
public protocol AgentExtension: Sendable {
  func install(into context: ExtensionContext) async throws
}
// ExtensionContext exposes: agent handle, tool registry, provider registry,
// session store, hook registration. All PUBLIC API — nothing more.
```

- **EXT-1** Extensions (including `ApusKitMCP` and `ApusKitWorkflows`) consume ONLY public API. If an extension needs an internal, the public API is wrong — fix it via `docs/proposals/`, never via `package`-access leakage.
- **EXT-2** Extensions are compile-time Swift packages. No dynamic code loading anywhere.

### 3.7 ApusKitMCP — MCP client AND server (trait `MCP`)

Bridges to the official `modelcontextprotocol/swift-sdk`.

- **Client**: `MCPToolSource: AgentExtension` — connects to an MCP server, lists tools, bridges each into an ApusKit `Tool` (schema passthrough; results → `ToolResult`; list-changed notifications refresh the registry). Transports: HTTP first; stdio only on macOS and only toward processes the host app may legitimately reach.
- **Server**: `ToolServer` — exposes a tool registry as an MCP server (stdio for CLI hosting, stateless/stateful HTTP for network); plus **agent-as-tool** — expose a whole configured `Agent` as a single MCP tool.
- **MCP-1** SDK types NEVER appear on ApusKit's public API surface — wrap everything. **MCP-2** Pin the SDK to an exact version.

### 3.8 ApusKitWorkflows — deterministic orchestration

- `WorkflowStep` primitives: `run` (one agent task), `parallel` (fan-out), `pipeline` (per-item stages), `judge` (adversarial verify/vote), `gate` (approval via hook). Runner executes on structured concurrency.
- **WF-1** Every step is journaled into the session tree as `custom` entries (auditable, replayable).
- **WF-2** Sub-agents = child `Agent` instances with scoped tool registries and budgets — created here, never in `ApusKitAgent`.
- **WF-3** Each step selects model/provider via the public `ProviderRegistry` — multi-provider per step is a feature, not an accident.
- **WF-4** v0 scope: value-typed workflow description + runner. No persistence, no scheduler, no DSL sugar unless it stays under ~100 LOC.

### 3.9 ApusKit — umbrella

Re-exports every target. Zero logic. Nothing else.

## 4. Coding practices (the law)

### API design
- **API-1** Every `public` declaration has a doc comment; first line is a single-sentence summary.
- **API-2** Naming per swift.org API Design Guidelines: name by role; call sites read as phrases; `sort()`/`sorted()` pairs; protocols are nouns (is-a) or `-able/-ing` (capability); factories are `make*`.
- **API-3** Non-O(1) computed properties document their complexity.

### Concurrency
- **CC-1** Library targets keep **nonisolated default isolation**. Never `-default-isolation MainActor` in library code.
- **CC-2** **Every public async API is explicitly annotated** `@concurrent` (always off-caller) or `nonisolated(nonsending)` (runs on caller's actor). Where code runs is an API contract.
- **CC-3** Maintain `docs/sendable-audit.md`: every public type listed with its `Sendable` status. Adding `@Sendable`/`@MainActor`/Sendable constraints post-release is SemVer-major.
- **CC-4** No locks, no semaphores, no `DispatchQueue`. Actors and `AsyncStream` only. No sync I/O on any actor.

### Errors
- **ERR-1** Public APIs use **untyped `throws`**. Typed throws only inside `ApusKitWireFormat` (WIRE-1).
- **ERR-2** Public error types are **structs with a `@nonexhaustive` `Code` enum** — never monolithic public enums.

### Enums & evolution
- **ENUM-1** Wire-facing enums (`StreamEvent`, `StopReason`, error codes) are `@nonexhaustive(warn)` now → `@nonexhaustive` at 1.0. Consumers write `@unknown default`.
- **EVO-1** A new protocol requirement always ships with a default implementation.
- **EVO-2** Deprecation: `@available(*, deprecated, renamed:/message:)` at least one minor release before removal.

### Access control & conformability
- **ACC-1** Cross-target internals: `package` access (PKG-8).
- **ACC-2** Conformability table — enforce in DocC ("Conform freely" vs "**Do not conform** — sealed"):
  - **Client-conformable:** `APIImplementation`, `Tool`, `SessionStore`, `StreamingHTTPTransport`, `AgentExtension`, hook handler types.
  - **Sealed:** everything else. Sealing preserves the right to add requirements.
- **ACC-3** Every conformable protocol documents its semantic contract in DocC (preconditions, isolation, cancellation, retry) AND has an executable contract in the **Conformance Kit** (§5, TEST-6).

### Dependencies & injection
- **DI-1** Constructor injection of `any APIImplementation` / `any SessionStore` / clock / transport. Zero singletons, zero global mutable state.
- **DI-2** No DI framework dependency.
- **DI-3** No `Date()`, `Task.sleep` against wall-clock, or `URLSession.shared` inside logic — clock and transport are injected.
- **DEP-1** No SwiftNIO and no MCP-SDK types on the public surface — both are fully wrapped (MCP-1, transport seam).
- **DEP-2** `internal import` for every non-API dependency.

### Forbidden
- **FORB-1** No `@frozen`, `@inlinable`, `@usableFromInline`, `@_spi`, `@_exported` (except the umbrella's re-exports).
- **FORB-2** No force unwraps, no `try!`, no implicitly-unwrapped optionals in production code (swift-format enforces; a justifying comment is required for the rare test-code exception).
- **FORB-3** No AppKit/UIKit/ObjC-runtime imports anywhere in the package.
- **FORB-4** No reflection (`Mirror`) in `ApusKitCore`/`ApusKitWireFormat`.
- **FORB-5** `~Copyable` only for OS-resource handles (file locks, stream handles) — never on the core API surface.

### Formatting
- **STYLE-1** Committed `.swift-format` with strict opt-ins: `AllPublicDeclarationsHaveDocumentation`, `NeverForceUnwrap`, `NeverUseImplicitlyUnwrappedOptionals`, `OrderedImports`.
- **STYLE-2** `swift format lint --strict --recursive .` passes on every commit. No SwiftLint.

## 5. Testing requirements

- **TEST-1** **Swift Testing only.** No XCTest anywhere.
- **TEST-2** Unit tests use protocol-seam fakes (`ScriptedProvider`, `ToolSpy`, in-memory `SessionStore`). Never URLProtocol stubbing.
- **TEST-3** **Wire-compat conformance suite**: recorded pi SSE transcripts per API implementation + real pi v3 session files in `Tests/Fixtures/`; known deviations listed ONLY in `conformance-baseline.yml`. A fixture failure not in the baseline fails CI.
- **TEST-4** Event-stream and rebuilt-context assertions render a deterministic **textual dump** and compare it against an inline expected literal with `#expect`. The dump is the contract: one stable line per event, every field written out rather than relying on a mirror-based `description`. No snapshot library — the comparison is string equality, and a dependency that supplies it must not drag UI frameworks into the test build (FORB-3).
- **TEST-5** Live provider suites are `@Suite(.enabled(if: env("ANTHROPIC_API_KEY") != nil))`-style — never CI-blocking.
- **TEST-6** **Conformance Kit** ships as a product: a reusable Swift Testing suite that any third-party `APIImplementation`/`Tool`/`SessionStore`/`StreamingHTTPTransport` conformance runs against itself. Every built-in conformance runs it in CI.
- **TEST-7** Every bugfix lands with a regression test reproducing the bug first.
- **TEST-8** `Evals/` scenarios drive the REAL loop on `ScriptedProvider`: multi-turn, steering mid-run, tool failure, `length` stop, compaction mid-run, abort. Non-default target; runs in CI on macOS.

## 6. Example & documentation requirements

- **DOC-1** DocC per target with `--warnings-as-errors`; each target has a landing article including a standalone (loop-free) usage example proving library-first (G7).
- **DOC-2** `Examples/apuskit-cli`: ArgumentParser CLI with two subcommands — `chat` (interactive loop against any registered provider) and `serve-mcp` (exposes its tools as an MCP server over stdio). This is the living proof for CLI-first macOS support.
- **DOC-3** `Examples/consumers/`: one minimal executable per target, each declaring **exactly one ApusKit product dependency** — that target — in its own `Package.swift` (§7 consumer-simulation job compiles them all, plus one with `-default-isolation MainActor` + `NonisolatedNonsendingByDefault` to simulate an app consumer). A consumer MAY `import` sibling modules that reach it transitively through its one product: `public import` propagates API-surface diagnostics, NOT transitive bare-name visibility, so a consumer doing real work with `Agent` must still `import ApusKitCore`/`ApusKitProviders`/`ApusKitTools` to spell their types. Only the `ApusKit` umbrella's `@_exported public import` (§3.9) re-exports transitively; the umbrella consumer is what proves that. What this job gates is the **product dependency graph**, not the import list.
- **DOC-4** Any new public API family starts as `docs/proposals/NNNN-<name>.md` (short: motivation, proposed API, alternatives) in the same or a prior PR.

## 7. CI gates (all required on every PR unless marked nightly)

| Job | Command / source | Gate |
|---|---|---|
| Soundness | `swiftlang/github-workflows` reusable | license headers, format, DocC `--analyze` |
| Tests (macOS matrix) | `swift test` on Swift 6.2 + nightly toolchain | all green |
| Format | `swift format lint --strict --recursive .` | clean |
| API breakage | `swift package diagnose-api-breaking-changes` vs PR base | no undocumented breaks |
| Docs | `swift package generate-documentation --warnings-as-errors`, scoped with one `--target` per ApusKit target (see below) | clean |
| TSan | `swift test --sanitize=thread` | clean |
| Consumer simulation | build `Examples/consumers/*` (incl. MainActor-default variant) | compiles |
| Traits matrix | build with no traits / `NIO` / `MCP` / both | compiles + tests |
| Fuzz (nightly) | libFuzzer+ASan on SSE + JSONL + partial-JSON kernels, 60 s smoke, in-repo corpus | no crashes |
| Benchmarks (nightly) | `package-benchmark` run, trend recorded | no silent regression >10% |

**The Docs command MUST be `--target`-scoped.** Unscoped, `generate-documentation` also documents
every dependency product pulled into the graph, and a dependency's own doc comments are outside this
project's control: `swift-json-schema` 0.9.1 cross-references a nonexistent `Keywords.AdditionalProperties`
symbol at `Sources/JSONComponent/TypeSpecific/JSONObject.swift:80`, which `--warnings-as-errors` turns
into 184 fatal errors. The gate therefore names each ApusKit target explicitly — the same list
`.spi.yml`'s `documentation_targets` carries — so the gate measures OUR documentation and cannot be
broken by a dependency's. Adding a target means adding it here, in `.spi.yml`, and in `docs.yml`.

## 8. Build order — technical backing of the PRD milestones

**The delivery plan and its gates live in the PRD (§4) and progress in PRD §5 — work strictly in that order.** This table maps each PRD gate to the technical checks that implement it; a milestone is DONE only when its backing checks are green in CI:

| PRD milestone | Technical backing (this document) |
|---|---|
| M0 Skeleton | §1 layout, §2 manifest, §3.1 Core, `ScriptedProvider`, loop skeleton (LOOP-1..7 partial), first TEST suites, §7 jobs live |
| M1 Real streaming | §3.2 kernels, §3.3 three built-in implementations + transport seam, §3.4 tools (TOOL-1..3, TRUNC-1); gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations |
| M2 Sessions | §3.5 full; gate = SESS-1 suite green |
| M3 Public 0.1.0 | hook bus + `AgentExtension` (§3.6), DOC-1..4, Conformance Kit (TEST-6), `apuskit-cli chat` (DOC-2), governance files, SPI listing |
| M4 MCP | §3.7 full, `apuskit-cli serve-mcp`; gate checks per PRD (HTTP external-server call + stdio stock-client consumption) |
| M5 Workflows | §3.8 full (WF-1..4); gate = two-provider red-team workflow on public API, journaled (WF-1) |
| M6 → 1.0 | flip `@nonexhaustive(warn)` → `@nonexhaustive` (ENUM-1), freeze Sendable audit (CC-3), proposals-driven API freeze |

## 9. Definition of Done — every PR

1. Rule codes cited for any judgment call (`CC-2`, `ACC-2`, …).
2. All §7 required CI jobs green; no new warnings (warnings are errors).
3. New/changed public API: doc comments (API-1), explicit isolation annotation (CC-2), Sendable audit updated (CC-3), proposal linked if it's a new family (DOC-4).
4. Tests included: unit for logic, conformance fixture if wire-facing, regression test if bugfix (TEST-7), Conformance Kit run if a new conformable implementation.
5. **PRD §5 Progress updated in the same PR** when a deliverable or gate is completed (PRD rules PROG-1..4); README status regenerated if the *Current status* line changed.
6. `CHANGELOG.md` untouched (maintainer-curated) unless you are the maintainer cutting a release.
7. Commits DCO-signed (`git commit -s`).
8. No scope beyond the milestone task: if it doesn't belong in core, it's an extension; if it isn't in this document or the PRD, it needs a proposal first.

