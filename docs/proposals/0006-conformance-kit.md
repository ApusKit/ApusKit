# 0006 — Conformance Kit (`ApusKitConformance`)

Status: proposed (M3 Public 0.1.0, F10.3). Draft for the maintainer. Nothing here is implemented.
Revision 2 addresses the first red-team pass; see "Changes in revision 2" at the end.

## Motivation

`TEST-6` and `ACC-3` promise that every client-conformable protocol has an
**executable** contract that a third party can run against their own
conformance. The protocols are `APIImplementation`, `Tool`, `SessionStore` and
`StreamingHTTPTransport`. PRD F10.3 makes that promise a deliverable of M3.
Today the contracts exist only as private test helpers that no consumer can
reach:

- `assertPROV1Shape` (`Tests/Shared/TestSupport.swift`) checks `PROV-1`'s
  start/terminal shape. Its own doc comment calls it "the check the `TEST-6`
  Conformance Kit will generalise". Each built-in adapter's suite calls it and
  also open-codes the split-at-every-byte-offset replay
  (`AnthropicMessagesAPITests.swift:287-292` and siblings).
- `assertStoreContract` (`Tests/ApusKitSessionsTests/SessionStoreTests.swift`)
  pins `JSONLFileSessionStore` and `InMemorySessionStore` to one behaviour. It
  is `private` to that file.
- `URLSessionTransportTests` proves incremental delivery against a loopback
  socket. Nothing generalises that proof to another transport, such as the M4
  `AsyncHTTPClientTransport`.
- No `Tool` contract check exists anywhere.

A consumer who writes `MyProxyAPI: APIImplementation` or
`SQLiteSessionStore: SessionStore` has only the DocC prose to go on. They find
out about a `PROV-1` or `API-4` violation when the agent loop misbehaves.
`ApusKitConformance` packages these checks as a library product. The built-in
conformances are proven by the same code a third party runs.

**pi has no equivalent product.** The kit is an ApusKit addition under §0
principles 2 and 3: library-first, with every conformable seam proven through
public API. What *is* ported from pi are the contracts it checks:

- `PROV-1`'s stream shape: one start, one terminal `done` or `error`.
- Encoding provider failures as a terminal in-stream error instead of
  throwing. This is the pi-ai stream contract that `LOOP-3` builds on. It is
  **not yet written into `APIImplementation`'s DocC**, so the kit does not
  enforce it until it is (see "Candidate clauses").

### The enforcement rule

The kit invents no new semantics. A check is **enforced** only when the
clause it tests is already stated in the TRD or in the protocol's DocC
(`ACC-3`: the DocC is the semantic contract, the kit makes it executable).
Every enforced check cites that sentence. A clause the kit *would* like to
check but that no document states yet is listed under **Candidate clauses**
with the DocC/TRD amendment it needs. A candidate becomes a check only when the
maintainer accepts the amendment (Open question 8), and the amendment lands in
the same PR as the check.

## Two facts measured before drafting

These two facts shaped the design. Both were measured in a scratch package
(Swift 6.3.2, Xcode 26.5, macOS 26). Fact 2 was independently reproduced by
the red-team pass.

1. **An `@Test` declared in a library product runs in every consumer's test
   bundle.** Swift Testing discovers tests in all linked images. A
   `@Test func shippedFromLibrary()` in a library target appeared in the
   dependent test target's run. So the kit **must declare no `@Test` or
   `@Suite`**. Swift Testing also has no cross-module suite inheritance, so the
   kit cannot ship a suite that is parameterised by the consumer's type.
   `TEST-6`'s wording ("a reusable Swift Testing suite") therefore needs an
   amendment (see "Package, docs and CI additions").
2. **A library that `import`s `Testing` builds and links into an executable,
   but the executable aborts at launch.** The failure is
   `dyld: Library not loaded: @rpath/Testing.framework` (exit 134). In a test
   target the same library works. Consequence: **the kit does not import
   `Testing` at all** (next section), so it can be re-exported by the umbrella
   (`PKG-7`) and linked by an executable (`DOC-3`, `apuskit-cli`).

## Proposed API

