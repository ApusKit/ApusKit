# Gotchas

Last reviewed: 2026-08-25
Source of truth: `docs/ci-deferrals.md`, `.github/workflows`, git history

Traps that already cost someone time. Every entry stays — they exist to stop rediscovery.
Entries marked **Safeguard** are merge blockers, not advice.

## `swift test --filter` takes symbol names, not `@Test` display strings

Symptom: `swift test --filter 'ContentBlock/text round-trips'` prints
`warning: No matching test cases were run`, runs zero tests, and **exits 0**.
Evidence: `Tests/ApusKitCoreTests/CoreTests.swift:17-21` — `@Suite("ContentBlock")` on
`struct ContentBlockTests`, `@Test("text round-trips")` on `func textRoundTrips()`.
Impact: a silent green. An agent filtering by the human-readable name concludes its change is
verified when nothing ran at all.
Do: filter on the Swift symbols — `swift test --filter 'ContentBlockTests/textRoundTrips'`.
Avoid: pasting the `@Suite`/`@Test` display strings into `--filter`. If a filtered run reports
0 tests, treat it as a failure and fix the filter.

## Unscoped DocC fails because of a dependency, not this package

Symptom: `swift package generate-documentation --warnings-as-errors` exits 1 with 184 errors.
Evidence: `docs/ci-deferrals.md` — swift-docc-plugin 1.5.0 documents all targets "in this
package **and its dependencies**"; swift-json-schema 0.9.1 cross-references a symbol that does
not exist.
Impact: looks like an ApusKit docs regression and invites a pointless hunt through our own doc
comments.
Do: always pass one `--target` per ApusKit target — the command in `commands.md` and in
`.github/workflows/docs.yml`.
Avoid: "simplifying" the Docs gate by dropping the `--target` flags. Adding a new target means
updating three places: `.spi.yml`, `.github/workflows/docs.yml`, and TRD §7.

## Consumer manifests must pin the root package name — **Safeguard**

Symptom: all six consumer builds fail with `unknown package 'ApusKit' in dependencies`, but only
in a checkout whose directory is not named `ApusKit`.
Evidence: commit `2337766`; `Examples/consumers/mainactor-consumer/Package.swift` shows the fix.
Impact: CI hid this because actions/checkout lands in a directory named after the repo — so it
was green here and broken for every real consumer, which is exactly what the consumer gate exists
to catch.
Do: `.package(name: "ApusKit", path: "../../..")` in every consumer manifest.
Avoid: bare `.package(path: "../../..")` — it derives package identity from the directory
basename.

## Every warning is a build failure

Symptom: a build fails on something that reads as a warning.
Evidence: `Package.swift` — `commonSwiftSettings` carries `.treatAllWarnings(as: .error)` plus
`StrictConcurrency` and the three PKG-3 upcoming features, and every target applies it.
Impact: a new target that spells out its own `swiftSettings` silently opts out of the whole law —
strict concurrency, existential-any, warnings-as-errors, all of it — and nothing flags the gap.
Do: reuse `commonSwiftSettings` for any new target.
Avoid: writing a fresh `swiftSettings:` array on a new target.

## Local green is not CI green — and 6.3 type-checks what 6.2 gives up on

Symptom: `swift test` passes locally and the required `swift test (swift-6.2)` leg fails to
**compile**, with `macro expansion #expect:1:1: error: the compiler is unable to type-check this
expression in reasonable time`.
Evidence: local toolchain is Swift 6.3.2; `Package.swift` declares `swift-tools-version: 6.2` and
`.github/workflows/tests.yml` runs a 6.2 leg plus a nightly leg installed via swiftly. The first CI
run that ever reached compilation died on
`#expect(usage.cost(at: pricing) == 3 + 15 + 0.3 + 3.75)` (`Tests/ApusKitCoreTests/CoreTests.swift`),
fixed by hoisting it to `let expectedCost: Double = …`. It took the TSan gate down with it — same
compile error, so a red TSan run is not automatically a data race.
Impact: comparing a typed value against a chain of *untyped* numeric literals makes the type checker
enumerate overloads across the chain, inside a macro expansion whose budget is already partly spent.
6.3 copes, 6.2 does not — so this class of break is invisible locally by construction. PRD gates
flip only on a link to a passing CI run (PROG-2); a local pass is evidence for you, never for the
gate.
Do: name the type once — hoist multi-term literal arithmetic into a `let x: Double = …` above the
`#expect`. Say "green locally" and leave the gate un-flipped until CI is observed.
Avoid: multi-term untyped literal arithmetic inside `#expect`/`#require`, and marking a milestone ✅
from a local run.

