---
format: 1
register: trd
status: draft
fingerprint: 204a0fe916e0
docs: [TRD.md, PRD.md]
reviewed_commit: 71c01a5
repo_state: scaffolded
lenses: consistency, gates, underspecified, external-deps, boundary
lens_failures:
sealed_at:
sealed_by:
engine: build-feature 1.3.0
---

# Spec review — TRD.md (with PRD.md)

Adjudications of this document, made by a human, applied by every later run. IDs are NOT rule
codes: never cite `spec-NNN` in code or in a task brief.
Is this file current?  From this directory: `cat TRD.md PRD.md | shasum | cut -c1-12` must equal `fingerprint`.

## Decisions

### spec-001 · blocker · external_dep
key: external_dep@F3.2+M2+SESS-1|- **sess-1** wire-compat is a tested guarantee: a real pi v3 session file loads,
where: TRD.md:160
refs: SESS-1, F3.2, M2
quote: - **SESS-1** Wire-compat is a tested guarantee: a real pi v3 session file loads, rebuilds context equivalently, and round-trips losslessly (fixtures in `Tests/Fixtures/`, deviations only via `conformance-baseline.yml`).
finding: The M2 gate can only be closed by an artefact produced by another project (a real pi v3 session file), and neither document names a source, a licence under which it may be vendored, nor a fallback if none can be obtained. A planner either blocks M2 indefinitely or silently substitutes an authored fixture, which is a different guarantee.
evidence: PRD.md:131 `- [ ] **Gate:** real pi session replays correctly (F3.2)`. Repo corroboration, /Users/gregor/projects/ApusKit/Tests/Fixtures/conformance-baseline.yml: "No real, licensed pi v3 session file exists in this repo, so `Tests/Fixtures/sessions/pi-v3-session.jsonl` is authored from pi's PUBLIC v3 session-file format" and "SESS-1 stays open ... until a real pi v3 file can be substituted for this authored one."
question: Under what source and licence terms will a real pi v3 session file be obtained for the M2 gate, or must SESS-1's evidence be restated against an artefact this project can produce itself?
options: [TRD] Name a concrete acquisition path for the artefact (permission/licence from the pi project, or a recorded run of pi itself) and record its provenance requirement in SESS-1 (recommended) / [TRD] Redefine SESS-1's evidence as a reproducible in-repo procedure (e.g. generating a session with pi at verification time) so no third-party artefact needs vendoring
status: open

### spec-002 · major · underspecified
key: underspecified@ACC-2+F5.1+LOOP-2|- **loop-2** per turn: inject steering → `transformcontext` → convert to llm for
where: TRD.md:173
refs: LOOP-2, F5.1, ACC-2
quote: - **LOOP-2** Per turn: inject steering → `transformContext` → convert to LLM form (filtering UI-only entries) → provider stream → mutate the partial `AssistantMessage` per event → execute tools → `prepareNextTurn` → `shouldStopAfterTurn`.
finding: `transformContext`, `prepareNextTurn` and `shouldStopAfterTurn` are named as normative loop steps but appear nowhere else: they are absent from the hook-bus registration points, from the `AgentExtension`/`ExtensionContext` surface and from ACC-2's conformable list. A planner either exposes them as three more public extension points (each needing EVO-1 defaults and ACC-3 contracts) or implements them as private loop internals, which changes what a consumer can build under F5.1.
evidence: TRD.md:180 lists the registration points as "`toolCall` (can block/deny), `toolResult` (can modify), `beforeProviderRequest`, `afterProviderResponse`, `sessionBeforeCompact`, `sessionStart`, `sessionShutdown`, `modelSelect`" — none of the three; ACC-2 at TRD.md:241 names only `APIImplementation`, `Tool`, `SessionStore`, `StreamingHTTPTransport`, `AgentExtension`, hook handler types.
question: Are `transformContext`, `prepareNextTurn` and `shouldStopAfterTurn` public extension points of the loop, or private internal steps of the Agent actor?
options: They are additional hook-bus points, registered like the other eight and covered by ACC-3 contracts (recommended) / They are private internals of the loop, and the eight listed hooks remain the whole extension surface
status: open
affects: ApusKitAgent, F5.1, M3