Target `ApusKitConformance`, its own library product (`PKG-7`), **re-exported
by the `ApusKit` umbrella like every other target** (`PKG-6`, `PKG-7`, §3.9).
It depends on `ApusKitCore`, `ApusKitProviders`, `ApusKitTools`,
`ApusKitSessions` and `swift-json-schema`'s `JSONSchema`/`JSONSchemaBuilder`,
all through `internal import` except the protocol modules it names publicly
(`DEP-2`). It **never imports `ApusKitAgent`** (`PKG-6`). It cannot depend on
`TestSupport` either, because that target imports `ApusKitAgent`
(`Package.swift`). It adds no package dependency (`PKG-5` unchanged), and it
**does not import `Testing`** (measured fact 2).

The checks are plain `@concurrent` functions that return a value. Namespacing
follows the caseless-`enum` precedent of `Compaction` and `JSONLCodec`. Every
type is a sealed value type (`ACC-2`). The kit adds no conformable protocol.

### Report types

```swift
/// One contract clause an implementation failed to satisfy.
public struct ConformanceViolation: Sendable, Equatable, CustomStringConvertible {
  /// The TRD rule or DocC clause the failed check enforces, e.g. `"PROV-1"` or `"API-4"`.
  public var rule: String

  /// The stable identifier of the check that failed, e.g. `"prov1.chunkInvariance"`.
  public var check: String

  /// A human-readable account of what was observed versus what the contract requires.
  public var message: String

  /// Creates a violation.
  public init(rule: String, check: String, message: String)
}

/// The outcome of running one conformance check family against one implementation.
public struct ConformanceReport: Sendable, Equatable, CustomStringConvertible {
  /// A label naming the implementation under test, used in `description`.
  public var subject: String

  /// The identifiers of every check that ran, in execution order (`API-4`).
  public var checksRun: [String]

  /// Every violation found, in the order the checks ran (`API-4`).
  public var violations: [ConformanceViolation]

  /// Whether no check found a violation.
  public var isConforming: Bool { get }
}
```

There is **no `recordIssues`** bridge in the kit. A consumer asserts on the
report from their own `@Test`; `Testing` prints the `Equatable` diff of the
violation list:

```swift
@Test(.timeLimit(.minutes(1)))
func mySessionStoreConforms() async {
  let report = await SessionStoreConformance.check(subject: "SQLiteSessionStore") {
    try SQLiteSessionStore(path: makeTemporaryPath())
  }
  #expect(report.violations == [])
}
```

The same report prints from an executable (`print(report)`), which is what
the `Examples/consumers` executable and an eventual `apuskit-cli` use. Whether
a separate `Testing`-importing convenience module is wanted is Open question 1.

### `APIImplementationConformance`

```swift
/// A recorded provider response the kit replays through an implementation under test.
public struct StreamFixture: Sendable {
  /// A label for this fixture, used in violation messages.
  public var name: String

  /// The request handed to the implementation.
  public var request: LLMRequest

  /// The raw response body the kit's replay transport yields, e.g. an SSE transcript.
  public var responseBody: Data

  /// Creates a fixture.
  public init(name: String, request: LLMRequest, responseBody: Data)
}

/// Executable contract for `APIImplementation` (`PROV-1`, `PROV-4`, `LOOP-6`).
public enum APIImplementationConformance {
  /// Replays each fixture through `implementation` and reports every contract violation.
  ///
  /// - Complexity: O(*n*²) in each fixture's body length, because the body is
  ///   replayed once for every byte offset at which it can be split.
  @concurrent
  public static func check(
    subject: String,
    implementation: some APIImplementation,
    fixtures: [StreamFixture]
  ) async -> ConformanceReport
}
```

The kit owns its replay and hanging transports, built on the
`FixtureTransport` pattern. They are **internal**, so the kit's public surface
gains no fakes (`TEST-6`: the `TEST-2` fakes stay in `TestSupport`).

**Enforced checks** (clause already documented):