## Five CI gates are deliberately absent

Symptom: TRD §7 lists ten gate rows; `.github/workflows` holds five workflows.
Evidence: `docs/ci-deferrals.md` names each missing row and the milestone that gives it a
subject — Soundness, API breakage, traits matrix, nightly fuzz, nightly benchmarks. As of the M1
wire-format slice, Benchmarks has a real subject (the two kernels) and is the next one due; Fuzz
still waits for M2's JSONL codec, since that row fuzzes all three kernels together.
Impact: an agent "fixing" the gap ships inert or always-skipped jobs that hide real failures
later.
Do: read `docs/ci-deferrals.md` before adding a workflow; add the row when its milestone lands.
Avoid: treating the five missing workflows as an oversight.

## The NIO and MCP traits are declared but inert

Symptom: building with `--traits NIO` or `--traits MCP` changes nothing.
Evidence: `docs/ci-deferrals.md` (traits-matrix row) — no source file is conditionalized on
either trait yet.
Impact: a traits-matrix CI job would build the identical tree four times and prove nothing.
Do: expect traits to become live at M1 (NIO) and M4 (MCP).
Avoid: assuming trait-gated code already exists.

## `.agentwork/` needs `.gitignore`, not `.git/info/exclude`

Symptom: in a fresh clone, a `build-feature` run leaves `.agentwork/` untracked and the next
run's clean-tree preflight refuses to start.
Evidence: `.gitignore` now lists it; before 2026-08-25 it was only in `.git/info/exclude`, which
is machine-local and never travels with a clone.
Impact: the brain cache and per-run plan artifacts would get swept into an unrelated commit, or
block the workflow outright.
Do: keep `.agentwork/` in `.gitignore`.
Avoid: relying on a local exclude for anything another clone must also ignore.

## Public async APIs must declare where they run — **Safeguard**

