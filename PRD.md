## 1. Product statement

**ApusKit is an open-source Swift framework for building AI agents into Apple-platform apps and command-line tools.** It is a faithful Swift reimplementation of the core of the **pi coding agent** (earendil-works/pi, MIT) — the same battle-tested loop semantics and session format — delivered as a modular kit for the Apple ecosystem.

**Who it is for:** Swift developers who want to embed agentic features (autonomous multi-turn LLM loops with tools) into a macOS/iOS app or CLI without building the plumbing themselves — and without being locked to any single AI vendor.

Three product identities, all mandatory:

1. **A pi port, not an invention** — proven agent semantics, including session-file interchange with pi itself.
2. **A kit, not just an engine** — every layer is usable on its own: the provider client without the agent, the session codec alone, the MCP server without any agent code.
3. **An extension platform** — everything above the core (MCP, workflows, plugins) is built on the public API, so anything ApusKit can do internally, a consumer can do externally.

## 2. Capabilities (functional requirements)

Each capability has a stable ID (`F*`). Milestones (§4) and progress (§5) reference these IDs.

### F1 — Multi-provider LLM access
- **F1.1** Stream responses from many AI providers through one unified interface; built-in catalog: Anthropic, OpenAI, Google, OpenRouter, Groq, local/Ollama (any OpenAI-compatible endpoint).
- **F1.2** **Bring-your-own provider:** consumers register their own provider (custom endpoint + auth) with zero library changes. First-class and permanently tested.
- **F1.3** Switch model or provider mid-session; conversation context is provider-neutral.
- **F1.4** Token usage and cost accounting per request, derived from a model catalog with pricing.
- **F1.5** A deterministic scripted provider so agents can be developed and tested with no network and no API keys.

### F2 — Typed tools
- **F2.1** Define tools with typed Swift arguments; JSON schema is derived automatically; arguments are validated before the tool runs.
- **F2.2** A failing tool never crashes the agent — failures become results the model can react to.
- **F2.3** Oversized tool output is truncated predictably (2000 lines / 50 KB) with a continuation mechanism.
- **F2.4** Tools report progress and respect cancellation while running.

### F3 — Sessions
- **F3.1** Conversations persist as trees: branch from any point, fork alternative continuations, walk history.
- **F3.2** **pi interchange:** session files are wire-compatible with pi v3 — a session recorded by pi opens in ApusKit, and ApusKit writes it back byte-for-byte, so pi opens what ApusKit writes.
- **F3.3** Long conversations compact automatically (summary + retained tail) without losing the thread: compaction triggers once the context comes within a **16 384-token reserve** of the model's context window, and keeps roughly the **20 000** most recent tokens verbatim (pi's numbers).
- **F3.4** Storage is pluggable; a file-based store ships built in.

### F4 — Agent loop
- **F4.1** Autonomous multi-turn loop: the model calls tools (in parallel where safe), sees results, continues until done.
- **F4.2** **Steering:** the user can inject guidance mid-run; it is applied between turns.
- **F4.3** Graceful failure: any error ends the run as a readable message — the loop never crashes the host app.
- **F4.4** Clean abort at any moment.
- **F4.5** A structured event stream (turns, message deltas, tool activity) for driving UIs and logs. Any number of observers may watch one agent; each is bounded by default, so a slow observer may miss the oldest events rather than grow memory, and lossless delivery is an explicit opt-in.

### F5 — Extensibility
- **F5.1** Hook points across the loop lifecycle: block or allow tool calls (permission gates), modify results, observe requests/responses, react to session events — budgets, quotas and telemetry are buildable by consumers.
- **F5.2** Plugins as packaged units (`AgentExtension`): a single conformance installs tools + hooks into an agent. Plugins use only the public API.

### F6 — MCP (Model Context Protocol)
- **F6.1** **Client:** connect an agent to any MCP server and use its tools like native ones.
- **F6.2** **Server:** expose an app's tools as an MCP server for other AI clients (Claude Desktop and friends).
- **F6.3** **Agent-as-tool:** expose a whole configured agent as a single MCP tool (e.g. `ask_researcher`).

### F7 — Workflows
- **F7.1** Deterministic multi-step orchestration above the loop: run, parallel fan-out, pipeline, adversarial judge/verify, approval gate.
- **F7.2** Sub-agents with scoped tools and budgets.
- **F7.3** Per-step model/provider choice — e.g. verification on a different provider than research.
- **F7.4** Every step is journaled into the session tree: auditable and replayable.

### F8 — Library-first modularity
- **F8.1** Every layer is a standalone product with its own documentation and example, usable without the agent loop.

### F9 — Platforms
- **F9.1** Tier 1 (first-class): macOS 14+ — GUI apps **and** CLI tools — iOS/iPadOS 17+, Mac Catalyst.
- **F9.2** Tier 2 (best-effort): tvOS 17+, visionOS.
- **F9.3** Linux: out of scope for now; the codebase deliberately keeps the door open.

