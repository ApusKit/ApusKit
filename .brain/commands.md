# Commands

Last reviewed: 2026-08-26
Source of truth: `.github/workflows`

Verbatim, runnable. Every command below is either taken from a workflow file or was run in this
checkout. Toolchain: Swift 6.2+ required (`Package.swift` declares `swift-tools-version: 6.2`).

## Everyday

```bash
swift build                     # must be warning-free; warnings are errors
swift test                      # counts move every run — read the output, not this line
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

`--filter` is an unanchored **regex**, and it matches the test's source file **basename** as well as
the `struct`/`func` symbol names. It does *not* match `@Suite("...")` / `@Test("...")` display
strings. So `--filter 'CoreTests\.swift'` selects all 21 tests in
`Tests/ApusKitCoreTests/CoreTests.swift` even though no `CoreTests` type exists, while
`--filter 'ContentBlock/text round-trips'` runs zero tests and still exits 0. Guard any scoped run:

```bash
swift test --filter 'ContentBlockTests/textRoundTrips' > run.log 2>&1; echo "EXIT=$?"
grep -qE 'Test run with [1-9]' run.log || echo "SELECTED NOTHING"
```

See `gotchas.md`.

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
