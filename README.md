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

See `PRD.md` §5 for the single source of truth on project state, and
`TRD.md` for the technical design this implementation follows.

## License

MIT. See `LICENSE`. Portions ported from pi are copyright Mario Zechner /
earendil-works (MIT).
