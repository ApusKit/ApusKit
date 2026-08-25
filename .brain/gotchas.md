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

## Local green is not CI green

Symptom: `swift test` passes locally on a toolchain the package does not target.
Evidence: local toolchain is Swift 6.3.2; `Package.swift` declares `swift-tools-version: 6.2`,
and `.github/workflows/tests.yml` runs a 6.2 leg plus a nightly leg installed via swiftly
(commit `570a9cb`).
Impact: PRD gates flip only on a link to a passing CI run (PROG-2). A local pass is evidence for
you, never evidence for the gate.
Do: say "green locally" and leave the gate un-flipped until CI is observed.
Avoid: marking a milestone ✅ from a local run.

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
`Sources/ApusKitProviders/AnthropicMessagesAPI.swift:396-450`.
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
Evidence: `Sources/ApusKitAgent/RunLoop.swift:120` —
`toolCalls[contentIndex]?.argumentsJSON += argumentsJSONDelta`.
Impact: `argumentsJSONDelta` is an append-only contract, and it is the whole of what makes the
three built-in adapters interchangeable. They agree on nothing else here:
`Sources/ApusKitProviders/AnthropicMessagesAPI.swift:302` withholds the uncommitted tail of each
`input_json_delta` and flushes the repair remainder at `:363`, so its deltas are *not* verbatim
wire fragments, while `Sources/ApusKitProviders/OpenAICompletionsAPI.swift:146` and
`Sources/ApusKitProviders/OpenAIResponsesAPI.swift:276` forward the provider's delta unchanged.
`OpenAIResponsesAPI.swift:229`'s `argumentAccumulators` is written at `:273` and read nowhere, so
that adapter's doc-comment promise of a repaired snapshot does not currently hold.
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