### F10 — Developer experience
- **F10.1** Reference CLI shipping with the repo: interactive `chat` against any provider + `serve-mcp` exposing tools over MCP.
- **F10.2** Complete documentation with a standalone usage example per layer.
- **F10.3** A Conformance Kit: an executable test suite third parties run against their own provider/tool/store implementations.

## 3. Non-goals (product)

Out of scope by design (consumer territory): permission UI · concrete app tools (coding, research) · GUI/TUI components · provider marketplace · dynamic/runtime plugin loading · workflow scheduler/daemon · Linux support commitment (F9.3).

## 4. Delivery plan — milestones

Built strictly in order. A milestone is **done** only when its gate passes as an automated, evidence-linked check — with one exception: M6's gate is an outside consumer's adoption, which no check can observe, so it is a maintainer attestation in the evidence form its row defines.

| # | Milestone | Delivers | Functional gate |
|---|---|---|---|
| M0 | Skeleton | Loop on scripted provider (F4.1/F4.3, F1.5), package + CI up | A scripted multi-turn conversation with one fake tool round-trips in CI |
| M1 | Real streaming | F1.1–F1.4, F2.1–F2.4 | A consumer-injected custom-endpoint provider streams through the loop (F1.2), and recorded streams for all three built-in wire formats replay correctly — offline, in CI. A live run against real vendors is optional and never gates. |
| M2 | Sessions | F3.1–F3.4 | A real pi session file replays correctly (F3.2) |
| M3 | Public 0.1.0 | F4.2/F4.4/F4.5, F5.1–F5.2, F10.1 (`chat`), F10.2, F10.3; public repo | A clean-room consumer installs the package and runs the README example unmodified. The package-index listing is an outside dependency the maintainer owns, tracked in §5; it does not gate M3. |
| M4 | MCP | F6.1–F6.3, F10.1 (`serve-mcp`) | The CLI calls a tool on the MCP project's own reference server through the loop over HTTP, and the MCP project's own reference client consumes an ApusKit tool server over stdio — both headless, launched locally at pinned versions, with no accounts and no GUI client |
| M5 | Workflows | F7.1–F7.4 | A red-team workflow (parallel researchers → adversarial judge → synthesis) runs across two distinct registered providers — scripted or local ones count, no external accounts needed — using only public API |
| M6 | Hardening → 1.0 | API freeze driven by real consumers | An external app ships on a tagged ApusKit release — including its MCP server and a workflow — without forking it. Evidence: a §5 entry signed off by the maintainer, naming the consumer, linking its public release, dated. |

**Versioning (user-facing):** 0.x with frequent small releases; minor = features/possible breaks, patch = fixes. **1.0 = the M6 gate**: the API is frozen by real consumption, and breaking changes from then on require proposals and deprecation cycles. Curated `CHANGELOG.md` per release.

## 5. Progress

> **Single source of truth for project state.** Rules: **PROG-1** update this section in the same PR that completes a deliverable; **PROG-2** a gate flips to ✅ only with a link to the passing check (CI run / test) — M6 alone flips on the maintainer attestation its §4 row defines; **PROG-3** the README status section mirrors the *Current status* line below — regenerate it whenever this section changes; **PROG-4** completed items get a date.