Symptom: a new `public` async function compiles fine and violates CC-2.
Evidence: `Sources/ApusKitTools/Tool.swift:31` — `@concurrent` on `Tool.execute`.
Impact: where code runs is an API contract; adding the annotation later is a source-breaking
change for consumers, and CC-3's Sendable audit is what makes it SemVer-visible.
Do: annotate every public async API `@concurrent` (always off-caller) or `nonisolated(nonsending)`
(runs on the caller's actor), and update `docs/sendable-audit.md` in the same change.
Avoid: leaving isolation implicit on a public async declaration.

## A `package` declaration needs `package import`, not `internal import`

Symptom: adding a `package`-access helper whose signature mentions a type from another ApusKit
target fails to build with `error: method cannot be declared package because its result uses an
internal type` — even though the file compiled fine until that one declaration was added.
Evidence: `Sources/ApusKitProviders/URLSessionTransport.swift:1` is `package import ApusKitCore`,
not `internal import`. Downgrading it in a scratch copy fails at `URLSessionTransport.swift:77`
(`mapNon2xxResponse` returns `StreamError?`).
Impact: `AGENTS.md` says "use `internal import` for every non-API dependency (DEP-2)", and
ACC-1/PKG-8 push cross-target internals onto `package` access — so the two rules collide the first
time a `package` seam touches a dependency's type, and the error names the *declaration*, not the
import, which sends you looking in the wrong file.
Do: raise the import to `package import` for the module whose types appear in a `package`
signature. An import's access level must be at least that of any declaration using it.
Avoid: widening the helper to `public` (that leaks a test-only seam onto the public surface and
into DocC) or demoting it to `internal` (it stops being reachable from the test target).

## `.agentwork/` assumption IDs are not TRD rule codes — **Safeguard**

Symptom: a production doc comment cites a rule code such as `ASM-3` that reads exactly like a real
one (`CC-2`, `DI-3`, `WIRE-1`) but exists in no normative document, and ships as a dangling
reference in the generated DocC.
Evidence: commit `e4b319c` removed three such citations from
`Sources/ApusKitProviders/URLSessionTransport.swift`; `cat TRD.md PRD.md AGENTS.md | grep -c 'ASM-'`
prints `0`. The ID came from a per-run plan's assumption table in `.agentwork/`, quoted into a task
brief and then copied into the code as if it were normative.
Impact: `AGENTS.md` mandates citing a rule code for every judgment call, and nothing in CI
validates that the cited code exists. A plan-local assumption number silently becomes a permanent,
unresolvable citation in the public API documentation — and `ASM-n` is renumbered per run, so it
does not even mean the same thing twice.
Do: cite only codes that appear in `TRD.md`/`PRD.md`/`AGENTS.md`. Check before committing:
`grep -oh '[A-Z]\{2,5\}-[0-9]\+' <files> | sort -u | while read c; do grep -q "$c" TRD.md PRD.md AGENTS.md || echo "BOGUS: $c"; done`
Avoid: putting an `ASM-n` id into a task brief's notes at all — an implementer will cite it.

## `JSONSerialization` is not a JSON well-formedness oracle

Symptom: a round-trip check on the partial-JSON accumulator reports failures on inputs that are
valid RFC 8259 — `"1e309"` and `"8e982"` fail with `NSCocoaErrorDomain Code=3840 "Number wound up
as NaN"`, while `"-1e400"` decodes fine as `-inf`. It also rejects string content the naive rule
"just don't end on a high surrogate" would accept: `"\udc00"`, `"\ud83dX"` and `"\ud83dA"` all
fail with Code=3840.
Evidence: `Sources/ApusKitWireFormat/PartialJSON.swift:239` — `safeStringBodyEnd` tracks a
`pendingHighSurrogate` for exactly this; `:154` — `repairedNumberEnd` deliberately passes an
over-range exponent through unchanged rather than corrupting a valid value.
Impact: WIRE-2 makes these kernels the nightly fuzz targets. A harness using `JSONSerialization`
as its "is this well-formed?" oracle reports false positives on valid over-range numbers, and — if
it only checks the trailing byte — misses real surrogate defects.
Do: treat `JSONSerialization` as *a* decoder, not *the* grammar. Exclude over-range exponents from
the oracle explicitly, and test the full surrogate pairing rule.
Avoid: "fixing" the accumulator to clamp `1e309` so the oracle goes green — that mutates a value
the caller sent, which is a worse bug than the false alarm.

## A loopback socket fixture needs `SO_NOSIGPIPE` and a time limit

Symptom: two failure shapes from the same kind of test. (a) The whole `swift test` process dies
with no failure report, because `send()` to a client that already hung up raises `SIGPIPE` on
Darwin. (b) A regression makes the suite hang forever instead of failing, because the assertion
under test is "a chunk arrives *before* the response ends" and a buffering implementation never
delivers a first chunk at all.
Evidence: `Tests/ApusKitProvidersTests/URLSessionTransportTests.swift:309` sets `SO_NOSIGPIPE` on
the accepted socket; the same file carries `.timeLimit(.minutes(1))` on every socket-driven test.
Impact: incremental delivery is only observable against a connection held open, and TEST-2 forbids
URLProtocol stubbing — a real loopback socket is the sanctioned route, so both traps are
load-bearing. Swift Testing's time-limit granularity is whole minutes, so a deliberate mutation run
against such a test costs ~61s; that is expected, not a hang.
Do: set `SO_NOSIGPIPE` on every accepted socket, and put `.timeLimit(.minutes(1))` on any test
whose failure mode is "waits forever".
Avoid: `HTTPStreamRequest(url:)` in a fixture aimed at a GET-only server — `method` defaults to
`"POST"`, the server answers 501, and it surfaces as `StreamError(.provider, "...HTTP status 501")`,
which reads like a status-mapping bug rather than a harness bug.

## A new target leaves sibling consumer `.build` caches stale

Symptom: after adding a target, the consumer loop fails on packages that do not even reference it
— `error: no such module 'ApusKitWireFormat'` from `mainactor-consumer` and `umbrella-consumer`.
Copying a checkout elsewhere gives the same class of failure with a different message:
`error: precompiled file '.../ModuleCache/....pcm' was compiled with module cache path
'/Users/.../ApusKit/.build/...', but the path is currently '...'`.
Evidence: every consumer keeps its own `.build`, resolved against
`.package(name: "ApusKit", path: "../../..")`.
Impact: it reads as a real DAG or manifest defect and invites a hunt through `Package.swift` when
the root package is fine.
Do: `rm -rf Examples/consumers/*/.build` after adding or renaming a target, then re-run the
consumer loop. Same after copying the repo anywhere.
Avoid: concluding the umbrella re-export or the product wiring is broken before clearing the
caches — CI never sees this, because it always starts from a fresh checkout.

## `SSEParser` holds a trailing bare `CR` until the next chunk

Symptom: `parser.feed(Array("data: hi\r\r".utf8))` returns `[]`. The event only appears on a later
call — `parser.feed(Array("x".utf8))` then returns `[SSEEvent(data: "hi")]`. A single-`feed` test
of a CR-terminated stream looks like the parser dropped the event.
Evidence: `Sources/ApusKitWireFormat/SSEParser.swift:130` — `nextLineBounds` treats a `CR` in the
last buffer position as an incomplete line and stashes `searchIndex`, because that byte may still
turn out to be the first half of a `CRLF`.
Impact: this is correct, not a bug — SSE allows LF, CRLF and bare CR, and only the next byte
disambiguates. But a test that feeds one chunk ending in `CR` and asserts on the return value fails
for the wrong reason, and sends you debugging the dispatch logic.
Do: end a bare-CR fixture with a following byte, or call `feed` a second time, before asserting.
Avoid: "fixing" the parser to dispatch on a trailing `CR` — that splits a `CRLF` straddling a chunk
boundary into two terminators and injects a spurious blank line, dispatching an event early.

## `PartialJSONAccumulator.snapshot()` is not append-monotone

Symptom: treating the repaired snapshot as a growing prefix corrupts the arguments text. A probe
against a copy of `Sources/ApusKitWireFormat/PartialJSON.swift` prints: an empty accumulator →
`null`; after `{"a` → `{}`; after a further `":1` → `{"a":1}`; and `{"k":"v\` → `{"k":"v"}` — the
dangling `\` is *dropped*, not carried.
Evidence: `Sources/ApusKitWireFormat/PartialJSON.swift:32` — `snapshot()` re-repairs the whole
buffer on every call. The only correct consuming pattern in the tree is
`Sources/ApusKitProviders/AnthropicMessagesAPI.swift:419-461` (`ToolCallArgumentBuffer`).
Impact: a repair is a whole-buffer rewrite, so byte *i* of one snapshot need not be byte *i* of the
next, and a snapshot can be *shorter* than the raw bytes fed in. An adapter that appends snapshots,
or that appends "the repair suffix" at the end of a raw passthrough stream, emits invalid JSON. And
`null` for a tool call that received zero `input_json_delta` fragments is a bogus arguments payload,
not an empty one.
Do: emit only the longest common prefix of the raw bytes and the current snapshot as it grows
(never cutting a multi-byte scalar in half), then emit the repair remainder once at block close —
the `ToolCallArgumentBuffer` pattern. Special-case "no fragments at all" so `null` never ships.
Avoid: yielding `accumulator.snapshot()` as a delta payload, and any assumption that `append` only
ever extends what `snapshot()` returned last time.

## `.toolCallDelta` payloads are concatenated by the loop — never send a snapshot

Symptom: tool arguments arrive doubled (`{"a":1}{"a":1}`) as soon as an adapter "helpfully" yields
the accumulated arguments instead of only what is new.
Evidence: `Sources/ApusKitAgent/RunLoop.swift:129` —
`toolCalls[contentIndex]?.argumentsJSON += argumentsJSONDelta`.
Impact: `argumentsJSONDelta` is an append-only contract, and it is the whole of what makes the
three built-in adapters interchangeable. They agree on nothing else here:
`Sources/ApusKitProviders/AnthropicMessagesAPI.swift:313` withholds the uncommitted tail of each
`input_json_delta` and flushes the repair remainder at `:388`, so its deltas are *not* verbatim
wire fragments, while `Sources/ApusKitProviders/OpenAICompletionsAPI.swift:147` and
`Sources/ApusKitProviders/OpenAIResponsesAPI.swift:288` forward the provider's delta unchanged.
(The dead `argumentAccumulators` this entry used to warn about no longer exists — commits `ecf3ee2`
and `6fc16a6` removed it; `grep -c argumentAccumulators Sources/ApusKitProviders/OpenAIResponsesAPI.swift`
prints `0`.)
Do: yield only what is new since the last `.toolCallDelta` for that `contentIndex`. Assert on the
*concatenation* of a content index's deltas, not on individual fragments.
Avoid: assuming all three adapters emit the provider's fragments byte-for-byte — an inline snapshot
that pins verbatim fragments breaks the moment an adapter changes how much it withholds.

## Catalog base URLs are deliberately not uniform

Symptom: pointing an Anthropic entry at `https://api.anthropic.com/v1` POSTs to
`https://api.anthropic.com/v1/v1/messages`; trimming `/v1` off an OpenAI-compatible entry POSTs to
`<host>/chat/completions`. Both 404, and both read like a catalog typo.
Evidence: `Sources/ApusKitProviders/AnthropicMessagesAPI.swift:64` appends the whole
`v1/messages` path, while `Sources/ApusKitProviders/OpenAICompletionsAPI.swift:282` appends only
`chat/completions` and `Sources/ApusKitProviders/OpenAIResponsesAPI.swift:97` only `responses`. So
`Sources/ApusKitProviders/ProviderCatalog.swift:32` stops at the host for Anthropic while `:65`,
`:92`, `:114` and `:136` each carry their vendor's version path.
Impact: "the base URL" means a different amount of the path per `APIImplementationID`. A
field-by-field assertion on a catalog constant cannot catch this class of bug — only the URL
actually POSTed can.
Do: when adding a catalog entry or overriding `baseURL`, derive it from the *adapter's* path
suffix. Assert it by resolving through `ProviderRegistry` with the real adapter and reading
`RequestSpyLog` — the `postedURL(for:model:)` helper at
`Tests/ApusKitProvidersTests/ProvidersTests.swift:218`.
Avoid: normalising every catalog base URL to end in `/v1` for tidiness.

## A hand-written SSE transcript needs TWO trailing blank lines

Symptom: an inline `"""…"""` transcript ending in a `data:` line plus one blank line dispatches
zero events. The test sees an empty stream and it reads like a parser regression.
Evidence: a probe against a copy of `Sources/ApusKitWireFormat/SSEParser.swift` — one blank line
produces the string `"data: hi\n"` and `feed` returns 0 events; two blank lines produce
`"data: hi\n\n"` and `feed` returns 1. Swift drops the newline immediately before the closing
`"""`, so the visually-blank last line only terminates the `data:` line, never the event.
Impact: SSE dispatches on a blank line, so the final (usually the only interesting) event of a
hand-written literal is silently never delivered. Recorded fixtures under `Tests/Fixtures` are
unaffected — they are real bytes on disk.
Do: end an inline transcript with two blank lines before the closing delimiter, or build it with
`events.joined(separator: "\n\n")` plus an explicit trailing `"\n\n"`.
Avoid: assuming the literal's own trailing newline terminates the event. See also the bare-`CR`
hold-back entry — the same class of "the parser is right, the fixture is short" failure.

## `Tests/Fixtures/conformance-baseline.yml` gates nothing

Symptom: the file declares "A fixture failure that is NOT listed here fails CI" and "This file is
the ONLY place a known deviation may be recorded", but
`grep -rn baseline Tests Sources .github Package.swift` matches exactly one line — the file's own
comment. No test and no workflow ever reads it.
Evidence: `Tests/Fixtures/conformance-baseline.yml:1-5`; the grep above returns a single hit.
Impact: it reads as an enforced TEST-3 gate. Adding an entry to `deviations: []` therefore changes
nothing, and nothing notices if an adapter's fixture assertions are weakened or deleted.
Do: treat it as a record of fixture provenance and intent. Real enforcement lives in the
per-adapter suites in `Tests/ApusKitProvidersTests`; if the baseline is meant to bind, a test has
to load it.
Avoid: recording a known deviation there and believing CI now tolerates it.

## "The adapter ignores this field" needs an indistinguishability test, not an absence argument

`LLMRequest.cacheBreakpoints` is provider-neutral (PROV-2): the Anthropic adapter renders it as
`cache_control`, the two OpenAI adapters ignore it. The obvious reasoning — "the field never appears
in `OpenAICompletionsAPI.makeHTTPRequest`, so it cannot affect the request" — is not a test, and the
suite went green for a whole run without one. A red-team mutant that made the Completions builder
throw on a non-empty set, and the Responses builder emit a bogus `GET`, survived all 134 tests.

The assertion that kills it compares two requests built from identical messages, one with hints and
one without, and requires them to be *indistinguishable*: same URL, method and headers, and an equal
**decoded** JSON body (`Tests/ApusKitProvidersTests/OpenAICompletionsAPITests.swift`,
`OpenAIResponsesAPITests.swift`). Compare the body as parsed JSON, not as bytes — the encoder makes
no promise about key order, and a byte comparison fails intermittently on two semantically identical
194-byte bodies.

`OpenAIResponsesAPI.makeHTTPRequest` is `internal`, so its suite asserts the request through
`RequestSpyLog` + `FixtureTransport` instead of calling the builder directly; the Completions one is
`package` and can be called. Any future "this adapter ignores X" claim needs the same treatment.

## `ValidationResult.errors` names the keyword, not the violation

Symptom: an argument breaking `minimum` yields exactly **one** top-level error whose message is
`Validation failed for keyword 'properties'`. The real cause — `#/count: … is below minimum …` —
sits one level down in `ValidationError.errors`, so a flat `errors.map(\.message)` builds an error
`ToolResult` that names nothing.
Evidence: `Sources/ApusKitTools/AnyAgentTool.swift:94-102` recurses to the leaves. Replacing
`let nested = violations(in: error.errors ?? [])` with `let nested: [String] = []` in a temp copy
fails `AnyAgentToolTests/schemaViolationNeverReachesExecute` with
`Expectation failed: (message → "Validation failed for keyword 'properties'").contains("count")`.
Impact: TOOL-1 requires the error result to *name* the violation. The flat version still reports
`isValid == false` and short-circuits correctly, so the rule reads as met while the model gets no
way to correct its call.
Do: flat-map to the leaves and fall back to a node's own message only when it has no nested errors.
`JSONPointer.description` renders the root as `"#"`, not `""` — skip the location prefix for
root-level violations (`:100`).
Avoid: `validation.errors?.map(\.message)`, and assuming one violated constraint produces one
top-level error.

## A type-mismatch argument cannot prove schema validation runs

Symptom: a test feeding `{"count":"not-a-number"}` to `AnyAgentTool.execute`, asserting an error
result and `callCount == 0`, stays green with TOOL-1 validation deleted entirely. It proves
`JSONDecoder`'s pre-existing behaviour, not the new schema check.
Evidence: mutating `guard validation.isValid else {` to `guard true else {` in a temp copy leaves
`AnyAgentToolTests/mistypedArgumentsNeverReachExecute` passing (exit 0) while
`AnyAgentToolTests/schemaViolationNeverReachesExecute` fails (exit 1).
`Tests/ApusKitToolsTests/ToolsTests.swift:18-26` carries `CountArguments` with
`@NumberOptions(.minimum(10))` for exactly this reason.
Impact: decoding happens after validation and rejects wrong JSON types on its own, so every
"wrong type" fixture is inert as TOOL-1 coverage. A suite built only from them reports schema
enforcement it never exercises.
Do: assert schema enforcement with a value that **decodes cleanly and violates a schema-only
constraint** — `{"count":5}` against `minimum: 10`. Confirm by mutation: with validation disabled,
the test must go red.
Avoid: type-mismatch, missing-required and malformed-JSON fixtures as proof that validation ran —
all three are caught by `JSONDecoder` regardless.

## A re-exported type still needs its defining module imported (SE-0444)

Symptom: `ToolDefinition(name: "x", description: "y", parameters: ["type": "object"])` fails with
`error: initializer 'init(stringLiteral:)' is not available due to missing import of defining
module 'JSONSchema' [#MemberImportVisibility]` — even though `import ApusKitProviders` alone makes
the `JSONValue` *type* visible and the file names no other JSONSchema symbol.
Evidence: `Package.swift:8` enables `MemberImportVisibility` for every target; the type is
re-exported by `Sources/ApusKitProviders/ToolDefinition.swift:2` (`public import JSONSchema`).
Deleting `import JSONSchema` from `Tests/ApusKitProvidersTests/OpenAICompletionsAPITests.swift:12`
in a temp copy fails `swift build --build-tests` with the error above.
Impact: SE-0444 scopes *members* — including the `ExpressibleBy*Literal` initializers — to files
that import the module declaring them, so a re-export gets you the name and nothing else. The error
points at the literal, not the import, which sends you hunting for a type mismatch.
Do: import the module that declares the member (`import JSONSchema` alongside
`import ApusKitProviders`). The mirror rule holds for exposure: a `public` stored property typed by
a dependency forces `public import` of that module — `Sources/ApusKitTools/AnyAgentTool.swift:3` is
`public import JSONSchema` for `public let schema: JSONValue`, while `JSONSchemaBuilder` stays
`internal import` at `:4` because none of its types reach the surface.
Avoid: assuming a spare import will be caught by warnings-as-errors — adding an unused
`internal import JSONSchema` to `Sources/ApusKitProviders/OpenAIResponsesAPI.swift` in a temp copy
built clean, exit 0, zero warnings. Nothing here polices unused imports.

## Three adapters, three request-body builders — a new `LLMRequest` field lands three ways

Symptom: a provider-neutral field added to `LLMRequest` renders in two adapters and silently
vanishes in the third, with a green build and no warning.
Evidence: Anthropic and Responses build `[String: Any]` for `JSONSerialization`, so "absent" means
never inserting the key — `Sources/ApusKitProviders/AnthropicMessagesAPI.swift:101` and
`Sources/ApusKitProviders/OpenAIResponsesAPI.swift:133`, both guarded by `if !request.tools.isEmpty`.
Chat Completions encodes a typed `RequestBody: Encodable`, so "absent" means `tools: [Tool]?` left
`nil` (`Sources/ApusKitProviders/OpenAICompletionsAPI.swift:305`, property at `:389`) **and** the
property must be listed in the private `CodingKeys` (`:392`). Probe:
`struct Body: Encodable { var model: String; var tools: [String]?; private enum CodingKeys: String,
CodingKey { case model } }` encodes `Body(model: "m", tools: ["a"])` to `{"model":"m"}` — no error,
no warning.
Impact: an explicit `CodingKeys` enum opts out of synthesis for anything it omits, so a forgotten
`case` ships a request that never mentions the field. And because the two mechanisms differ, an
edit that "unifies" the builders breaks one of the two empty-array omission tests.
Do: add the field to all three builders, then assert the **decoded** JSON body of a request built
with and without it, per adapter — the same indistinguishability pattern used for
`cacheBreakpoints`. `OpenAIResponsesAPI.makeRequestBody` is `internal`, so its suite must go through
`FixtureTransport` + `RequestSpyLog`; `OpenAICompletionsAPI.makeHTTPRequest` is `package` and can be
called directly.
Avoid: assuming `Encodable` synthesis picks up a new stored property when the type declares its own
`CodingKeys`, and assuming all three adapters omit an empty collection the same way.

## `${PIPESTATUS[0]}` is empty in zsh — a piped `swift test` reads as a pass

Symptom: `swift test | tail -3` followed by `echo ${PIPESTATUS[0]}` prints an empty string, and
`$?` is `0` because it belongs to `tail`. A failing suite reports as green.
Evidence: `zsh -c 'false | tail -1; echo "PIPESTATUS0=[${PIPESTATUS[0]}] pipestatus=[${pipestatus[1]}] q=[$?]"'`
prints `PIPESTATUS0=[] pipestatus=[1] q=[0]`. `$SHELL` here is `/bin/zsh`; `PIPESTATUS` is a bashism
and zsh spells it `$pipestatus`, 1-indexed.
Impact: the same class of silent green as the `--filter` trap — an agent that pipes a run through
`tail`/`grep` to shorten the output loses the only signal that matters.
Do: redirect and read the real code — `swift test > run.log 2>&1; echo "EXIT=$?"; tail -3 run.log`.
Swift Testing's summary (`Test run with N tests in M suites passed`) is mixed across stdout and
stderr, so grep the `2>&1` capture, not stdout alone.
Avoid: `${PIPESTATUS[0]}` in any command here; if you must pipe, use `${pipestatus[1]}`.

## `ToolCancellationSignal` is `Task.isCancelled` in a wrapper, not a stored flag

Symptom: a tool that hands its `signal` to a detached task, or that suspends on a
`CheckedContinuation` expecting cancellation to wake it, never observes an abort — while an
otherwise identical tool polling `signal.isCancelled` in its own loop sees it immediately.
Evidence: `Sources/ApusKitTools/ToolSupport.swift:12-14` — `isCancelled` is literally
`{ Task.isCancelled }`, evaluated against whichever task reads it. The F2.4 fake that does observe
cancellation polls cooperatively (`CancellationObservingTool` in `Tests/Shared/TestSupport.swift`),
driven by `Tests/ApusKitAgentTests/AgentTests.swift:496`.
Impact: the value carries no state of its own, so passing it across a task boundary reads the wrong
task's cancellation. `abort()` cancels the enclosing task (LOOP-6); it does not resume a suspended
continuation, so a tool awaiting one hangs until its `.timeLimit` fires.
Do: poll `signal.isCancelled` on the task running `execute`, between units of work, and return a
partial `ToolResult`. Wrap any real suspension in `withTaskCancellationHandler`.
Avoid: `Task.detached { signal.isCancelled }`, and treating the signal as a latch you can await.

## `headTruncate`'s two caps are on different axes — step by `linesReturned`, not `limit`

Symptom: paging a large tool output with `offset += limit` silently skips content, and for a text
under 2000 lines the "obvious" continuation call returns an *empty* window with
`isTruncated == false` while ~50 KB goes unserved.
Evidence: `Sources/ApusKitTools/Truncation.swift` — `offset`/`limit` count **lines**, `maxBytes`
counts **bytes**. Whichever fires first ends the window, so when the byte cap wins, the window
covers fewer lines than `limit` asked for. This shipped broken in the M1c typed-tools slice
(`offset`/`limit` indexed lines while `maxBytes` sliced the joined window's raw UTF-8) and was
fixed in `32e2bda`, which added `TruncatedText.linesReturned` and made the byte cap end on a line
boundary.
Impact: `limit` is what you *asked for*; `linesReturned` is what you *got*. Only the second is a
valid continuation step. Before the fix, the byte cap could also cut mid-scalar —
`headTruncate("aaééé", limit: 10, maxBytes: 3).text` was `"aa\u{FFFD}"`.
Do: continue with `offset += result.linesReturned`, and stop on `!result.isTruncated`. A window
with `isTruncated == true` and `linesReturned == 0` means one line alone exceeds `maxBytes` —
paging cannot advance, and `TRUNC-1` leaves spilling that payload to the consumer.
Avoid: `offset += limit`, and any new byte-level cut that does not back off over UTF-8
continuation bytes (`b & 0xC0 == 0x80`) the way `Truncation.swift`'s `scalarAlignedPrefix` and
`AnthropicMessagesAPI`'s `ToolCallArgumentBuffer` both do.

## Xcode's `swift` is not in `Contents/Developer/usr/bin` — **Safeguard**

Symptom: every workflow fails in 9–15 seconds, before compiling anything, with
`::error::No installed Xcode ships Swift 6.2 or later; Package.swift (swift-tools-version: 6.2)
cannot be parsed.` — on an image that demonstrably ships four of them.
Evidence: the shared "Select a Swift 6.2+ toolchain" step probed
`$app/Contents/Developer/usr/bin/swift`, which exists in no Xcode; that directory holds
`xcodebuild`, `actool`, `atos`. The driver is at
`$app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift`. So
`[ -x "$bin" ] || continue` skipped every candidate and the loop fell through to its own `exit 1`.
`gh api repos/actions/runner-images/contents/images/macos/macos-15-Readme.md` lists Xcode 26.0.1,
26.1.1, 26.2 and 26.3 on `macos-15`, all Swift 6.2+. Fixed in commit `2c02c3b`; first green run
https://github.com/ApusKit/ApusKit/actions/runs/32883395354.
Impact: the error message blames the runner image, which sends you to bump `runs-on` or pin an Xcode
version — neither is the problem. This shipped in M0 and stayed broken through all of M1, because
the remote had no CI history and the selector was never once observed to *succeed*.
Do: probe the toolchain path. When adding a workflow, copy the corrected step from an existing one
— the block is duplicated verbatim in all five, so a fix must be applied five times
(`grep -c` to confirm).
Avoid: trusting a hand-rolled toolchain selector whose success path has never run. A guard that can
only fail is indistinguishable from a guard that works, until something needs it to pass.
