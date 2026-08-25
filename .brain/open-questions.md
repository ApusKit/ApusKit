# Open questions

Last reviewed: 2026-08-25
Source of truth: this file

Unresolved decisions that affect implementation. Add here instead of inventing certainty. When a
question is settled, move the answer to the page that owns it (see `owner-page-taxonomy.md`) and
delete the question.

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
- [ ] **How long does the nightly Tests leg stay red?** It fails compiling
      `swift-snapshot-testing`'s `AssertSnapshot.swift:648` — `generic struct 'Attachment' requires
      that 'NSImage' conform to 'Attachable'` — against the unreleased toolchain's swift-testing
      attachment API. Nothing in ApusKit is involved, and §7 marks this leg the non-required half of
      its row (`continue-on-error` in `tests.yml`), so it does not block. It resolves when
      swift-snapshot-testing catches up; until then the leg carries no signal about this package,
      and a real ApusKit break on nightly would be hidden behind it.