| Check | Source of the clause | Requirement |
|---|---|---|
| `prov1.shape` | PROV-1 (TRD §3.3); `APIImplementation.stream` DocC | Exactly one `.start`, first. Exactly one `.done`/`.error`, last. Generalises `assertPROV1Shape`. |
| `prov1.chunkInvariance` | PROV-1 ("the accumulator MUST survive argument JSON split across arbitrary chunk boundaries") | Splitting the body at every byte offset, and also delivering it one byte per chunk the way `URLSessionTransport.forwardBytes` does, yields events equal to the whole-body replay. |
| `prov4.connection` | `ProviderConnection.baseURL`, `ProviderAuth.bearer`, `ProviderAuth.headers` DocC | Every transport request's URL starts with `connection.baseURL`. `.bearer(t)` arrives as `Authorization: Bearer t` (pinned by `ProviderAuth.bearer`'s DocC). `.headers(_)` fields arrive verbatim on every request. |
| `loop6.cancellation` | LOOP-6 | When the consumer's task is cancelled mid-stream over a hanging transport, the transport stream terminates and the implementation's stream finishes. |

`PROV-1`'s third clause ("every `toolCall*` event carries `contentIndex`") is
enforced by the compiler: `contentIndex` is a non-optional `Int` on every
`StreamEvent.toolCall*` case. The kit has nothing to add. `.apiKey` rendering
stays unchecked, because its DocC says "a provider-specific header".
Fixture-specific event expectations (`TEST-4` textual dumps) stay in each
adapter's own suite. The kit checks invariants, not transcripts.

### `ToolConformance`

```swift
/// Executable contract for `Tool` (`TOOL-1`, `TOOL-4`, `LOOP-6`).
public enum ToolConformance {
  /// Checks `tool`'s schema against its decoder, and executes it once per valid sample.
  ///
  /// Execution checks run only when `validArgumentsJSON` is non-empty. A tool with
  /// side effects should be handed samples that are safe to execute.
  @concurrent
  public static func check<T: Tool>(
    subject: String,
    tool: T,
    validArgumentsJSON: [String],
    invalidArgumentsJSON: [String] = []
  ) async -> ConformanceReport
}
```

**Enforced checks:**

| Check | Source of the clause | Requirement |
|---|---|---|
| `tool1.schemaAgreesWithDecoder` | TOOL-1; `Tool.Arguments` DocC | Every valid sample validates against the schema **and** decodes as `Arguments`. This catches a hand-written `Decodable` drifting from its schema. |
| `tool1.schemaRejects` | TOOL-1 | Every invalid sample fails schema validation. This proves the schema is not trivially permissive. |
| `tool4.cancellation` | TOOL-4, LOOP-6; `Tool.execute` DocC ("`abort()` cancels the task running this method … return a partial `ToolResult`") | Cancelling the task that runs `execute` makes it return or throw. It must not hang. |

Not checked, and why:

- **"`onUpdate` is never invoked after `execute` returns"** — dropped. `onUpdate`
  is a non-escaping `@Sendable (ToolUpdate) -> Void` parameter, so the compiler
  already forbids a late call. A conformer could only violate it through
  `withoutActuallyEscaping` misuse, which is undefined behaviour, so the check
  could not be proven against a legitimate mutant.
- **Name pattern, non-empty description, object-root schema** — `Tool`'s DocC
  states none of these. They are candidate clauses (below). A name *pattern*
  in particular would bake vendor naming limits into the library, which the
  no-hardcoded-vendor rule forbids unless it is written as a vendor-neutral
  ApusKit rule.
- `TOOL-2` (errors become results) and `TRUNC-1` (truncation) are **not** a
  `Tool`'s obligations. `AnyAgentTool` enforces both for every tool. A thrown
  error from `execute` is therefore never a violation.

### `SessionStoreConformance`

```swift
/// Executable contract for `SessionStore` (`§3.5`, `F3.4`, `API-4`, `ERR-2`).
public enum SessionStoreConformance {
  /// Runs every check against a fresh store from `makeStore` and reports every violation.
  ///
  /// `makeStore` is called once per check and must return an **empty** store each time.
  @concurrent
  public static func check(
    subject: String,
    makeStore: @Sendable () async throws -> any SessionStore
  ) async -> ConformanceReport
}
```

