# Commands

Last reviewed: 2026-08-25
Source of truth: `.github/workflows`

Verbatim, runnable. Every command below is either taken from a workflow file or was run in this
checkout. Toolchain: Swift 6.2+ required (`Package.swift` declares `swift-tools-version: 6.2`).

## Everyday

```bash
swift build                     # must be warning-free; warnings are errors
swift test                      # 136 tests / 26 suites as of 2026-08-25
swift package resolve
```

Treat any quoted test count as a smell rather than a fact — it is stale the moment a suite is
added. `PRD.md`'s status line and its `README.md` mirror quote a count too (PROG-3 keeps the two in
step); if they disagree with a fresh `swift test`, the fresh run wins and both files need the
correction in the same commit.

## One test

```bash
swift test --filter 'ContentBlockTests/textRoundTrips'
```

`--filter` matches the Swift **symbol** names — the `struct` and the `func` — not the
`@Suite("...")` / `@Test("...")` display strings. Filtering on a display string runs zero tests
and still exits 0. See `gotchas.md`.

## The CI gates

```bash
swift test                                              # Tests      (.github/workflows/tests.yml)
swift test --sanitize=thread                            # TSan       (.github/workflows/tsan.yml)
swift format lint --strict --recursive .                # Format     (.github/workflows/format.yml)
swift package generate-documentation \
  --target ApusKitCore --target ApusKitWireFormat --target ApusKitProviders \
  --target ApusKitTools --target ApusKitAgent --target ApusKit \
  --warnings-as-errors                                  # Docs       (.github/workflows/docs.yml)
for d in Examples/consumers/*/; do swift build --package-path "$d"; done   # Consumers
```

The Docs command **must** stay `--target`-scoped; unscoped it fails on a dependency's doc
comments. See `gotchas.md`.

## Fix formatting

```bash
swift format --in-place --recursive .
```

## Nightly / deferred

Five of TRD §7's ten gate rows still have no workflow — Soundness, API breakage, traits matrix,
nightly fuzz, nightly benchmarks. `docs/ci-deferrals.md` records why and which milestone revives
each. Do not add them early.

## Validation

Running `swift format lint --strict --recursive .` and `swift test` covers the two gates that
catch almost everything. Add `--sanitize=thread` when touching `Sources/ApusKitAgent`.

## Open questions

None.
