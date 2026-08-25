# AGENTS.md — ApusKit

Swift 6.2 SwiftPM library: a Swift-native agent harness, a faithful port of the core of
[pi](https://github.com/earendil-works/pi) (MIT). Five library products, zero hardcoded vendors —
consumers inject providers through public protocols.

`CLAUDE.md` is a symlink to this file. **Edit this file only.**

## Reading order

1. This file (`AGENTS.md`) — boundaries, commands, Definition of Done.
2. `.brain/INDEX.md` — the project brain: durable knowledge, as-built. Read it before any broad
   codebase research, then only the page your task needs (`code-maps.md` for where code lives,
   `gotchas.md` before debugging anything surprising).
3. `TRD.md` — the normative spec, for the section governing your change.

Precedence when they disagree: **the code is authoritative, `TRD.md` is binding, the brain is
advisory.** If the brain says X and the code says Y, trust the code and correct the brain.
Durable findings go to the page that owns them (`.brain/owner-page-taxonomy.md`); uncertain ones
go to `.brain/open-questions.md`. Commit brain edits separately as `chore(brain): ...` — never in
the same diff as feature code.

## Non-negotiable rules

**IMPORTANT: `TRD.md` is the law, not a suggestion.** §4 (coding practices), §5 (testing) and §7
(CI gates) bind every change. Read the relevant section before writing code, and **cite the rule
code** (`CC-2`, `ACC-2`, `FORB-2`, …) for any judgment call, in the code comment or the PR body.

**IMPORTANT: `PRD.md` §5 is the single source of truth for project state.** Update it in the same
PR that completes a deliverable (PROG-1), date completed items (PROG-4), and mirror the *Current
status* line into `README.md` (PROG-3). **A gate flips to ✅ only with a link to a passing CI run**
(PROG-2) — never because it passed locally.

**Never:**
- Force unwrap, `try!`, or implicitly-unwrapped optionals in production code (FORB-2).
- Locks, semaphores, `DispatchQueue`, or sync I/O on an actor — actors and `AsyncStream` only (CC-4).
- `@frozen`, `@inlinable`, `@usableFromInline`, `@_spi`, `@_exported` outside the umbrella (FORB-1).
- Import AppKit/UIKit/the ObjC runtime anywhere in the package (FORB-3). No Linux CI, but nothing
  may be written that *would* block Linux.
- XCTest. Swift Testing only (TEST-1). No URLProtocol stubbing — use the protocol-seam fakes (TEST-2).
- Singletons or global mutable state; `Date()`, wall-clock `Task.sleep`, or `URLSession.shared`
  inside logic — clock and transport are injected (DI-1, DI-3).
- Violate the dependency DAG (PKG-6): no lower target ever imports `ApusKitAgent`, and
  `ApusKitAgent` never imports `ApusKitMCP`/`ApusKitWorkflows`.
- Put SwiftNIO or MCP-SDK types on the public surface — both are fully wrapped (DEP-1).
- Hardcode a provider/vendor anywhere in the library.

**Ask first:**
- A new public API family — it needs `docs/proposals/NNNN-<name>.md` in the same or a prior PR (DOC-4).
- A new dependency (PKG-5 lists the allowed set; exact-pin anything 0.x).
- Editing `CHANGELOG.md` (maintainer-curated) or flipping a milestone status.
- Any work outside the current milestone's scope — if it isn't in `TRD.md` or `PRD.md`, it needs a
  proposal first (§9.8).

**Always:**
- Doc-comment every `public` declaration, first line a single-sentence summary (API-1).
- Annotate every public async API explicitly `@concurrent` or `nonisolated(nonsending)` — where code
  runs is an API contract (CC-2).
- Update `docs/sendable-audit.md` when the public surface changes (CC-3); adding `Sendable`
  constraints post-release is SemVer-major.
- Land a bugfix with the regression test that reproduces it, written first (TEST-7).
- Reuse `commonSwiftSettings` in `Package.swift` for any new target — never redefine the settings.
- Sign commits: `git commit -s` (DCO).

## Commands

```bash
swift build
swift test
swift test --filter 'ContentBlockTests/textRoundTrips'   # source symbol names, NOT @Test display names
swift test --sanitize=thread                             # TSan gate
swift format lint --strict --recursive .                 # Format gate
swift format --in-place --recursive .                    # apply formatting
swift package generate-documentation \
  --target ApusKitCore --target ApusKitWireFormat --target ApusKitProviders --target ApusKitTools \
  --target ApusKitSessions --target ApusKitAgent --target ApusKit --warnings-as-errors   # Docs gate — MUST stay --target-scoped
for d in Examples/consumers/*/; do swift build --package-path "$d"; done   # Consumer gate
```

`--filter` matches the Swift *symbol* names (`ContentBlockTests/textRoundTrips`), not the
`@Suite`/`@Test` display strings — filtering on a display string silently runs zero tests.

The Docs command must name each target. Unscoped, it also documents dependencies, and
`swift-json-schema` 0.9.1's own broken cross-reference turns into 184 fatal errors under
`--warnings-as-errors`. Adding a target means adding it to `.spi.yml`, `.github/workflows/docs.yml`,
and the command above. See `TRD.md` §7 and `docs/ci-deferrals.md`.

Warnings are errors everywhere (`treatAllWarnings(as: .error)`) — a warning fails the build.

## Architecture

```
ApusKitCore ← ApusKitProviders ┐
ApusKitCore ← ApusKitTools     ├→ ApusKitAgent → ApusKit (umbrella, re-export only)
```

- Every target is its own library product and **must be usable standalone**, without the agent loop.
  `Examples/consumers/*` exists to prove it: each declares exactly one ApusKit product dependency,
  and the consumer CI job compiles them all (DOC-3). `mainactor-consumer` simulates an app consumer via
  `.defaultIsolation(MainActor.self)`.
- Library targets keep **nonisolated default isolation** — never `-default-isolation MainActor` in
  library code (CC-1).
- Traits: `NIO`, `MCP`. Default traits are **none** — everything else must build with zero traits (PKG-4).
- `Tests/Shared` is the `TestSupport` target — the protocol-seam fakes (`RecordingTool`, `ThrowingTool`,
  `GateTool`, `HangingProvider`, `RequestRecordingProvider`); one test target per source target.
- Cross-target internals use the `package` access level, never `@_spi` (ACC-1/PKG-8).
- Conformable protocols are a closed set — `APIImplementation`, `Tool`, `SessionStore`,
  `StreamingHTTPTransport`, `AgentExtension`, hook handlers. **Everything else is sealed** (ACC-2).

The full target specs are `TRD.md` §3; the layout is §1. Don't restate them here.

## Code style

`.swift-format` enforces `AllPublicDeclarationsHaveDocumentation`, `NeverForceUnwrap`,
`NeverUseImplicitlyUnwrappedOptionals`, `OrderedImports`. Naming follows the swift.org API Design
Guidelines (API-2). Public errors are structs with a `@nonexhaustive` `Code` enum, never public
enums (ERR-2); public APIs use untyped `throws` (ERR-1). Use `internal import` for every non-API
dependency (DEP-2).

```swift
/// Decodes a single server-sent event into a stream event.
///
/// - Complexity: O(*n*) in the length of `payload`.
@concurrent
public func decode(_ payload: String) throws -> StreamEvent
```

## Git workflow

Integration branch is `main`. Conventional Commits with a scope, milestone scopes where they apply
(`feat(m0):`, `test(m0):`, `docs(trd):`, `ci:`, `fix(examples):`). Commit bodies explain *why*, and
for a test change, state what mutant it was proven to catch. All commits DCO-signed (`git commit -s`).

## Definition of Done (`TRD.md` §9)

1. Rule codes cited for judgment calls.
2. Every required §7 CI job green; no new warnings.
3. New/changed public API: doc comments, explicit isolation annotation, Sendable audit updated,
   proposal linked if it's a new family.
4. Tests included — unit for logic, conformance fixture if wire-facing, regression test if a bugfix.
5. `PRD.md` §5 updated in the same PR; `README.md` status regenerated if the status line changed.
6. `CHANGELOG.md` untouched.
7. No scope beyond the milestone task.

## Where to look

`PRD.md` (capabilities, milestones, §5 state) · `TRD.md` (technical law) · `README.md` (status) ·
`docs/sendable-audit.md` · `docs/ci-deferrals.md` · `.brain/INDEX.md` (project brain) ·
`.agentwork/` (per-run plans, gitignored).
