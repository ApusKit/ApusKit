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

**Current status: 🔵 Pre-M0 — specification complete (PRD + TRD, 2026-08-24); implementation not started.**

Legend: ⬜ planned · 🔨 in progress · ✅ done

| Milestone | Status | Gate evidence |
|---|---|---|
| M0 Skeleton | ⬜ | — |
| M1 Real streaming | ⬜ | — |
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
