# Project overview

Last reviewed: 2026-10-08
Source of truth: `PRD.md`, `README.md`

Domain vocabulary for agents working here. The product statement and capability list live in
`PRD.md` §1–2 and are not repeated — this page exists so the words in the code mean the same
thing to you as they do to the people who wrote it.

## Summary

- ApusKit is a Swift-native agent harness: a faithful reimplementation of the core of **pi**
  (earendil-works/pi, MIT) for Apple platforms.
- It is a **library kit**, not an app and not an engine. Every target must be usable on its own,
  without the agent loop.
- It hardcodes no vendor. A consumer supplies the provider; ApusKit supplies the loop, the tool
  system, and (later) sessions, MCP and workflows.
- Current milestone: M3 next. M0 (2026-08-25) and M1 (2026-10-08) are complete with green CI
  links. M1's gate is offline — PROV-4 custom-provider injection plus TEST-3 fixture replay;
  live vendor suites never gate. M2's ApusKitSessions code is landed, but its gate (SESS-1) stays
  open until the maintainer records a real pi session. `PRD.md` §5 is the single source of truth
  for state.

## Vocabulary

| Term | In this codebase |
|---|---|
| **Provider** | A vendor's service. Described by `ModelProvider` + `ModelInfo` (catalog data: models, pricing, auth), registered in a `ProviderRegistry` |
| **API implementation** | The *wire adapter* — how you talk to a provider. `APIImplementation.stream(request:connection:)` returns an `AsyncThrowingStream<StreamEvent>`. One implementation can serve many providers (an OpenAI-compatible endpoint) |
| **Connection** | `ProviderConnection` — where and how to reach a provider on this call (base URL, auth). Passed per request, never stored globally |
| **Transport** | `StreamingHTTPTransport` — the HTTP seam *under* an API implementation, so bytes-on-the-wire can be faked or swapped without faking the protocol above it |
| **Tool** | A typed capability the model can invoke mid-turn. Arguments are `Schemable` so the JSON Schema is derived, not hand-written. Shaped like Foundation Models' `Tool` but with no dependency on it |
| **Turn** | One request/response exchange with the model. A `run` may take many turns — the loop keeps going while the model keeps asking for tools |
| **Steering** | Injecting a user message into a run already in flight. The queue exists at M0; the surfaced API is M3 |
| **Session** | The JSONL conversation *tree* (pi's v3 format) — branching, not a flat log. M2 |
| **Hook / extension** | `AgentExtension` — the public-API-only plugin seam. M3 |
| **Trait** | A SwiftPM package trait gating an optional dependency: `NIO` and `MCP`. Declared now, inert until M1/M4 |
| **Milestone gate** | The check that lets a milestone flip to ✅ in `PRD.md` §5. Requires a link to a passing CI run |

## The five products

| Product | For a consumer who wants |
|---|---|
| `ApusKitCore` | Just the message/event/usage model — e.g. to render a transcript |
| `ApusKitProviders` | Just streaming LLM access, no agent loop |
| `ApusKitTools` | Just the typed-tool system and its schema derivation |
| `ApusKitAgent` | The full loop |
| `ApusKit` | All of the above via one import |

That table is the library-first principle in practice: if a row stops being true, the design has
regressed regardless of whether tests pass.

## Relevant files

| Path | Why it matters |
|---|---|
| `PRD.md` | Capabilities, milestones, and §5 — the single source of truth for state |
| `TRD.md` | The normative technical spec. §4 is "the law" |
| `README.md` | Public framing; its status table mirrors PRD §5 |
| `AGENTS.md` | Agent rules, commands, boundaries. `CLAUDE.md` is a symlink to it |

## Gotchas

See `gotchas.md`.

## Validation

`swift test`. See `commands.md`.

## Open questions

See `open-questions.md`.
