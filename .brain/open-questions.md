# Open questions

Last reviewed: 2026-08-25
Source of truth: this file

Unresolved decisions that affect implementation. Add here instead of inventing certainty. When a
question is settled, move the answer to the page that owns it (see `owner-page-taxonomy.md`) and
delete the question.

- [ ] **No CI run has been observed yet.** The five workflows exist and the suite is green
      locally, but M0's gate stays un-flipped pending a link to a passing run (PROG-2). Until
      then, no claim about CI behaviour in this brain is verified — only about the workflow files.
- [ ] **Does ApusKitWireFormat earn its own target?** It landed as a separate layer between Core
      and Providers (`Package.swift`), carrying the WIRE-1 typed-throws carve-out. It holds only
      two kernels today and imports nothing from `ApusKitCore`. The rest of M1 — the three API
      implementations — will show whether the split earns its keep.
- [ ] **Should the nightly fuzz workflow land with the SSE and partial-JSON kernels alone?**
      `docs/ci-deferrals.md` names M1 as what gives the row a subject, but the row also covers the
      JSONL codec, which is M2. Two of the three targets now exist.
- [ ] **How are pi v3 session files obtained and licensed?** The SSE half of this is settled: no pi
      transcript could be obtained under a settled licence, so the ten transcripts under
      `Tests/Fixtures` were authored from each vendor's public streaming documentation to the same
      event shapes, recorded as `provenance: authored-from-vendor-docs` in
      `Tests/Fixtures/conformance-baseline.yml`. Swapping in real recordings later is a data change,
      not a code change. M2's session codec still needs fixtures with a known provenance, and TEST-3
      names pi v3 session files specifically.
- [ ] **What does the M0 gate's CI evidence look like in practice** — which workflow run counts
      as proof of "scripted multi-turn + fake tool round-trip green in CI"? PRD §5 M0 leaves the
      form of the link unspecified.
