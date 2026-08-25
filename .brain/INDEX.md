# ApusKit Agent Brain

Last reviewed: 2026-08-25
Source of truth: `AGENTS.md`, `TRD.md`, `PRD.md`

Durable project knowledge for coding agents. Read this page first, then only the page your task
needs.

## Start here

| Need | Read |
|---|---|
| Domain vocabulary — what "provider" or "tool" means here | [project-overview.md](./project-overview.md) |
| Run, test, format, build, validate | [commands.md](./commands.md) |
| System shape and data flow, Norms & Safeguards | [architecture.md](./architecture.md) |
| Where code lives, and which test fakes already exist | [code-maps.md](./code-maps.md) |
| Known traps — read before debugging anything surprising | [gotchas.md](./gotchas.md) |
| Milestone gating, run artifacts, the brain's own loop | [workflows.md](./workflows.md) |
| Decisions still open | [open-questions.md](./open-questions.md) |
| Where a new fact belongs | [owner-page-taxonomy.md](./owner-page-taxonomy.md) |
| Entry formats for adding to the brain | [templates.md](./templates.md) |

## Three documents, three jobs

Getting this wrong is how the brain turns into a stale copy of the spec:

| Document | Job |
|---|---|
| `TRD.md` | **Normative** — what the code *must* be, as rule codes (`CC-2`, `FORB-2`, `PKG-6`, …). Binding |
| `.brain` (here) | **Descriptive** — what the code *is*, plus what it cost to find out. Advisory |
| `PRD.md` §5 | **State** — what is done. The single source of truth for progress |

This brain cites rule codes; it never restates the rules. A fact that belongs in the TRD goes to
the TRD, in its own PR.

## Brain vs. code (the core rule)

The brain is **advisory**; the code is authoritative. If the brain says X but the code says Y,
**trust the code — then update the brain.** Verify any named file, function or flag still exists
before relying on it. When unsure whether a fact is durable, add it to
[open-questions.md](./open-questions.md) rather than inventing certainty.

## Repo coordinates

- Brain location: `.brain` (this directory). Pages are flat — no subdirectories.
- Stack: SwiftPM, `swift-tools-version: 6.2`, Swift 6 language mode. macOS 14+ / iOS 17+ /
  macCatalyst 17+ / tvOS 17+ / visionOS 1+.
- Branch: `main` (single branch; no integration/production split).
- Milestone: M1 in progress — M0's work is complete but its gate is un-flipped, pending an
  observed CI run (PROG-2). `PRD.md` §5 is authoritative.

## Validation quick links

```bash
swift build
swift test                                        # 165 tests / 28 suites
swift test --filter 'ContentBlockTests/textRoundTrips'    # symbol names, not @Test strings
swift test --sanitize=thread
swift format lint --strict --recursive .
```

Full set, including the `--target`-scoped Docs gate and the consumer loop: [commands.md](./commands.md).

## Before changing code

1. Read `AGENTS.md` — the boundaries and the Definition of Done.
2. Read the page above that owns your area, plus [gotchas.md](./gotchas.md).
3. Check the TRD section that governs it and cite the rule codes in your change.
4. Decide how you will validate *before* you implement.

## Maintenance

Route each durable fact to its owner page ([owner-page-taxonomy.md](./owner-page-taxonomy.md))
using the formats in [templates.md](./templates.md). Rewrite pages in full rather than appending.
Bump `Last reviewed:` on every page you touch. Commit brain edits separately as
`chore(brain): ...`, never in the same diff as feature code.