| Check | Rule | Requirement |
|---|---|---|
| `store.emptyRoundTrip` | F3.4 | A created session loads back with an equal header, no entries and empty `trailing`. |
| `store.appendOrder` | §3.5 | Entries load back in append order **independent of `parentID`**. The fixture appends a child before a sibling of its parent, with at least two branches (gotcha: "a selection rule needs ≥2 instances"). |
| `store.everyEntryKind` | §3.5, CORE-2 | One entry of each of the eight `SessionEntryKind` cases round-trips equal. |
| `store.sessionsIndependent` | F3.4 | Appends to one session never appear in another. |
| `api4.listOrder` | API-4 | `listSessionIDs()` is ascending by `hex`, with ids created in non-sorted order. |
| `err2.alreadyExists` / `err2.notFound` | ERR-2 | Duplicate create throws `.sessionAlreadyExists`. Load or append to an unknown id throws `.sessionNotFound`. Both are `SessionStoreError`. |

This generalises `assertStoreContract` one-for-one and adds the last four
rows. Before implementation, each row's clause is re-verified against
`SessionStore`'s DocC under the enforcement rule; any row whose clause lives
only in PRD/TRD prose gets its DocC sentence in the same PR. Concurrent
appends are **not** in the contract (Open question 5).

### `StreamingHTTPTransportConformance`

```swift
/// Executable contract for `StreamingHTTPTransport`.
public enum StreamingHTTPTransportConformance {
  /// Drives transports from `makeTransport` against a loopback HTTP/1.1 server the kit runs.
  @concurrent
  public static func check(
    subject: String,
    makeTransport: @Sendable () async throws -> any StreamingHTTPTransport
  ) async -> ConformanceReport
}
```

