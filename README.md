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

**Current status: 🔨 M1 in progress — M0's package skeleton, core message/event types, `ScriptedProvider` and agent loop are in place; M1 has landed its wire-format foundation (the `ApusKitWireFormat` target, the incremental SSE parser, the partial-JSON accumulator, and the default `URLSessionTransport`) with a green local `swift test` (2026-08-25); no CI run has been observed yet, so no gate is flipped pending a link to a passing CI run (PROG-2).**

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

See `PRD.md` §5 for the single source of truth on project state, and
`TRD.md` for the technical design this implementation follows.

## License

MIT. See `LICENSE`. Portions ported from pi are copyright Mario Zechner /
earendil-works (MIT).
