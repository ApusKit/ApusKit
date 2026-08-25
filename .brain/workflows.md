# Workflows

Last reviewed: 2026-08-25
Source of truth: `AGENTS.md`, `PRD.md`

How work moves through this repo. Branch and commit conventions live in `AGENTS.md` and are not
duplicated here — this page covers milestone gating, run artifacts, and the brain's own loop.

## Summary

- Single branch: `main`. No integration/production split, no worktree convention.
- Work is milestone-driven. TRD §8 maps each PRD milestone to the technical checks that back it.
- Every PR satisfies the Definition of Done in TRD §9 — nine numbered items, including "rule codes
  cited for any judgment call".

## Milestone gating (PROG-1..4)

- **PROG-1** — update `PRD.md` §5 in the *same* PR that completes a deliverable.
- **PROG-2** — a gate flips to ✅ **only** with a link to the passing CI run. Local green is not
  evidence. This is why M0 is still 🔨 despite the suite passing.
- **PROG-3** — `README.md`'s status section mirrors PRD §5's *Current status* line. Change one,
  regenerate the other.
- **PROG-4** — completed items carry a date.

Scope discipline (TRD §9.8): if it isn't in `TRD.md` or `PRD.md`, it needs a proposal first. New
public API families start as a proposal document (DOC-4) before the code.

## Run artifacts

`.agentwork/<date>-<slug>/plan.md` holds one feature run's frozen intent, requirements, task
table and verdicts — see `.agentwork/2026-08-24-m0-skeleton/plan.md` for the M0 example. These are
per-run records, not durable knowledge: what survives a run belongs in this brain instead.

`.agentwork/` is gitignored. It is scratch, and it must stay ignored in every clone — see
`gotchas.md`.

## The brain loop

- **Read** — `AGENTS.md` → `.brain/INDEX.md` → the page your task needs. Automated runs distil
  the brain once and cache the result under `.agentwork`, keyed to a hash of `.brain` only, so a
  code commit does not invalidate it.
- **Write** — when a run learns something durable, route it to its owner page via
  `owner-page-taxonomy.md`, using the formats in `templates.md`.
- **Commit separately.** Brain edits land in their own commit, `chore(brain): ...`, never in the
  same diff as feature code. Documentation must be reviewable independently.
- **Rewrite, don't append.** Full-page rewrites force summarisation and keep pages scannable.
- Bump `Last reviewed:` on every page you touch, and delete the cache so the next run re-distils.

## Relevant files

| Path | Why it matters |
|---|---|
| `AGENTS.md` | Branch model, commit conventions, Never/Ask-first/Always boundaries |
| `PRD.md` | §5 progress table and the PROG rules |
| `TRD.md` | §8 build order, §9 Definition of Done |
| `.agentwork` | Per-run plan artifacts (gitignored) |

## Gotchas

Local green is not CI green; see `gotchas.md`.

## Validation

Before opening a PR: `swift format lint --strict --recursive .`, `swift test`, and the gates in
`commands.md` that your change touches.

## Open questions

See `open-questions.md`.