### spec-003 · major · underspecified
key: underspecified@F1.4+PROV-3+TRD§3.3|- built-in api implementations — m1: `anthropic-messages` (incl. `cache_control`
where: TRD.md:126
refs: F1.4, PROV-3, TRD§3.3
quote: - Built-in API implementations — M1: `anthropic-messages` (incl. `cache_control` prompt-caching passthrough), `openai-completions`, `openai-responses`. Built-in provider catalog: Anthropic, OpenAI, Google, OpenRouter, Groq, Ollama/local (any OpenAI-compatible baseURL).
finding: A built-in catalog whose entries carry `models: [ModelInfo]` with pricing needs a source for those prices, and neither document names one: pi's analog is a fetched/bundled models.json, while DI-3 forbids `URLSession.shared` in logic and PKG-5 lists no data dependency. One reader compiles a static price table into the library (and inherits a staleness problem plus a SemVer question every time a vendor changes prices), another ships an empty-priced catalog that consumers must populate, and a third fetches a catalog at runtime — three different public APIs for F1.4.
evidence: TRD.md:130 "- **PROV-3** Cost is computed from `ModelInfo` pricing — never hardcoded." reads as forbidding hardcoded prices, while PRD.md:21 requires cost "derived from a model catalog with pricing"; TRD.md:111 `public var models: [ModelInfo] // id, context window, pricing → Usage cost` gives the field but no provenance, and PKG-5 lists no catalog dependency or bundled resource.
question: Where do the built-in catalog's model IDs, context windows and prices come from — a table compiled into the library, a bundled data file, or a catalog the consumer supplies?
options: A compiled-in table refreshed by ordinary releases, with a stated SemVer policy for price changes (recommended) / A bundled resource file (pi's models.json analog) loaded at start-up, keeping data out of source
status: open
affects: ApusKitProviders, F1.4, M1

### spec-004 · major · underspecified
key: underspecified@F10.3+PKG-6+TEST-6|- **test-6** **conformance kit** ships as a product: a reusable swift testing su
where: TRD.md:270
refs: TEST-6, F10.3, PKG-6
quote: - **TEST-6** **Conformance Kit** ships as a product: a reusable Swift Testing suite that any third-party `APIImplementation`/`Tool`/`SessionStore`/`StreamingHTTPTransport` conformance runs against itself. Every built-in conformance runs it in CI.
finding: The Conformance Kit must ship as a product, yet §1's layout — introduced as "create exactly this" — contains no such directory, and PKG-6's DAG ("anything not listed is forbidden") grants it no imports, so as written it can neither exist nor depend on the protocols it tests. A planner either invents a new Sources target and edits three normative lists, or promotes Tests/Shared TestSupport into a shipped product, which drags the fakes named in TEST-2 onto the public surface — two very different distributions of the same M3 deliverable.
evidence: TRD.md:29-37 lists the nine Sources targets with no conformance target; TRD.md:40 puts TestSupport under `Tests/Shared/`, which SwiftPM cannot expose as a library product; TRD.md:58 PKG-6 "Dependency DAG (arrows = \"may import\"; anything not listed is forbidden)" has no row for it; `ls Sources` shows the seven targets built so far, none of them a kit.
question: Where does the Conformance Kit live — a new Sources library target added to the layout and the PKG-6 DAG, or the existing Tests/Shared TestSupport promoted to a shipped product?
options: A new `Sources/ApusKitConformance` library target with its own row in the §1 layout and the PKG-6 DAG (recommended) / Promote `Tests/Shared` TestSupport to a library product, accepting that TEST-2's fakes become public API under ACC-2
status: open
affects: M3, F10.3, ACC-3

### spec-005 · major · underspecified
key: underspecified@F2.3+TOOL-1+TRUNC-1|- **trunc-1** output truncation ported 1:1 from pi: head-truncate at **2000 line
where: TRD.md:151
refs: TRUNC-1, F2.3, TOOL-1
quote: - **TRUNC-1** Output truncation ported 1:1 from pi: head-truncate at **2000 lines or 50 KB, whichever comes first**; continuation supported via offset/limit parameters. Spilling oversized payloads to files is the CONSUMER's job (core stays sandbox-neutral).
finding: Neither document says whose parameters `offset`/`limit` are: the `Tool` protocol's Arguments are wholly consumer-defined and derived by `@Schemable`, so a framework-owned continuation would have to inject two properties into every tool's schema, while a tool-owned one means truncation is opt-in and F2.3's "is truncated" guarantee does not hold for third-party tools. One reader writes an automatic truncator inside `AnyAgentTool` plus schema injection; another ships a public `headTruncate` helper each tool must call — the guarantee differs at the user-facing surface.
evidence: TRD.md:137-143 declares `Tool` with only `name`, `description` and `execute(toolCallID:arguments:onUpdate:)` — no offset/limit and no truncation requirement; PRD.md:27 states "Oversized tool output is truncated predictably (2000 lines / 50 KB) with a continuation mechanism" as an unconditional capability.
question: Is truncation applied automatically by the tool-execution machinery with framework-owned offset/limit continuation parameters, or is it a helper each Tool implementation calls on its own arguments?
options: The registry truncates every ToolResult and owns the continuation parameters, so the guarantee holds for third-party tools too (recommended) / A public truncation helper plus a documented offset/limit convention that tool authors adopt, making the guarantee apply only to built-ins
status: open
affects: ApusKitTools, F2.3, M1

### spec-006 · major · underspecified
key: underspecified@F3.3+PKG-6+TRD§3.5|- **compaction** (numbers are normative, ported from pi): trigger when `contextt
where: TRD.md:158
refs: F3.3, PKG-6, TRD§3.5
quote: - **Compaction** (numbers are normative, ported from pi): trigger when `contextTokens > contextWindow − reserve` (default reserve **16 384**); cut-point keeps ~**20 000** recent tokens; iterative LLM summary + self-contained `retainedTail`.
finding: Compaction is placed in ApusKitSessions and requires an "iterative LLM summary", but PKG-6 lets Sessions import only Core and WireFormat, so the target that owns compaction cannot reach a provider; neither document says who supplies the summarizing model, who counts the tokens, or who fires the trigger that PRD F3.3 calls "automatically". One reader builds Sessions with an injected summarizer/token-counter seam called by the Agent; another puts the whole trigger-and-summarize path in ApusKitAgent and leaves Sessions a passive codec — incompatible public API families for the same capability.
evidence: TRD.md:62 `Core, WireFormat ← Sessions` under PKG-6 ("anything not listed is forbidden"); the hook list at TRD.md:180 offers `sessionBeforeCompact` but names no owner of the trigger; PRD.md:33 F3.3 says "Long conversations compact automatically". No LLM-call seam for summarization appears in §3.5, §3.6 or ACC-2's conformable list.
question: Which target owns the compaction trigger and the summarization call — ApusKitSessions behind an injected summarizer seam, or ApusKitAgent driving a passive Sessions codec?
options: Sessions owns policy and exposes an injected summarizer + token-counter seam that the Agent wires up (keeps PKG-6 intact, keeps §3.5's placement) (recommended) / ApusKitAgent owns trigger and summarization end to end; §3.5 keeps only the entry shape and the retained-tail rule
status: open
affects: ApusKitSessions, ApusKitAgent, M2

### spec-007 · major · underspecified
key: underspecified@F5.1+F7.2+WF-2|- **wf-2** sub-agents = child `agent` instances with scoped tool registries and 
where: TRD.md:207
refs: WF-2, F7.2, F5.1
quote: - **WF-2** Sub-agents = child `Agent` instances with scoped tool registries and budgets — created here, never in `ApusKitAgent`.
finding: "Budgets" is used as a normative feature in three places but never given a unit or an enforcement point, and `Usage` supplies both token counts and a computed cost, so token budget, currency-cost budget and turn/step count are all defensible readings. Two implementations diverge on the public type a workflow author writes and on when a sub-agent is stopped — mid-stream on token overrun versus between turns on a turn count.
evidence: PRD.md:54 "- **F7.2** Sub-agents with scoped tools and budgets."; PRD.md:44 F5.1 says "budgets, quotas and telemetry are buildable by consumers", which reads as consumer-built, while WF-2 makes them a shipped part of sub-agents. No definition of a budget unit appears in §3.1's `Usage`, §3.6 or §3.8.
question: What is a sub-agent budget measured in — tokens, currency cost, or turn/step count — and at which point in the loop is it enforced?
options: Token budget derived from `Usage`, enforced between turns via the existing hook bus (consistent with F5.1 calling budgets consumer-buildable) (recommended) / Currency-cost budget derived from `ModelInfo` pricing (PROV-3), enforced between turns
status: open
affects: ApusKitWorkflows, M5, F7.2

### spec-008 · major · underspecified
key: underspecified@DOC-4+EVO-2+TRD§7|| api breakage | `swift package diagnose-api-breaking-changes` vs pr base | no u
where: TRD.md:288
refs: TRD§7, EVO-2, DOC-4
quote: | API breakage | `swift package diagnose-api-breaking-changes` vs PR base | no undocumented breaks |
finding: The tool reports every break; "undocumented" implies a waiver channel that no document defines, so the gate's pass condition is not mechanically decidable. A planner either wires an allowlist file into the job (which §1's layout does not contain) or treats any break as a failure, and the two give opposite CI outcomes on the very PRs that carry intentional 0.x breaks.
evidence: TRD.md:236 EVO-2 governs deprecation but names no break-waiver artefact; §1's layout (TRD.md:16-49) contains no allowlist or breakage-baseline file; TEST-3 at TRD.md:267 explicitly rejects an unenforced deviations list for fixtures but provides no analogue here.
question: By what artefact does an intentional API break become "documented" and let this gate pass — a checked-in allowlist read by the job, a CHANGELOG entry, or a linked proposal?
options: A checked-in breakage allowlist consumed by the job, so the gate stays mechanical (recommended) / A linked `docs/proposals/` entry plus a maintainer override label on the PR
status: open
affects: TRD§7, M6

### spec-009 · major · contradicts
key: contradicts@F3.2+SESS-1+TEST-3|**sess-1** wire-compat is a tested guarantee: a real pi v3 session file loads, r⇄`tests/fixtures/conformance-baseline.yml` is a **provenance record** (where each
where: TRD.md:160 ⇄ TRD.md:267
refs: SESS-1, TEST-3, F3.2
quote: **SESS-1** Wire-compat is a tested guarantee: a real pi v3 session file loads, rebuilds context equivalently, and round-trips losslessly (fixtures in `Tests/Fixtures/`, deviations only via `conformance-baseline.yml`). ⇄ `Tests/Fixtures/conformance-baseline.yml` is a **provenance record** (where each fixture came from, and any deliberate divergence from vendor docs), read by humans, not by CI: no code loads it, and a `deviations:` list that nothing enforces would be worse than none because it reads like a waiver.
finding: SESS-1 makes `conformance-baseline.yml` the sole channel through which a divergence from pi's session format may be tolerated, while TEST-3 says nothing may load that file and that a `deviations:` list is harmful. One implementation lets the SESS-1 suite consult a deviations record and tolerate the listed divergences from a real pi file; the other permits no divergence at all and fails on any byte-level difference, so F3.2's "a pi session opens in ApusKit and vice versa" is either soft or hard depending on which line the planner reads.
evidence: Tests/Fixtures/conformance-baseline.yml `sessions.deviations` records that entry-kind discriminators on disk are camelCase Swift Codable tags (`branchSummary`, `customMessage`, `modelChange`, `thinkingLevelChange`) while TRD.md:156 names them normatively as `branch_summary, custom_message, model_change, thinking_level_change`; Tests/ApusKitSessionsTests/SessionConformanceTests.swift:24-25 cites SESS-1 "deviations only via conformance-baseline.yml" as licence for that divergence.
question: May the SESS-1 suite tolerate any recorded divergence from a real pi v3 session file, and if so which artefact declares and enforces that tolerance?
options: No tolerance: SESS-1 is byte-level wire compatibility with a real pi file and the baseline is provenance only, as TEST-3 says. (recommended) / Tolerance is allowed but must be enforced: a deviation is recorded in the baseline AND pinned by a named test, and TEST-3's "worse than none" clause is narrowed to unenforced lists.
status: open

### spec-010 · major · contradicts
key: contradicts@M0+PKG-4+TRD§7|## 7. ci gates (all required on every pr unless marked nightly)⇄- [x] first test suites + ci jobs live — test suites green locally, the five §7 
where: TRD.md:281 ⇄ PRD.md:116
refs: PKG-4, TRD§7, M0
quote: ## 7. CI gates (all required on every PR unless marked nightly) ⇄ - [x] First test suites + CI jobs live — test suites green locally, the five §7 workflows in `.github/workflows/` (2026-08-25)
finding: TRD §7 lists eight non-nightly rows and declares them all required on every PR (and §9 DoD item 2 requires all of them green), yet the PRD records M0 complete with exactly five workflows and calls them "the five §7 workflows"; the TRD itself undercuts its own table at PKG-4 by saying a traits-matrix job today "would prove nothing". One codebase wires Soundness, API breakage and Traits matrix as required jobs now (and M0 is not done); the other treats rows without a subject as deferred to a later milestone, which is what the repo did.
evidence: TRD.md:292 "| Traits matrix | build with no traits / `NIO` / `MCP` / both | compiles + tests |" versus TRD.md:56 "so a traits-matrix job today would build the identical tree four times and prove nothing."; TRD.md:321 "2. All §7 required CI jobs green; no new warnings (warnings are errors)."; `ls .github/workflows` shows only consumers.yml, docs.yml, format.yml, tests.yml, tsan.yml; docs/ci-deferrals.md defers Soundness, API breakage and Traits matrix to M1/M3/M4.
question: Are the §7 rows that have no subject yet (Soundness, API breakage, Traits matrix, and the nightly Fuzz and Benchmarks) required on every PR from M0, or required only from the milestone that gives each a subject?
options: Make §7 milestone-aware: mark each row with the milestone from which it becomes required, so the header's "all required on every PR" and PKG-4's "prove nothing" stop contradicting each other and the PRD's "five" is derivable from the TRD. (recommended) / Keep §7 as written (all eight required now): wire the missing three workflows and reopen M0's "package + CI up" deliverable in PRD §5.
status: open

### spec-011 · major · contradicts
key: contradicts@M1+PKG-4+TRD§3.3|both traits are **declared but inert** until their milestone lands (nio: m1's se⇄| m1 real streaming | §3.2 kernels, §3.3 three built-in implementations + transp
where: TRD.md:56 ⇄ TRD.md:311
refs: PKG-4, M1, TRD§3.3
quote: Both traits are **declared but inert** until their milestone lands (NIO: M1's second transport; MCP: M4) ⇄ | M1 Real streaming | §3.2 kernels, §3.3 three built-in implementations + transport seam, §3.4 tools (TOOL-1..3, TRUNC-1); gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations |
finding: PKG-4 assigns the NIO `AsyncHTTPClientTransport` to M1, but the §8 M1 row backs M1 with only "transport seam" and the PRD's M1 deliverables and checklist never mention a second transport. One implementation blocks M1 (and the Traits-matrix NIO leg) on shipping `AsyncHTTPClientTransport` behind the `NIO` trait; the other flips M1 with `URLSessionTransport` alone and leaves NIO for an unnamed later milestone.
evidence: PRD.md:122 "- [x] Transport seam + default URLSession transport (2026-08-25)" is the only transport item under M1 and the M1 checklist has no NIO line; TRD.md:125 "Shipped transports: `URLSessionTransport` (default, zero deps) and, behind trait `NIO`, `AsyncHTTPClientTransport`." names no milestone; Package.swift declares trait `NIO` but no `async-http-client` dependency.
question: Does M1 include the `AsyncHTTPClientTransport` behind the `NIO` trait, or is the second transport assigned to a later milestone?
options: Assign the NIO transport to a named later milestone (and move the Traits-matrix NIO leg's subject with it), leaving M1 on the URLSession transport alone. (recommended) / Keep NIO in M1: add it to the §8 M1 backing row and the PRD M1 deliverables/checklist so the gate is not silently narrower than PKG-4.
status: open

### spec-012 · major · contradicts
key: contradicts@M1+PROV-4+TEST-5|| m1 real streaming | §3.2 kernels, §3.3 three built-in implementations + transp⇄| m1 | real streaming | f1.1–f1.4, f2.1–f2.4 | live smoke vs anthropic and opena
where: PRD.md:82 ⇄ TRD.md:311
refs: M1, PROV-4, TEST-5
quote: | M1 | Real streaming | F1.1–F1.4, F2.1–F2.4 | Live smoke vs Anthropic AND OpenAI AND a consumer-injected custom-endpoint provider (F1.2) | ⇄ | M1 Real streaming | §3.2 kernels, §3.3 three built-in implementations + transport seam, §3.4 tools (TOOL-1..3, TRUNC-1); gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations |
finding: The PRD's M1 gate is a live, credentialed smoke against two real vendors plus an injected endpoint, while the TRD's technical backing defines the same gate as the offline PROV-4 integration test plus replayed fixtures — and TRD TEST-5 forbids live suites from ever blocking CI. One implementation flips M1 as soon as the fixture suites and PROV-4 are green in the required jobs; the other holds M1 open until a credentialed live run is linked, which the PRD §5 status line is currently doing.
evidence: TRD.md:269 "**TEST-5** Live provider suites are `@Suite(.enabled(if: env(\"ANTHROPIC_API_KEY\") != nil))`-style — never CI-blocking."; TRD.md:131 PROV-4 uses `baseURL: <any URL>` (satisfiable by `FixtureTransport`); Tests/Fixtures/conformance-baseline.yml line 19 `provenance: authored-from-vendor-docs` — the fixtures TRD §8 accepts as the gate were not recorded from real vendor streams.
question: Is M1 done when the offline PROV-4 test and fixture suites are green, or only when a credentialed live smoke against Anthropic, OpenAI and an injected endpoint has run and its run is linked?
options: [PRD] The gate is the live smoke: define how a never-CI-blocking live suite produces the linkable evidence PROG-2 demands (e.g. a credentialed, manually triggered workflow), and have TRD §8 M1 point at that rather than at PROV-4 + fixtures. (recommended) / [TRD] The gate is PROV-4 + TEST-3 fixtures: relabel the PRD M1 gate accordingly and accept that authored-from-docs fixtures, not real vendors, are what flips M1.
status: open

### spec-013 · major · leak_trd
key: leak_trd@F3.3+TRD§3.5|- **compaction** (numbers are normative, ported from pi): trigger when `contextt
where: TRD.md:158
refs: F3.3, TRD§3.5
quote: - **Compaction** (numbers are normative, ported from pi): trigger when `contextTokens > contextWindow − reserve` (default reserve **16 384**); cut-point keeps ~**20 000** recent tokens; iterative LLM summary + self-contained `retainedTail`.
finding: The TRD fixes two normative, user-visible numbers — when a conversation is summarized and how much of it survives verbatim — that the PRD's F3.3 never states. A second platform TRD written from this PRD could pick any reserve and any retained budget and still satisfy F3.3, producing sessions that compact at different points and retain different history.
evidence: PRD.md:33 "- **F3.3** Long conversations compact automatically (summary + retained tail) without losing the thread." — no number; yet the PRD does state the analogous truncation limits at PRD.md:27 "truncated predictably (2000 lines / 50 KB)", so product-visible limits are otherwise the PRD's to own.
question: Do the 16 384 reserve and 20 000 retained-token budgets belong in the PRD as product limits, the way the 2000 lines / 50 KB truncation limits already do?
options: [PRD] Move the two numbers into F3.3 so every platform compacts identically, and let the TRD cite them (recommended) / [TRD] Keep them as platform-specific defaults and state in F3.3 that the thresholds are implementation-chosen
status: open

### spec-014 · major · leak_trd
key: leak_trd@F4.5+TRD§3.6|- **event-2** streams are **bounded by default** (`.bufferingnewest`); an absent
where: TRD.md:167
refs: F4.5, TRD§3.6
quote: - **EVENT-2** Streams are **bounded by default** (`.bufferingNewest`); an absent or slow consumer must not grow the agent's memory without limit. `.unbounded` is opt-in, for a consumer that cannot lose an event.
finding: The TRD decides a user-visible delivery guarantee the PRD never states: by default the event stream that F4.5 promises for "driving UIs and logs" may silently drop events, and lossless observation is opt-in. A second platform TRD could default to lossless delivery and both would satisfy F4.5, so a log written against one platform would be complete and against the other would have holes.
evidence: PRD.md:41 "- **F4.5** A structured event stream (turns, message deltas, tool activity) for driving UIs and logs." — the PRD states no buffering policy, no loss semantics and no default; the words "bounded by default" and "`.unbounded` is opt-in" appear nowhere in PRD.md (grep: no match for "bounded").
question: Should the PRD state whether the event stream is lossy or lossless by default, or is the buffering policy the TRD's to choose per platform?
options: [PRD] State the delivery guarantee for F4.5 in the PRD so every platform's observers behave the same, and keep the buffering mechanism in the TRD (recommended) / [TRD] Keep the policy platform-specific and note in F4.5 that delivery guarantees are implementation-defined
status: open

### spec-015 · major · leak_trd
key: leak_trd@F6.1+F9.1+TRD§3.7|- **client**: `mcptoolsource: agentextension` — connects to an mcp server, lists
where: TRD.md:199
refs: F6.1, F9.1, TRD§3.7
quote: - **Client**: `MCPToolSource: AgentExtension` — connects to an MCP server, lists tools, bridges each into an ApusKit `Tool` (schema passthrough; results → `ToolResult`; list-changed notifications refresh the registry). Transports: HTTP first; stdio only on macOS and only toward processes the host app may legitimately reach.
finding: The TRD narrows a stated capability: F6.1 promises connection to any MCP server, but the TRD makes stdio-transport servers reachable only on macOS, so on iOS/iPadOS — a Tier 1 platform — a whole class of MCP servers is unreachable. It also adds an unstated behaviour, registry refresh on list-changed notifications, that a second platform need not implement.
evidence: PRD.md:48 "- **F6.1** **Client:** connect an agent to any MCP server and use its tools like native ones." and PRD.md:62 lists iOS/iPadOS 17+ as Tier 1 first-class; the PRD's non-goals at PRD.md:73 do not exclude stdio clients on any platform.
question: Is the stdio-client restriction a product limit on F6.1 that the PRD must state, or a purely Apple-platform consequence the PRD should stay silent about?
options: [PRD] Record the transport scope of F6.1 in the PRD (which transports are promised, on which tiers) and keep the macOS-only sandbox reasoning in the TRD (recommended) / [TRD] Keep the line as platform-specific, since process spawning is an OS capability, and add nothing to the PRD
status: open

### spec-016 · major · leak_trd
key: leak_trd@M1+PRD§4+TRD§8|| m1 real streaming | §3.2 kernels, §3.3 three built-in implementations + transp⇄| m1 | real streaming | f1.1–f1.4, f2.1–f2.4 | live smoke vs anthropic and opena
where: PRD.md:82 ⇄ TRD.md:311
refs: M1, TRD§8, PRD§4
quote: | M1 | Real streaming | F1.1–F1.4, F2.1–F2.4 | Live smoke vs Anthropic AND OpenAI AND a consumer-injected custom-endpoint provider (F1.2) | ⇄ | M1 Real streaming | §3.2 kernels, §3.3 three built-in implementations + transport seam, §3.4 tools (TOOL-1..3, TRUNC-1); gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations |
finding: The PRD states M1's gate as a live smoke against two named vendors plus an injected provider, while the TRD's backing table states a different gate for the same milestone — PROV-4 plus recorded conformance fixtures, neither of which contacts a live vendor. TRD.md:306 makes the TRD's own list decisive ("a milestone is DONE only when its backing checks are green in CI"), so an Apple implementation could declare M1 done with zero live traffic while a second platform's TRD, reading only the PRD, would hold M1 open until real Anthropic and OpenAI calls succeed.
evidence: TRD.md:306 "This table maps each PRD gate to the technical checks that implement it; a milestone is DONE only when its backing checks are green in CI"; TRD.md:269 TEST-5 "Live provider suites are `@Suite(.enabled(if: env(\"ANTHROPIC_API_KEY\") != nil))`-style — never CI-blocking", so the PRD's live-smoke gate is by construction absent from the TRD's green-in-CI set.
question: Which document defines when M1 is done — the PRD's live-smoke gate, or the TRD's PROV-4-plus-fixtures backing?
options: [PRD] Keep the gate wording solely in the PRD and have the TRD row cite it without restating a different check (recommended) / [TRD] Change the PRD's M1 gate to the offline check the TRD backs, and record the live smoke as a separate non-gating milestone item
status: open

### spec-017 · major · external_dep
key: external_dep@F1.1+M1+TEST-3|│ └── fixtures/ // recorded pi sse transcripts + real pi v3 session files + conf
where: TRD.md:41
refs: TEST-3, M1, F1.1
quote: │   └── Fixtures/                // recorded pi SSE transcripts + real pi v3 session files + conformance-baseline.yml
finding: The wire-compat suite that backs M1 is specified over transcripts *recorded* from an outside system, an artefact class that requires vendor accounts to capture and whose redistribution licence is not addressed anywhere in either document. Without a stated provenance rule, one implementer vendors real recordings and another authors look-alikes, and the two suites prove different things.
evidence: TRD.md:311 "gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations". Repo corroboration, /Users/gregor/projects/ApusKit/Tests/Fixtures/conformance-baseline.yml: "TEST-3 names \"recorded pi SSE transcripts\"; none could be obtained under a settled licence, so the transcripts here are authored from each vendor's public streaming documentation to the same event shapes."
question: Must the conformance transcripts be genuine recordings of third-party traffic, or are transcripts authored from public vendor documentation an accepted substitute?
options: [TRD] State that authored-from-public-documentation transcripts satisfy TEST-3, with the provenance recorded per fixture (recommended) / [TRD] Require genuine recordings and name the licence/redistribution basis under which vendor stream output may be committed
status: open

### spec-018 · major · external_dep
key: external_dep@F6.2+M4+MCP-2|- **mcp-1** sdk types never appear on apuskit's public api surface — wrap everyt
where: TRD.md:201
refs: M4, F6.2, MCP-2
quote: - **MCP-1** SDK types NEVER appear on ApusKit's public API surface — wrap everything. **MCP-2** Pin the SDK to an exact version.
finding: The whole of §3.7 — stdio and stateless/stateful HTTP server modes, list-changed notification refresh, agent-as-tool — is specified as a bridge onto another project's SDK release whose supported feature set is neither named nor version-bound here. If the pinned release lacks a mode, M4 either diverges from §3.7 or the wrapper has to implement the protocol itself, and nothing says which.
evidence: TRD.md:199 "- **Client**: `MCPToolSource: AgentExtension` — connects to an MCP server, lists tools, bridges each into an ApusKit `Tool` (schema passthrough; results → `ToolResult`; list-changed notifications refresh the registry). Transports: HTTP first; stdio only on macOS and only toward processes the host app may legitimately reach." PKG-5 (TRD.md:57) names the dependency without a version: "`modelcontextprotocol/swift-sdk` (trait `MCP`)".
question: Which exact `modelcontextprotocol/swift-sdk` version does M4 target, and what is the fallback if that release does not provide a transport or notification mode §3.7 requires?
options: [TRD] Name the target SDK version and mark the §3.7 features it is known to supply, so a shortfall is visible before M4 starts (recommended) / [TRD] State that any §3.7 feature the pinned SDK lacks is deferred rather than reimplemented in ApusKit
status: open

### spec-019 · major · external_dep
key: external_dep@M0+TRD§7|| soundness | `swiftlang/github-workflows` reusable | license headers, format, d
where: TRD.md:285
refs: TRD§7, M0
quote: | Soundness | `swiftlang/github-workflows` reusable | license headers, format, DocC `--analyze` |
finding: A gate required on every PR is delegated wholesale to another project's workflow, with no version, tag or commit pinned, so what this gate checks can change without any change in this repository. Two implementations pinning different refs — or one tracking the default branch — would enforce different rules on the same PR.
evidence: No ref or version accompanies the reusable-workflow reference anywhere in TRD.md (§7 table row and no supporting note), unlike PKG-5's "exact-pin anything 0.x" and MCP-2's "Pin the SDK to an exact version" (TRD.md:57, TRD.md:201). No soundness workflow exists in the repo: `ls /Users/gregor/projects/ApusKit/.github/workflows/` → consumers.yml, docs.yml, format.yml, tests.yml, tsan.yml.
question: To which pinned ref of `swiftlang/github-workflows` is the Soundness gate bound, and what happens to the gate if that project changes or removes it?
options: [TRD] Pin the reusable workflow to an explicit tag or commit, consistent with the exact-pin rule already applied to dependencies (recommended) / [TRD] Replace the delegated gate with in-repo jobs that state the checks directly, removing the outside dependency
status: open

### spec-020 · minor · underspecified
key: underspecified@LOOP-7+TRD§3.4|- **loop-7** tools execute in parallel by default; a tool may declare a serial `
where: TRD.md:178
refs: LOOP-7, TRD§3.4
quote: - **LOOP-7** Tools execute in parallel by default; a tool may declare a serial `executionMode`; a `ToolResult` with `terminate: true` ends the batch.
finding: "Serial" has two ordinary meanings for a batch scheduler — the tool runs alone as a barrier while nothing else is in flight, or serial tools merely run one at a time among themselves while parallel ones proceed — and nothing in either document settles which. `executionMode` also has no home: the `Tool` protocol as declared has no such requirement, so its default (per EVO-1) is unstated too.
evidence: TRD.md:137-143 declares `Tool` with `name`, `description` and `execute(...)` only — no `executionMode` property and no default; PRD.md:37 F4.1 says only "the model calls tools (in parallel where safe)".
options: A serial tool is a barrier: it runs alone, with no other tool in flight (recommended) / Serial tools run one at a time among themselves while parallel tools continue concurrently
status: noted
affects: ApusKitAgent, ApusKitTools

### spec-021 · minor · contradicts
key: contradicts@CC-3+CORE-2+PRD§4|**versioning (user-facing):** 0.x with frequent small releases; minor = features⇄constraints: **core-1** no networking imports, no i/o, no reflection. **core-2**
where: PRD.md:89 ⇄ TRD.md:86
refs: CORE-2, CC-3, PRD§4
quote: **Versioning (user-facing):** 0.x with frequent small releases; minor = features/possible breaks, patch = fixes. ⇄ Constraints: **CORE-1** no networking imports, no I/O, no reflection. **CORE-2** every type versioned-stable for wire-compat (changing a `Codable` shape is SemVer-major).
finding: The PRD allows breaks in any 0.x minor, while CORE-2 (and CC-3's "post-release is SemVer-major") label a Codable-shape or Sendable change SemVer-major with no statement of whether that binds before 1.0. One team ships a `ContentBlock` shape change as 0.(x+1); another treats it as blocked until 1.0/2.0.
evidence: TRD.md:226 "Adding `@Sendable`/`@MainActor`/Sendable constraints post-release is SemVer-major." — 0.1.0 is a release, so the clause reads as binding from M3.
options: State that the SemVer-major clauses take effect at 1.0 and that 0.x minors may break as the PRD says. (recommended) / State that CORE-2/CC-3 bind from 0.1.0 and amend the PRD's 0.x rule for wire types.
status: noted

### spec-022 · minor · contradicts
key: contradicts@ENUM-1+TRD§3.1|- **enum-1** **every public enum on an evolving surface** is `@nonexhaustive(war⇄- `stopreason` (`@nonexhaustive`): `endturn, tooluse, length, aborted, error`.
where: TRD.md:82 ⇄ TRD.md:234
refs: ENUM-1, TRD§3.1
quote: - `StopReason` (`@nonexhaustive`): `endTurn, toolUse, length, aborted, error`. ⇄ - **ENUM-1** **Every public enum on an evolving surface** is `@nonexhaustive(warn)` now → `@nonexhaustive` at 1.0; consumers write `@unknown default`.
finding: §3.1 annotates `StopReason` and `StreamEvent` as `@nonexhaustive` today, while ENUM-1 and the §8 M6 row say the pre-1.0 form is `@nonexhaustive(warn)` and the flip happens at 1.0. One implementation makes a consumer's missing `@unknown default` a hard error from 0.1; the other makes it a warning until 1.0.
evidence: TRD.md:316 "| M6 → 1.0 | flip `@nonexhaustive(warn)` → `@nonexhaustive` (ENUM-1)"; Sources/ApusKitCore/StopReason.swift:7 and StreamEvent.swift:11 currently carry `@nonexhaustive(warn)`.
options: Treat ENUM-1 as the rule and read the §3.1 annotations as shorthand for the 1.0 form. (recommended) / Treat §3.1 literally and make `StopReason`/`StreamEvent` hard-`@nonexhaustive` from 0.x.
status: noted

### spec-023 · minor · contradicts
key: contradicts@F1.5+TEST-2+TRD§3.3|- **test-2** unit tests use protocol-seam fakes from the `testsupport` target (`⇄- `scriptedprovider` — a deterministic `apiimplementation` playing back scripted
where: TRD.md:127 ⇄ TRD.md:266
refs: TEST-2, F1.5, TRD§3.3
quote: - `ScriptedProvider` — a deterministic `APIImplementation` playing back scripted event sequences — is **public** and documented (testing is first-class). ⇄ - **TEST-2** Unit tests use protocol-seam fakes from the `TestSupport` target (`ScriptedProvider`, `RecordingTool`, `ThrowingTool`, `GateTool`, `HangingProvider`, `RequestRecordingProvider`, `FixtureTransport`, `RequestSpyLog`, in-memory `SessionStore`). Never URLProtocol stubbing.
finding: §3.3 places `ScriptedProvider` in the public `ApusKitProviders` product, while TEST-2 lists it among the fakes that live in the test-only `TestSupport` target. One implementation ships it to consumers (as PRD F1.5 requires); the other keeps it in Tests/Shared where no consumer can reach it.
evidence: PRD.md:22 "- **F1.5** A deterministic scripted provider so agents can be developed and tested with no network and no API keys."; repo has Sources/ApusKitProviders/ScriptedProvider.swift:20 `public struct ScriptedProvider: APIImplementation` and Tests/Shared contains no ScriptedProvider.
options: Keep `ScriptedProvider` in the Providers product (F1.5) and drop it from the TEST-2 TestSupport list. (recommended) / Move it to TestSupport and retract F1.5's consumer-facing promise.
status: noted

### spec-024 · minor · contradicts
key: contradicts@F2.4+M1+TOOL-4|| m1 real streaming | §3.2 kernels, §3.3 three built-in implementations + transp⇄| m1 | real streaming | f1.1–f1.4, f2.1–f2.4 | live smoke vs anthropic and opena
where: PRD.md:82 ⇄ TRD.md:311
refs: M1, TOOL-4, F2.4
quote: | M1 | Real streaming | F1.1–F1.4, F2.1–F2.4 | Live smoke vs Anthropic AND OpenAI AND a consumer-injected custom-endpoint provider (F1.2) | ⇄ | M1 Real streaming | §3.2 kernels, §3.3 three built-in implementations + transport seam, §3.4 tools (TOOL-1..3, TRUNC-1); gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations |
finding: The PRD puts F2.4 (progress and cancellation) in M1, but the TRD's M1 backing row lists TOOL-1..3 and TRUNC-1 only, omitting TOOL-4 (cancellation). One plan implements structured-concurrency cancellation in tools during M1; another defers it to M3 alongside abort (F4.4).
evidence: TRD.md:150 "**TOOL-4** Cancellation is ordinary structured-concurrency cancellation (`LOOP-6`)" is absent from the M1 row; PRD.md:124 "- [x] Typed tools: schema derivation, validation, truncation, progress/cancel (F2.1–F2.4) (2026-08-25)" ticks it under M1.
options: Add TOOL-4 to the §8 M1 backing row to match F2.4's placement. (recommended) / Move F2.4 to M3 in the PRD alongside F4.4.
status: noted

### spec-025 · minor · contradicts
key: contradicts@TEST-8+TRD§7|## 7. ci gates (all required on every pr unless marked nightly)⇄- **test-8** `evals/` scenarios drive the real loop on `scriptedprovider`: multi
where: TRD.md:272 ⇄ TRD.md:281
refs: TEST-8, TRD§7
quote: - **TEST-8** `Evals/` scenarios drive the REAL loop on `ScriptedProvider`: multi-turn, steering mid-run, tool failure, `length` stop, compaction mid-run, abort. Non-default target; runs in CI on macOS. ⇄ ## 7. CI gates (all required on every PR unless marked nightly)
finding: TEST-8 says the non-default `Evals/` target runs in CI, but no §7 row names it, so a planner cannot tell whether Evals is part of the required `swift test` job, a separate required job, or nightly. One codebase folds Evals into the Tests matrix; another adds an unlisted job or never runs it because §7 is the closed list of gates.
evidence: TRD.md:283-294 table rows: Soundness, Tests, Format, API breakage, Docs, TSan, Consumer simulation, Traits matrix, Fuzz (nightly), Benchmarks (nightly) — no Evals row; `ls Evals` → No such file or directory.
options: Add Evals to §7 as its own row (required or nightly) so TEST-8's "runs in CI" has a gate. (recommended) / State in TEST-8 that Evals runs inside the existing Tests job.
status: noted

### spec-026 · minor · leak_trd
key: leak_trd@F4.1+TRD§3.6|- **loop-7** tools execute in parallel by default; a tool may declare a serial `
where: TRD.md:178
refs: F4.1, TRD§3.6
quote: - **LOOP-7** Tools execute in parallel by default; a tool may declare a serial `executionMode`; a `ToolResult` with `terminate: true` ends the batch.
finding: A tool being able to end the batch by returning `terminate: true` is a product capability — a tool author can stop the agent's run — and the PRD's F4 group never mentions it. Built from the PRD alone, a second platform would offer no tool-initiated termination and its tool authors would write different tools.
evidence: grep for "terminate" in PRD.md returns no match; PRD.md:37 "- **F4.1** Autonomous multi-turn loop: the model calls tools (in parallel where safe), sees results, continues until done." covers only parallel execution, not tool-initiated stop.
options: [PRD] Add tool-initiated termination to F4 as a stated capability and leave the field spelling in the TRD (recommended) / [TRD] Keep it as a platform-specific detail of the ported pi loop
status: noted

## Gates measured
<!-- every row the TRD declares, measured at reviewed_commit in a throwaway copy; rewritten by each gates-lens run -->
| declared in | command | cause | measured | note |
|---|---|---|---|---|
| TRD.md:285 | `swiftlang/github-workflows reusable (license headers, format, DocC --analyze)` | not_a_command | -1 | Row names a reusable GitHub Actions workflow, not a local co |
| TRD.md:286 | `swift test` | passes | exit 0 | Test run with 252 tests in 45 suites passed after 0.441 seco |
| TRD.md:286 | `swift test  (nightly-toolchain leg of the macOS matrix)` | environment | -1 | No alternate toolchain installed: /Library/Developer/Toolcha |
| TRD.md:287 | `swift format lint --strict --recursive .` | passes | exit 0 | (no output, 0 lines) — swift format 6.3.0. Control check: a  |
| TRD.md:288 | `swift package diagnose-api-breaking-changes` | structural | exit 64 | error: Missing expected argument '<treeish>' |
| TRD.md:288 | `swift package diagnose-api-breaking-changes HEAD~1` | passes | exit 0 | Build complete! (29.25s) |
| TRD.md:289 | `swift package generate-documentation --warnings-as-errors --target ApusKit --target ApusKitCore --target ApusKitWireFormat --target ApusKitProviders --target ApusKitTools --target ApusKitSessions --target ApusKitAgent` | passes | exit 0 | Generated 7 documentation archives: ApusKit, ApusKitAgent, A |
| TRD.md:289 | `swift package generate-documentation --warnings-as-errors` | structural | exit 1 | 183 lines matching "error:"; Error: An error was encountered |
| TRD.md:285 | `swift package generate-documentation --analyze --warnings-as-errors` | structural | exit 1 | 184 lines matching "error:"; error: 'Keywords.AdditionalProp |
| TRD.md:290 | `swift test --sanitize=thread` | passes | exit 0 | Test run with 252 tests in 45 suites passed after 1.228 seco |
| TRD.md:291 | `swift build  (in each of Examples/consumers/*: agent, core, mainactor, providers, sessions, tools, umbrella, wireformat)` | passes | exit 0 | agent-consumer EXIT:0 / core-consumer EXIT:0 / mainactor-con |
| TRD.md:292 | `swift build` | passes | exit 0 | Build complete! (40.10s) — no-traits leg of the traits matri |
| TRD.md:292 | `swift build --traits NIO` | passes | exit 0 | [60/60] Emitting module TestSupport |
| TRD.md:292 | `swift build --traits MCP` | passes | exit 0 | [60/60] Emitting module TestSupport |
| TRD.md:292 | `swift build --traits NIO,MCP` | passes | exit 0 | [60/60] Compiling TestSupport FixtureTransport.swift |
| TRD.md:292 | `swift test --traits NIO,MCP` | passes | exit 0 | Test run with 252 tests in 45 suites passed after 0.407 seco |
| TRD.md:293 | `libFuzzer+ASan on SSE + JSONL + partial-JSON kernels, 60 s smoke, in-repo corpus` | skipped | -1 | Row is marked (nightly) — not run per the standing rule. |
| TRD.md:294 | `package-benchmark run, trend recorded` | skipped | -1 | Row is marked (nightly) — not run per the standing rule. |
| TRD.md:326 | `git commit -s` | skipped | -1 | Definition-of-Done item 7; a repository-writing git command, |
| TRD.md:311 | `gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations` | not_a_command | -1 | M1 milestone gate stated as a condition on named tests; no l |
| TRD.md:312 | `gate = SESS-1 suite green` | not_a_command | -1 | M2 milestone gate stated as a condition; no literal command. |
| TRD.md:314 | `gate checks per PRD (HTTP external-server call + stdio stock-client consumption)` | not_a_command | -1 | M4 milestone gate delegated to the PRD in prose; no literal  |
| TRD.md:315 | `gate = two-provider red-team workflow on public API, journaled (WF-1)` | not_a_command | -1 | M5 milestone gate stated as a scenario; no literal command. |

## History
- 2026-08-26 · full · 204a0fe916e0 @ 71c01a5 · 5 lenses · 26 findings (1 blocker, 18 major) · draft