**Current status: 🔨 M3 next — **M0 and M1 are complete.** M0 (2026-08-25): a scripted multi-turn conversation round-trips a fake tool in CI ([Tests run 32883395354](https://github.com/ApusKit/ApusKit/actions/runs/32883395354)). M1 (2026-10-08): its offline gate is green in CI — `CustomProviderInjectionTests` streams a consumer-defined `ModelProvider(id: "custom", api: .openAICompletions, auth: .bearer(_))` through the real `Agent` loop with zero library changes (PROV-4), and the recorded-stream conformance suites replay for all three built-in implementations — `anthropic-messages`, `openai-completions`, `openai-responses` (TEST-3) — in [Tests run 37778806283](https://github.com/ApusKit/ApusKit/actions/runs/37778806283) (259 tests, 48 suites on Swift 6.2), with TSan, Docs, Format and Consumer simulation green on the same commit. Live vendor suites (TEST-5) are optional and never gate. M1 delivered the wire-format kernels and `URLSessionTransport`, the three built-in `APIImplementation`s (F1.1), the provider catalog, `ProviderRegistry` and usage/cost accounting (F1.4), and typed tools with schema validation, head-truncation, progress and cancellation (F2.1–F2.4). **M2 Sessions code is landed** — the `ApusKitSessions` target with the pi-v3 JSONL codec and context rebuild (F3.1), compaction behind an injected token-counter seam (F3.3), and the pluggable `SessionStore` with a file-backed store (F3.4) — but its gate stays open: SESS-1/F3.2 needs a real session recorded with pi by the maintainer, which the authored `pi-v3-session.jsonl` fixture cannot stand in for, so M2 is not flipped (PROG-2). M3 (Public 0.1.0) is next.**

Legend: ⬜ planned · 🔨 in progress · ✅ done

| Milestone | Status | Gate evidence |
|---|---|---|
| M0 Skeleton | ✅ | [Tests run 32883395354](https://github.com/ApusKit/ApusKit/actions/runs/32883395354) — `multiTurnToolRoundTrip` green, 165 tests / 28 suites (2026-08-25) |
| M1 Real streaming | ✅ | [Tests run 37778806283](https://github.com/ApusKit/ApusKit/actions/runs/37778806283) — `CustomProviderInjectionTests` (PROV-4) + conformance fixtures for all three implementations green, 259 tests / 48 suites (2026-10-08) |
| M2 Sessions | 🔨 | — |
| M3 Public 0.1.0 | ⬜ | — |
| M4 MCP | ⬜ | — |
| M5 Workflows | ⬜ | — |
| M6 Hardening → 1.0 | ⬜ | — |

### M0 — Skeleton
- [x] Repository scaffold per TRD layout; manifest rules applied (2026-08-25)
- [x] Core message/event types (2026-08-25)
- [x] ScriptedProvider (F1.5) (2026-08-25)
- [x] Loop skeleton: multi-turn + tool execution on scripted provider (F4.1, F4.3) (2026-08-25)
- [x] First test suites + CI jobs live — test suites green locally, the five §7 workflows in `.github/workflows/` (2026-08-25)
- [x] **Gate:** scripted multi-turn + fake tool round-trip green in CI — [Tests run 32883395354](https://github.com/ApusKit/ApusKit/actions/runs/32883395354) (2026-08-25)

### M1 — Real streaming
- [x] Wire-format kernels (SSE, partial-JSON accumulator) (2026-08-25)
- [x] `anthropic-messages`, `openai-completions`, `openai-responses` implementations (F1.1) (2026-08-25)
- [x] Transport seam + default URLSession transport (2026-08-25)
- [x] Provider catalog + registry, usage/cost accounting (F1.4) (2026-08-25)
- [x] Typed tools: schema derivation, validation, truncation, progress/cancel (F2.1–F2.4) (2026-08-25)
- [x] **Gate:** a consumer-injected custom-endpoint provider streams through the loop (F1.2, PROV-4), and recorded streams for all three built-in wire formats replay correctly (TEST-3) — offline, in CI; live vendor runs never gate — [Tests run 37778806283](https://github.com/ApusKit/ApusKit/actions/runs/37778806283) (2026-10-08)

### M2 — Sessions
- [x] JSONL tree v3 codec + context rebuild (F3.1) (2026-08-26)
- [x] Compaction (F3.3) (2026-08-26)
  - [x] Token-counter seam: `Compaction.compactIfNeeded` owns trigger + cut + compact behind injected counter and summarizer (§3.5, amended 2026-10-01) (2026-10-08)
- [x] File session store + pluggable store protocol (F3.4) (2026-08-26)
- [ ] **Gate:** a session recorded with pi decodes, rebuilds context, and re-encodes byte-for-byte (F3.2)

### M3 — Public 0.1.0
- [ ] Steering, abort, event stream surfaced (F4.2, F4.4, F4.5)
- [ ] Hook bus + `AgentExtension` (F5.1, F5.2)
- [ ] Reference CLI `chat` (F10.1)
- [ ] Docs per layer (F10.2) + Conformance Kit (F10.3)
- [ ] Governance files, public repo
- [ ] Package-index listing — outside dependency, maintainer-owned; does not gate M3
- [ ] **Gate:** clean-room install runs README example

### M4 — MCP
- [ ] MCP client bridge (F6.1)
- [ ] MCP server exposure (F6.2) + agent-as-tool (F6.3)
- [ ] CLI `serve-mcp` (F10.1)
- [ ] **Gate:** tool call on the MCP reference server over HTTP + MCP reference client consumes an ApusKit tool server over stdio (headless, pinned)

### M5 — Workflows
- [ ] Step primitives: run/parallel/pipeline/judge/gate (F7.1)
- [ ] Sub-agents with scoped tools/budgets (F7.2)
- [ ] Per-step provider selection (F7.3) + session journaling (F7.4)
- [ ] **Gate:** red-team workflow across two distinct registered providers on public API only

### M6 — Hardening → 1.0
- [ ] API freeze (wire enums, Sendable audit) driven by consumer proposals
- [ ] **Gate:** external app ships on a tagged release without forking — maintainer-attested entry (consumer, release link, date)

