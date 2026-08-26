# Open questions

Last reviewed: 2026-08-26
Source of truth: this file

Unresolved decisions that affect implementation. Add here instead of inventing certainty. When a
question is settled, move the answer to the page that owns it (see `owner-page-taxonomy.md`) and
delete the question.

- [x] **Does ApusKitWireFormat earn its own target?** *Resolved 2026-08-26: yes.* It now holds
      three kernels (SSE, partial-JSON, JSONL), and the JSONL one is consumed by `ApusKitSessions`
      — a target that is not `ApusKitProviders`. Two unrelated consumers across two milestones is
      the split paying for itself; a merged WireFormat+Providers would have forced Sessions to
      import the provider layer, which PKG-6 forbids. Move to `architecture.md` and delete.
- [ ] **Should the nightly fuzz workflow land with the SSE and partial-JSON kernels alone?**
      `docs/ci-deferrals.md` names M1 as what gives the row a subject. As of 2026-08-26 all three
      kernels exist — SSE, partial-JSON and JSONL — so the row finally has its full subject and the
      deferral's own stated trigger is met. Nothing has landed the workflow itself.
- [ ] **How are pi v3 session files obtained and licensed?** The SSE half of this is settled: no pi
      transcript could be obtained under a settled licence, so the ten transcripts under
      `Tests/Fixtures` were authored from each vendor's public streaming documentation to the same
      event shapes, recorded as `provenance: authored-from-vendor-docs` in
      `Tests/Fixtures/conformance-baseline.yml`. Swapping in real recordings later is a data change,
      not a code change. The session half is now settled the same way: no licensed pi v3 file could be
      obtained, so `Tests/Fixtures/sessions/pi-v3-session.jsonl` was authored 2026-08-26 from pi's
      public v3 format alongside this repo's own codec, recorded as
      `provenance: authored-from-pi-source`. **The question that remains is narrower and is the
      only thing blocking M2's gate:** can a real, licensed pi v3 session file be obtained? Until
      one is, `SessionConformanceTests` proves the fixture is self-consistent with the codec it was
      authored beside — not that either matches real pi output.
- [ ] **Should PKG-2 keep declaring `.tvOS(.v17)` and `.visionOS(.v1)`?** Neither has a plausible
      consumer for a coding-agent harness, and every declared platform is a support obligation and
      an availability constraint. Raised by the M1 TRD audit and deliberately left unchanged: cutting
      them removes reach, so it is a product decision rather than a defect. `.macOS`/`.iOS`/
      `.macCatalyst` are the ones with a real story today.