**Enforced checks** (from `StreamingHTTPTransport.stream`'s DocC, "Performs
`request` and streams the response body as it arrives"):

| Check | Requirement |
|---|---|
| `transport.requestFidelity` | Method, every header, and the body reach the server unchanged. |
| `transport.bodyCompleteness` | The streamed chunks concatenate to the exact response body, then the stream finishes normally. |
| `transport.incrementalDelivery` | The first bytes are yielded **before** the server ends the response ("as it arrives"). SSE depends on this. |

Non-2xx handling and cancellation are **not** documented on the protocol (only
`URLSessionTransport` documents its non-2xx behaviour), so they are candidate
clauses, below.

#### The loopback server — design and the `CC-4` question

The kit needs an HTTP/1.1 server on `127.0.0.1`. This is **new code, not a
promotion** of the `URLSessionTransportTests` server: that server reads one
4096-byte `recv` and discards it unparsed, serves one connection, and reports
nothing back (`URLSessionTransportTests.swift:236-237, 318-320`). The kit's
server needs, in addition:

- **A request parser**: request line, headers up to `\r\n\r\n`, and a body of
  exactly `Content-Length` bytes, read across as many `recv`s as it takes.
  Chunked *request* bodies are out of scope (no built-in sends them).
- **A server-to-check signalling channel**: an `AsyncStream<ServerEvent>`
  whose continuation the server thread yields `.requestReceived(...)` and
  `.connectionClosed` into. `AsyncStream.Continuation` is `Sendable` and safe
  to yield from any thread, so the async side never blocks.
- **One connection per check**, with a fresh listening socket each time, so
  checks stay independent.
- `Darwin`/`Glibc` imports only, so nothing in it would block Linux (`PKG-2`).

**The judgment call (escalated, Open question 10).** The server does blocking
socket I/O on a `Thread.detachNewThread`, never on an actor. That satisfies
`CC-4`'s "no sync I/O on any actor" clause, but **not** its "Actors and
`AsyncStream` only" clause: a detached `Thread` is neither. The existing
server's own justification is that it is "a test fixture"; in the kit it would
ship inside a library product. This proposal does **not** assume compliance. It
needs either a scoped `CC-4` carve-out for the kit's internal fixture server,
or one of the alternatives in Open question 10.

### Candidate clauses (not enforced until documented)

Each row is a check the kit could run, the amendment it needs before it may
(`ACC-3`), and the decision it waits on. None is in the kit as drafted.

| Candidate check | Needed amendment | Notes |
|---|---|---|
| `prov1.toolCallIndexing` — every `toolCallDelta`/`toolCallEnd` names an index opened by an earlier `toolCallStart`; nothing follows that index's `toolCallEnd` | PROV-1 (TRD §3.3) and `StreamEvent` DocC | Today PROV-1 only requires the index to be present. |
| `prov1.toolCallClosed` — every `toolCallStart` is matched by a `toolCallEnd` before `.done` | PROV-1 and `StreamEvent` DocC | Unclear for `stopReason == .length` and `tool-call-truncated.sse`. |
| `prov1.transportFailure` — a transport that finishes by throwing yields exactly one terminal `.error` and the stream itself does not throw | `APIImplementation.stream` DocC; possibly LOOP-3 | The loop accepts a throwing stream (`RunLoop.swift:111`, `for try await`), and `ScriptedProvider` throws (Open question 4). |
| `prov4.singleRequest` — each `stream` call issues exactly one transport request | `APIImplementation.stream` DocC (retry clause, `ACC-3` lists retry) | Forbids in-adapter retries; that is a policy choice, not an observation. |
| `tool.description` — non-empty | `Tool.description` DocC | Was tagged "API-1 (spirit)"; API-1 governs ApusKit's own declarations, not conformers. |
| `tool.schemaRoot` — the `Arguments` schema is an object schema | `Tool.Arguments` DocC | All three built-in wire shapes require an object root (proposal 0003). |
| `tool.name` — a vendor-neutral name rule | `Tool.name` DocC, stated as an ApusKit rule, not a vendor's | The draft's `^[a-zA-Z0-9_-]{1,64}$` and its `R5` tag are withdrawn: `R5` is proposal 0003's wire-rendering requirement, and a vendor-derived pattern conflicts with the no-hardcoded-vendor rule. |
| `transport.non2xx` — a non-2xx status finishes the stream by throwing, with no body chunk yielded | `StreamingHTTPTransport.stream` DocC | Only `URLSessionTransport` documents this today. Whether the error must be a `StreamError` with `.provider` is a further choice. |
| `transport.cancellation` — cancelling the consumer's task finishes the stream and closes the connection | `StreamingHTTPTransport.stream` DocC (cancellation clause, `ACC-3`) | Needs the server's `.connectionClosed` signal. |

### Hang detection and `DI-3`

The cancellation checks deliberately contain **no internal timeout**.
Measuring a timeout needs a clock, and `DI-3` forbids wall-clock sleeps in
library logic. A non-conforming implementation therefore hangs the check. The
DocC article requires every caller to put `.timeLimit(.minutes(1))` on the
enclosing `@Test`, which is Swift Testing's minimum granularity. See Open
question 6.

## How the built-ins run it in CI (`TEST-6`, §9 item 4)

A new test target, `ApusKitConformanceTests`, satisfies "one test target per
source target". It depends on `ApusKitConformance` and `TestSupport` and holds
two kinds of suite:

1. **Kit self-tests (mutation proof).** Each enforced check is run against a
   deliberately broken conformance that violates exactly that clause. The test
   asserts `report.violations.map(\.check)` contains the check's id. Examples:
   an adapter that emits two `.start`s, a store that sorts `listSessionIDs`
   descending, a transport that buffers to end-of-response, a tool whose
   `Decodable` ignores a required schema property. Every enforced check has
   such a mutant; a check for which no legitimate mutant can be written is not
   added (that is why `tool.updatesBeforeReturn` was dropped).
2. **Built-in conformances, all green:**
   - `AnthropicMessagesAPI`, `OpenAICompletionsAPI` and `OpenAIResponsesAPI`
     use the existing `Tests/Fixtures/*/*.sse` transcripts via
     `Fixtures.transcript`.
   - `ScriptedProvider` (see Open question 4).
   - `URLSessionTransport`, given a caller-built ephemeral `URLSession`
     (`DI-3`).
   - `JSONLFileSessionStore` in a fresh temporary directory per check, and
     `InMemorySessionStore`.
   - No built-in `Tool` exists (`TOOL-3`), so `RecordingTool`, `GateTool` and
     `CancellationObservingTool` from `TestSupport` stand in.

The built-ins run from this one target. **No per-target test suite gains a
kit dependency**, so the existing helpers are handled as follows:

- **`assertStoreContract` is deleted.** Its only call sites
  (`SessionStoreTests.swift:119,125`) run it against the two built-in stores,
  which is exactly what `ApusKitConformanceTests` now does. Those two tests
  move; nothing else in `ApusKitSessionsTests` changes.
- **`assertPROV1Shape` stays in `TestSupport`.** Its 17 call sites in
  `ApusKitProvidersTests` assert shape on *specific* error and truncation
  paths next to `TEST-4` dumps (e.g. `AnthropicMessagesAPITests.swift:345` on
  `tool-call-truncated.sse`). The kit's API takes an implementation plus
  fixtures, not an already-collected `[StreamEvent]`, so those calls cannot
  switch one-for-one. This leaves two copies of the start/terminal shape
  check. Collapsing them is Open question 11.
- **The per-adapter byte-split loops stay** for the same reason: they sit
  beside fixture-specific assertions. `prov1.chunkInvariance` covers the same
  invariant for the kit's own fixtures; removing the loops is part of Open
  question 11.

**Relation to `TestSupport`.** `TestSupport` stays internal and
unpublished. It is the home of the `TEST-2` fakes that drive the **agent
loop** (`HangingProvider`, `GateTool`, `FollowUpGate`, and the others). The kit
checks **one conformance in isolation** and never needs the loop. The two may
look alike (both have replay transports), but they serve different
dependency graphs: `TestSupport` imports `ApusKitAgent` and the kit must not
(`PKG-6`). The kit's transports stay internal so the published surface does
not become a second fake library.

## Package, docs and CI additions

| Where | Change |
|---|---|
| `Package.swift` | Add `.library(name: "ApusKitConformance")`, the target with `commonSwiftSettings`, and `.testTarget("ApusKitConformanceTests")`. |
| `ApusKit` umbrella | Re-export `ApusKitConformance` (`PKG-7`, §3.9). Safe because the kit does not import `Testing`. |
| `Examples/consumers/conformance-consumer/` | A minimal **executable** with one product dependency (`DOC-3` unchanged): runs `SessionStoreConformance.check` against `InMemorySessionStore` and prints the report. The shared consumer loop is unchanged. |
| `.spi.yml`, `.github/workflows/docs.yml`, TRD §7 text, AGENTS.md Docs command | Add `--target ApusKitConformance` to every `--target` list (TRD §7: "adding a target means adding it here, in `.spi.yml`, and in `docs.yml`"). |
| **TRD amendment — `TEST-6`** | Replace "a reusable Swift Testing suite" with "reusable check functions, callable from a consumer's own Swift Testing `@Test`, that return a `ConformanceReport`", citing measured fact 1. Needs maintainer sign-off (Open question 12). |
| **TRD amendment — `CC-4`** | Only if Open question 10 resolves to a carve-out: scope it to the kit's internal loopback server. |
| **DocC/TRD amendments — candidate clauses** | One amendment per accepted candidate (Open question 8), landed with its check. |
| DocC (`DOC-1`) | A landing article with the standalone usage example above. Each conformable protocol's "Conform freely" DocC (`ACC-2`/`ACC-3`) links to its check family. |
| `docs/sendable-audit.md` (`CC-3`) | A new `ApusKitConformance` section covering `ConformanceViolation`, `ConformanceReport`, `StreamFixture` and the four namespaces (all explicit `Sendable`). |
| `PRD.md` §5 | Tick "Conformance Kit (F10.3)" under M3 in the landing PR (`PROG-1`). |
| Brain | `code-maps.md` row and `architecture.md` DAG line, committed separately as `chore(brain)`. |

TSan already runs the whole test plan, so the loopback server's thread is
covered without a new job.

## Alternatives considered

- **Ship `@Suite`s in the kit, parameterised by a registration hook.**
  Rejected (measured fact 1). Swift Testing would run the kit's suites in
  *every* consumer's test bundle, including consumers that never registered
  anything. It also has no cross-module suite inheritance to make
  parameterisation work.
- **Checks call `#expect` / `Issue.record` directly, returning `Void`, like
  `assertPROV1Shape`.** Rejected. The kit would import `Testing` (measured
  fact 2: no umbrella re-export, no executable consumer), and the kit's own
  mutation self-tests could only tell *which* check fired by matching on issue
  comment text. A returned `ConformanceReport` makes the self-test exact and
  prints from an executable.
- **`ConformanceReport.recordIssues()` in the kit (revision 1's design).**
  Withdrawn. It forced `public import Testing` into the kit, which kept the kit
  out of the umbrella against `PKG-7` and made any executable linking it crash
  at launch. A split-module form of it is Open question 1.
- **Publish the `TestSupport` fakes as the kit.** Rejected by `TEST-6`
  ("the TEST-2 fakes stay in the internal `TestSupport` target"), and it is
  impossible under `PKG-6` because `TestSupport` imports `ApusKitAgent`.
- **A public `ConformanceTransport` / `LoopbackServer` so consumers compose
  their own checks.** Rejected for 0.1.0. It would add a public fake family the
  TRD did not ask for, and every public type is a SemVer obligation (`CC-3`).
  It can be proposed later if a consumer needs it.
- **Let the consumer supply a server URL for transport checks.** Rejected as
  the default. The checks need precise control over response timing (holding
  the connection open for `incrementalDelivery`). It is, however, one way out
  of the `CC-4` question (Open question 10, option c).
- **Internal timeouts on cancellation checks via an injected `Clock`.**
  Deferred (Open question 6). It is a parameter every caller must thread
  through to catch only a hang, and `.timeLimit` already catches that.

## Open questions for the maintainer

1. **A `Testing` bridge, or none?** As drafted the kit has no `Testing`
   import, is re-exported by the umbrella (`PKG-7`), and consumers write
   `#expect(report.violations == [])`. Do you also want a convenience
   `report.recordIssues()`? If so it must live in a second product
   (e.g. `ApusKitConformanceTesting`) that the umbrella does **not**
   re-export — which itself needs a `PKG-7` carve-out, its own consumer (a
   test target, since an executable linking `Testing` crashes), and the
   unmeasured Docs-gate run in question 9.
2. **Consumer-simulation shape.** Resolved by question 1's default: the
   conformance consumer is an ordinary executable and the shared loop is
   unchanged. It reopens only if question 1 adds the bridge module; then the
   choice is changing the shared loop to `swift build --build-tests` or a
   separate CI step, plus a `DOC-3` amendment ("one minimal executable per
   target") for the test-target consumer.
3. **`ACC-3` lists `AgentExtension` and the hook handlers too.** `PKG-6`
   forbids the kit from importing `ApusKitAgent`, so they cannot have contracts
   *here*. Options are (a) a later `ApusKitAgentConformance` target allowed to
   import Agent, (b) narrowing `ACC-3`'s executable-contract clause to
   `TEST-6`'s four protocols, or (c) defer until the M3 hook-bus proposal
   lands. Which one?
4. **`ScriptedProvider` and thrown finishes.** `ScriptedProvider` ignores the
   connection, so the fixture checks do not apply to it. When its scripts run
   out it `finish(throwing:)`s
   (`Sources/ApusKitProviders/ScriptedProvider.swift:53`) instead of emitting a
   terminal `.error`, the one place a built-in departs from the in-stream-error
   convention every adapter follows. The loop tolerates it (`RunLoop.swift:111`
   iterates with `for try await`). Is a thrown finish PROV-1-legal? The answer
   decides the `prov1.transportFailure` candidate. If not legal, fixing
   `ScriptedProvider` is a separate `fix(m3):` with a regression test
   (`TEST-7`). Also: should the kit grow a script-based mode for
   `ScriptedProvider`, or is it exempt?
5. **Concurrent appends.** `JSONLFileSessionStore.appendEntry` does
   `seekToEnd` then `write` on a fresh `FileHandle` per call, without
   `O_APPEND`, and `createSession` is check-then-write. Concurrent appends to
   one session *look* able to interleave or overwrite. This is unverified.
   Should "concurrent appends all persist" be part of the `SessionStore`
   contract? If yes, the check likely fails the built-in and needs a fix first.
   This proposal leaves it out, and the protocol doc's "appended in call order"
   only makes sense for serial calls.
6. **Hang detection.** Is `.timeLimit(.minutes(1))` on the caller's `@Test`
   acceptable as the only guard against a hanging cancellation check, or do you
   want an injected `any Clock<Duration>` with a bounded wait (`DI-3`-legal,
   but one more parameter on every entry point)?
7. **Evolution of the check set.** Adding a check can turn a third party's
   green suite red with no API change. Is that SemVer-minor (with a CHANGELOG
   line), or should new checks be opt-in behind a version parameter, e.g.
   `check(…, contract: .v0_1)`? Is a check's string `id` part of the stable
   API? (This matters immediately: every accepted candidate clause after 0.1.0
   is such an addition.)
8. **Which candidate clauses become contract?** For each row of the
   "Candidate clauses" table — `prov1.toolCallIndexing`,
   `prov1.toolCallClosed`, `prov1.transportFailure`, `prov4.singleRequest`,
   `tool.description`, `tool.schemaRoot`, `tool.name`, `transport.non2xx`,
   `transport.cancellation` — accept (DocC/TRD sentence + check land together
   in the kit PR) or reject (dropped). For `tool.name`, what vendor-neutral
   rule, if any? For `transport.non2xx`, must the error be a `StreamError`
   with code `.provider`? For `prov4.singleRequest`, are in-adapter retries
   forbidden?
9. **DocC for a module importing `Testing`.** Only relevant if question 1 adds
   the bridge module. Unmeasured: the Docs gate with
   `--target ApusKitConformanceTesting --warnings-as-errors` has not been tried.
10. **`CC-4` and the kit's loopback server.** Shipping a detached-`Thread`
    blocking-socket server in a library product does not meet `CC-4`'s
    "Actors and `AsyncStream` only". Options: (a) a TRD carve-out scoped to
    the kit's internal fixture server; (b) move
    `StreamingHTTPTransportConformance` into the test-only bridge module of
    question 1 (still shipped, so still needs (a)); (c) make the consumer
    supply the server, so the kit ships no thread (loses timing control,
    weakens `incrementalDelivery`); (d) defer the transport family until the
    `NIO` trait exists and build the server on SwiftNIO behind that trait
    (`DEP-1` keeps it off the public surface; transport checks then require
    the trait). Which one?
11. **Two copies of the PROV-1 shape check.** Keeping `assertPROV1Shape` in
    `TestSupport` duplicates `prov1.shape`. To collapse them the kit would need
    a public entry point over collected events, e.g.
    `APIImplementationConformance.checkShape(_ events: [StreamEvent]) -> ConformanceReport`
    (a new public function, `CC-3`), and `ApusKitProvidersTests` would gain a
    kit dependency (test targets are outside `PKG-6`, but it widens that suite's
    graph). Accept the duplication for 0.1.0, or add the entry point and switch
    the 17 call sites (and the byte-split loops) in the kit PR?
12. **`TEST-6` wording amendment.** Approve replacing "a reusable Swift Testing
    suite" with check functions returning a report (measured fact 1)?

## Changes in revision 2

- Added the enforcement rule: only documented clauses are enforced; the rest
  moved to a "Candidate clauses" table pending Open question 8.
  `prov1.toolCallIndexing`, `prov1.transportFailure`, the "exactly one request"
  part of `prov4.connection`, `tool.name`, `tool.description`,
  `tool.schemaRoot`, `transport.non2xx` and `transport.cancellation` are no
  longer enforced as drafted. The `R5` citation and the vendor-derived name
  pattern were withdrawn.
- Dropped `tool.updatesBeforeReturn` (compiler-enforced; no legitimate mutant).
- `prov4.connection` now checks `.bearer` rendering, which `ProviderAuth.bearer`'s
  DocC pins.
- Removed `recordIssues` and the kit's `Testing` import, so the kit is
  re-exported by the umbrella (`PKG-7`) and has an executable consumer
  (`DOC-3`) with the shared loop unchanged. Former Open questions 1/2/9
  rewritten accordingly.
- Fixed the helper-migration contradiction: `assertStoreContract` is deleted
  (its call sites move to `ApusKitConformanceTests`); `assertPROV1Shape` and
  the byte-split loops stay; collapsing them is Open question 11.
- The loopback server is now described as new code with a request parser and an
  `AsyncStream` signalling channel; the `CC-4` conflict is escalated as Open
  question 10 instead of claimed compliant.
- Listed the `TEST-6` wording amendment (Open question 12) and the conditional
  `CC-4`/`DOC-3` amendments in the package/docs table.
