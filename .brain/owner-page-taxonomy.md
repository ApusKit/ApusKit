# Owner-page taxonomy

Last reviewed: 2026-08-25
Source of truth: this file

Each fact-type has exactly one home page. Route durable knowledge here so the brain stays
findable and free of duplication. The harvest step of an automated run uses this table.

| Fact category | Page |
|---|---|
| Where code lives | `code-maps.md` |
| Architectural shape, data flow, cross-cutting Norms | `architecture.md` |
| Trap, sentinel, env mismatch, ordering constraint, Safeguard | `gotchas.md` |
| Branch / worktree / workflow rules | `workflows.md` |
| Dev / test / build / e2e command | `commands.md` |
| Product domain, vocabulary, what a product is for | `project-overview.md` |
| Unresolved decision | `open-questions.md` |

## Norms vs. Safeguards

Cross-cutting rules live in the brain and are handed to implementers and reviewers directly:

- **Norm** — a cross-cutting convention (e.g. "constructor injection everywhere, no singletons").
  Home: `architecture.md` / `code-maps.md`.
- **Safeguard** — a hard, non-negotiable limit treated as a merge blocker (e.g. "no locks or
  DispatchQueue; actors and AsyncStream only"). Home: `gotchas.md` / `architecture.md`.

## Brain vs. TRD

`TRD.md` is **normative**: what the code must be, expressed as rule codes (`CC-2`, `FORB-2`, …).
This brain is **descriptive**: what the code is, plus what it cost to find out. Cite a rule code;
never restate the rule. A fact that belongs in the TRD goes to the TRD, in its own PR.
