# Gotchas

Last reviewed: 2026-08-25
Source of truth: `docs/ci-deferrals.md`, `.github/workflows`, git history

Traps that already cost someone time. Every entry stays — they exist to stop rediscovery.
Entries marked **Safeguard** are merge blockers, not advice.

## `swift test --filter` takes symbol names, not `@Test` display strings

Symptom: `swift test --filter 'ContentBlock/text round-trips'` prints
`warning: No matching test cases were run`, runs zero tests, and **exits 0**.
Evidence: `Tests/ApusKitCoreTests/CoreTests.swift:17-21` — `@Suite("ContentBlock")` on
`struct ContentBlockTests`, `@Test("text round-trips")` on `func textRoundTrips()`.
Impact: a silent green. An agent filtering by the human-readable name concludes its change is
verified when nothing ran at all.
Do: filter on the Swift symbols — `swift test --filter 'ContentBlockTests/textRoundTrips'`.
Avoid: pasting the `@Suite`/`@Test` display strings into `--filter`. If a filtered run reports
0 tests, treat it as a failure and fix the filter.

## Unscoped DocC fails because of a dependency, not this package

Symptom: `swift package generate-documentation --warnings-as-errors` exits 1 with 184 errors.
Evidence: `docs/ci-deferrals.md` — swift-docc-plugin 1.5.0 documents all targets "in this
package **and its dependencies**"; swift-json-schema 0.9.1 cross-references a symbol that does
not exist.
Impact: looks like an ApusKit docs regression and invites a pointless hunt through our own doc
comments.
Do: always pass one `--target` per ApusKit target — the command in `commands.md` and in
`.github/workflows/docs.yml`.
Avoid: "simplifying" the Docs gate by dropping the `--target` flags. Adding a new target means
updating three places: `.spi.yml`, `.github/workflows/docs.yml`, and TRD §7.

## Consumer manifests must pin the root package name — **Safeguard**

Symptom: all six consumer builds fail with `unknown package 'ApusKit' in dependencies`, but only
in a checkout whose directory is not named `ApusKit`.
Evidence: commit `2337766`; `Examples/consumers/mainactor-consumer/Package.swift` shows the fix.
Impact: CI hid this because actions/checkout lands in a directory named after the repo — so it
was green here and broken for every real consumer, which is exactly what the consumer gate exists
to catch.
Do: `.package(name: "ApusKit", path: "../../..")` in every consumer manifest.
Avoid: bare `.package(path: "../../..")` — it derives package identity from the directory
basename.

## Every warning is a build failure

Symptom: a build fails on something that reads as a warning.
Evidence: `Package.swift` — `commonSwiftSettings` carries `.treatAllWarnings(as: .error)` plus
`StrictConcurrency` and the three PKG-3 upcoming features, and every target applies it.
Impact: a new target that spells out its own `swiftSettings` silently opts out of the whole law —
strict concurrency, existential-any, warnings-as-errors, all of it — and nothing flags the gap.
Do: reuse `commonSwiftSettings` for any new target.
Avoid: writing a fresh `swiftSettings:` array on a new target.

## Local green is not CI green

Symptom: `swift test` passes locally on a toolchain the package does not target.
Evidence: local toolchain is Swift 6.3.2; `Package.swift` declares `swift-tools-version: 6.2`,
and `.github/workflows/tests.yml` runs a 6.2 leg plus a nightly leg installed via swiftly
(commit `570a9cb`).
Impact: PRD gates flip only on a link to a passing CI run (PROG-2). A local pass is evidence for
you, never evidence for the gate.
Do: say "green locally" and leave the gate un-flipped until CI is observed.
Avoid: marking a milestone ✅ from a local run.

## Five CI gates are deliberately absent at M0

Symptom: TRD §7 lists ten gate rows; `.github/workflows` holds five workflows.
Evidence: `docs/ci-deferrals.md` names each missing row and the milestone that gives it a
subject — Soundness, API breakage, traits matrix, nightly fuzz, nightly benchmarks.
Impact: an agent "fixing" the gap ships inert or always-skipped jobs that hide real failures
later.
Do: read `docs/ci-deferrals.md` before adding a workflow; add the row when its milestone lands.
Avoid: treating the five missing workflows as an oversight.

## The NIO and MCP traits are declared but inert

Symptom: building with `--traits NIO` or `--traits MCP` changes nothing.
Evidence: `docs/ci-deferrals.md` (traits-matrix row) — no source file is conditionalized on
either trait yet.
Impact: a traits-matrix CI job would build the identical tree four times and prove nothing.
Do: expect traits to become live at M1 (NIO) and M4 (MCP).
Avoid: assuming trait-gated code already exists.

## `.agentwork/` needs `.gitignore`, not `.git/info/exclude`

Symptom: in a fresh clone, a `build-feature` run leaves `.agentwork/` untracked and the next
run's clean-tree preflight refuses to start.
Evidence: `.gitignore` now lists it; before 2026-08-25 it was only in `.git/info/exclude`, which
is machine-local and never travels with a clone.
Impact: the brain cache and per-run plan artifacts would get swept into an unrelated commit, or
block the workflow outright.
Do: keep `.agentwork/` in `.gitignore`.
Avoid: relying on a local exclude for anything another clone must also ignore.

## Public async APIs must declare where they run — **Safeguard**

Symptom: a new `public` async function compiles fine and violates CC-2.
Evidence: `Sources/ApusKitTools/Tool.swift:31` — `@concurrent` on `Tool.execute`.
Impact: where code runs is an API contract; adding the annotation later is a source-breaking
change for consumers, and CC-3's Sendable audit is what makes it SemVer-visible.
Do: annotate every public async API `@concurrent` (always off-caller) or `nonisolated(nonsending)`
(runs on the caller's actor), and update `docs/sendable-audit.md` in the same change.
Avoid: leaving isolation implicit on a public async declaration.
