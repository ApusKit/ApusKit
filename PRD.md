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
- **F3.2** **pi interchange:** session files are wire-compatible with pi v3 — a pi session opens in ApusKit and vice versa.
- **F3.3** Long conversations compact automatically (summary + retained tail) without losing the thread.
- **F3.4** Storage is pluggable; a file-based store ships built in.

### F4 — Agent loop
- **F4.1** Autonomous multi-turn loop: the model calls tools (in parallel where safe), sees results, continues until done.
- **F4.2** **Steering:** the user can inject guidance mid-run; it is applied between turns.
- **F4.3** Graceful failure: any error ends the run as a readable message — the loop never crashes the host app.
- **F4.4** Clean abort at any moment.
- **F4.5** A structured event stream (turns, message deltas, tool activity) for driving UIs and logs.

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

Built strictly in order. A milestone is **done** only when its gate passes as an automated, evidence-linked check.

| # | Milestone | Delivers | Functional gate |
|---|---|---|---|
| M0 | Skeleton | Loop on scripted provider (F4.1/F4.3, F1.5), package + CI up | A scripted multi-turn conversation with one fake tool round-trips in CI |
| M1 | Real streaming | F1.1–F1.4, F2.1–F2.4 | Live smoke vs Anthropic AND OpenAI AND a consumer-injected custom-endpoint provider (F1.2) |
| M2 | Sessions | F3.1–F3.4 | A real pi session file replays correctly (F3.2) |
| M3 | Public 0.1.0 | F4.2/F4.4/F4.5, F5.1–F5.2, F10.1 (`chat`), F10.2, F10.3; public repo + package listing | A clean-room consumer installs the package and runs the README example unmodified |
| M4 | MCP | F6.1–F6.3, F10.1 (`serve-mcp`) | CLI calls a real external MCP server's tool through the loop over HTTP; a stock MCP client consumes an ApusKit tool server over stdio |
| M5 | Workflows | F7.1–F7.4 | A red-team workflow (parallel researchers → adversarial judge → synthesis) runs across two different providers using only public API |
| M6 | Hardening → 1.0 | API freeze driven by real consumers | An external app ships on the released package — including its MCP server and a workflow — without forking it |

**Versioning (user-facing):** 0.x with frequent small releases; minor = features/possible breaks, patch = fixes. **1.0 = the M6 gate**: the API is frozen by real consumption, and breaking changes from then on require proposals and deprecation cycles. Curated `CHANGELOG.md` per release.

## 5. Progress

> **Single source of truth for project state.** Rules: **PROG-1** update this section in the same PR that completes a deliverable; **PROG-2** a gate flips to ✅ only with a link to the passing check (CI run / test); **PROG-3** the README status section mirrors the *Current status* line below — regenerate it whenever this section changes; **PROG-4** completed items get a date.

**Current status: 🔨 M1 in progress — M0's package skeleton, core message/event types, `ScriptedProvider` and agent loop are in place; M1's wire-format foundation (the `ApusKitWireFormat` target, the incremental SSE parser, the partial-JSON accumulator, and the default `URLSessionTransport`) is landed, and M1 now also has its three built-in `APIImplementation`s — `anthropic-messages` (including `cache_control` prompt-caching passthrough via `LLMRequest.cacheBreakpoints`, `docs/proposals/0002`), `openai-completions`, `openai-responses` (F1.1) — plus the built-in provider catalog (`ModelProvider.anthropic`/`.openAI`/`.google`/`.openRouter`/`.groq`/`.ollama`), `ProviderRegistry` resolution to a streaming `ProviderConnection`, and per-request usage/cost accounting via `Usage.cost(at:)` (F1.4), with a green local `swift test` (127 tests, 26 suites) (2026-08-25); typed tools (F2.1–F2.4) remain outstanding, no CI run has been observed yet, so no gate is flipped pending a link to a passing CI run (PROG-2).**

Legend: ⬜ planned · 🔨 in progress · ✅ done

| Milestone | Status | Gate evidence |
|---|---|---|
| M0 Skeleton | 🔨 | — |
| M1 Real streaming | 🔨 | — |
| M2 Sessions | ⬜ | — |
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
- [ ] **Gate:** scripted multi-turn + fake tool round-trip green in CI

### M1 — Real streaming
- [x] Wire-format kernels (SSE, partial-JSON accumulator) (2026-08-25)
- [x] `anthropic-messages`, `openai-completions`, `openai-responses` implementations (F1.1) (2026-08-25)
- [x] Transport seam + default URLSession transport (2026-08-25)
- [x] Provider catalog + registry, usage/cost accounting (F1.4) (2026-08-25)
- [ ] Typed tools: schema derivation, validation, truncation, progress/cancel (F2.1–F2.4)
- [ ] **Gate:** live smoke vs Anthropic + OpenAI + injected custom-endpoint provider (F1.2)

### M2 — Sessions
- [ ] JSONL tree v3 codec + context rebuild (F3.1)
- [ ] Compaction (F3.3)
- [ ] File session store + pluggable store protocol (F3.4)
- [ ] **Gate:** real pi session replays correctly (F3.2)

### M3 — Public 0.1.0
- [ ] Steering, abort, event stream surfaced (F4.2, F4.4, F4.5)
- [ ] Hook bus + `AgentExtension` (F5.1, F5.2)
- [ ] Reference CLI `chat` (F10.1)
- [ ] Docs per layer (F10.2) + Conformance Kit (F10.3)
- [ ] Governance files, public repo, package-index listing
- [ ] **Gate:** clean-room install runs README example

### M4 — MCP
- [ ] MCP client bridge (F6.1)
- [ ] MCP server exposure (F6.2) + agent-as-tool (F6.3)
- [ ] CLI `serve-mcp` (F10.1)
- [ ] **Gate:** external-server tool call over HTTP + stock client consumes tool server over stdio

### M5 — Workflows
- [ ] Step primitives: run/parallel/pipeline/judge/gate (F7.1)
- [ ] Sub-agents with scoped tools/budgets (F7.2)
- [ ] Per-step provider selection (F7.3) + session journaling (F7.4)
- [ ] **Gate:** two-provider red-team workflow on public API only

### M6 — Hardening → 1.0
- [ ] API freeze (wire enums, Sendable audit) driven by consumer proposals
- [ ] **Gate:** external app ships on the released package without forking

