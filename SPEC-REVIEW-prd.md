---
format: 1
register: prd
status: draft
fingerprint: 9ab9319b1d8e
docs: [PRD.md]
lenses: consistency, underspecified, external-deps, boundary
lens_failures:
sealed_at:
sealed_by:
engine: build-feature 1.3.0
---

# Spec review — PRD.md

Adjudications of this document, made by a human, applied by every later run. IDs are NOT rule
codes: never cite `spec-NNN` in code or in a task brief.
Is this file current?  From this directory: `cat PRD.md | shasum | cut -c1-12` must equal `fingerprint`.

## Decisions

### spec-001 · blocker · external_dep
key: external_dep@F1.2+M1+TEST-5|| m1 | real streaming | f1.1–f1.4, f2.1–f2.4 | live smoke vs anthropic and opena
where: PRD.md:82
refs: M1, F1.2, TEST-5
quote: | M1 | Real streaming | F1.1–F1.4, F2.1–F2.4 | Live smoke vs Anthropic AND OpenAI AND a consumer-injected custom-endpoint provider (F1.2) |
finding: M1's gate requires live traffic to two commercial vendor services and a third custom endpoint — funded accounts and network reachability that exist outside the repository — while the TRD forbids exactly those suites from blocking CI, so the gate can never appear as a green required check. It is also unstated who provides the third custom endpoint or whether a locally hosted one qualifies.
evidence: TRD.md:269 "- **TEST-5** Live provider suites are `@Suite(.enabled(if: env(\"ANTHROPIC_API_KEY\") != nil))`-style — never CI-blocking." TRD.md:311 backs M1 with a different, offline set instead: "gate = PROV-4 test + conformance fixtures (TEST-3) green for all three implementations".
question: Is the M1 gate a live run against externally hosted vendor services recorded as out-of-CI evidence, or the offline PROV-4/TEST-3 checks the TRD names as its technical backing?
options: [TRD] Declare the offline PROV-4 + fixture suite as the gating evidence and demote the live vendor smoke to a recorded, non-gating manual run (recommended) / [PRD] Keep the live smoke as the gate and state the out-of-CI evidence form (run log, dated attestation in §5) that satisfies PROG-2 without violating TEST-5
status: open

### spec-002 · blocker · external_dep
key: external_dep@F6.1+F6.2+M4|| m4 | mcp | f6.1–f6.3, f10.1 (`serve-mcp`) | cli calls a real external mcp serv
where: PRD.md:85
refs: M4, F6.1, F6.2
quote: | M4 | MCP | F6.1–F6.3, F10.1 (`serve-mcp`) | CLI calls a real external MCP server's tool through the loop over HTTP; a stock MCP client consumes an ApusKit tool server over stdio |
finding: Both halves of the M4 gate depend on software outside the repository — an unnamed third-party MCP server reachable over the network, and an unnamed third-party "stock" MCP client (F6.2 names Claude Desktop, a proprietary app requiring an account) — with no statement of which one is normative or how either is driven unattended. Two implementers would pick different servers and different clients, and one may pick a GUI client that cannot be exercised by a check at all.
evidence: PRD.md:49 "**F6.2** **Server:** expose an app's tools as an MCP server for other AI clients (Claude Desktop and friends)." TRD.md:314 defers the specifics back to the PRD: "| M4 MCP | §3.7 full, `apuskit-cli serve-mcp`; gate checks per PRD (HTTP external-server call + stdio stock-client consumption) |", so neither document names the server or the client.
question: Which specific external MCP server and which specific stock MCP client constitute the M4 gate, and is either permitted to be a manually driven GUI application?
options: [PRD] Name a specific, headlessly runnable reference server and reference client for the gate so the check is reproducible by anyone (recommended) / [TRD] Specify the gate against a locally launched conformance server/client from the MCP SDK, keeping the check free of network and account dependencies
status: open

### spec-003 · blocker · external_dep
key: external_dep@M6+PRD§4|| m6 | hardening → 1.0 | api freeze driven by real consumers | an external app s
where: PRD.md:87
refs: M6, PRD§4
quote: | M6 | Hardening → 1.0 | API freeze driven by real consumers | An external app ships on the released package — including its MCP server and a workflow — without forking it |
finding: The 1.0 gate is satisfiable only by a third party outside this repository choosing to ship a product, which no work inside the repository can cause, yet PRD §4 requires every gate to pass as an automated, evidence-linked check. Nothing states who qualifies as an external app, who signs off that it shipped, or what artefact records the pass.
evidence: PRD.md:77 "A milestone is **done** only when its gate passes as an automated, evidence-linked check." PRD.md:89 makes the release contingent on it: "**1.0 = the M6 gate**: the API is frozen by real consumption". PRD.md:156 `- [ ] **Gate:** external app ships on the released package without forking`.
question: What observable, recordable artefact from an outside consumer counts as the M6 gate passing, and who is authorised to declare it?
options: [PRD] Define the qualifying evidence and the sign-off owner for the external-consumer gate (named consumer, public release reference, dated attestation in §5) (recommended) / [PRD] Replace the third-party-shipping condition with an in-repo proxy that the project can execute (e.g. a consumer scenario built and run from the released package)
status: open

### spec-004 · major · untestable
key: untestable@F3.2+M2+SESS-1|- **f3.2** **pi interchange:** session files are wire-compatible with pi v3 — a 
where: PRD.md:32
refs: F3.2, SESS-1, M2
quote: - **F3.2** **pi interchange:** session files are wire-compatible with pi v3 — a pi session opens in ApusKit and vice versa.
finding: The "vice versa" half — an ApusKit-written session opening in pi — has no gate anywhere: SESS-1 only requires that a pi file loads, rebuilds and round-trips inside ApusKit, and no document pins a pi version, names a pi executable, or provides for running pi in CI. A verifier asked to prove the reverse direction has no command to run and reports it BLOCKED forever, while the forward direction also depends on a "real pi v3 session file" whose provenance and licence nothing specifies.
evidence: TRD.md:160 "- **SESS-1** Wire-compat is a tested guarantee: a real pi v3 session file loads, rebuilds context equivalently, and round-trips losslessly (fixtures in `Tests/Fixtures/`, deviations only via `conformance-baseline.yml`)." — load/rebuild/round-trip only; PKG-5 declares no pi dependency and §7 has no job that executes pi.
question: How is the ApusKit-to-pi direction of F3.2 proven — by executing a pinned pi build in CI, by a byte-level fixture comparison against pi-produced files, or is the claim narrowed to one direction?
options: Byte-level comparison against checked-in pi-produced fixtures at a pinned pi version, with the fixture provenance recorded (recommended) / A CI job that runs a pinned pi build over an ApusKit-written session
status: open
affects: M2, ApusKitSessions

### spec-005 · major · untestable
key: untestable@M6+PRD§4|| m6 | hardening → 1.0 | api freeze driven by real consumers | an external app s
where: PRD.md:87
refs: M6, PRD§4
quote: | M6 | Hardening → 1.0 | API freeze driven by real consumers | An external app ships on the released package — including its MCP server and a workflow — without forking it |
finding: This gate is an event in a third party's release process, not an observable of this repository, so no command, test or CI job could ever prove it and §5's ✅ can never be earned mechanically. The rule immediately above the table says a milestone is done only when its gate passes as an automated, evidence-linked check, which this gate cannot satisfy under either reading.
evidence: PRD.md:77 "Built strictly in order. A milestone is **done** only when its gate passes as an automated, evidence-linked check."; PROG-2 at PRD.md:93 requires "a link to the passing check (CI run / test)" — an external shipment produces neither.
question: What observable stands in for M6's external-adoption gate — a maintainer-attested evidence link, or an in-repo proxy such as a full-stack consumer example built in CI?
options: Keep external adoption as the product signal but define the attestation artefact that flips M6, exempting it from the automated-check rule (recommended) / Replace it with an in-repo proxy consumer (MCP server + workflow, released-package dependency) that CI builds
status: open
affects: M6, PROG-2

### spec-006 · major · external_dep
key: external_dep@F10.2+M3|| m3 | public 0.1.0 | f4.2/f4.4/f4.5, f5.1–f5.2, f10.1 (`chat`), f10.2, f10.3; p
where: PRD.md:84
refs: M3, F10.2
quote: | M3 | Public 0.1.0 | F4.2/F4.4/F4.5, F5.1–F5.2, F10.1 (`chat`), F10.2, F10.3; public repo + package listing | A clean-room consumer installs the package and runs the README example unmodified |
finding: The M3 deliverable depends on acceptance by an outside index (the TRD names SPI) and on a public hosting account, and the gate's "installs the package" step requires resolving from that public host — neither is under this repository's control nor scheduled. A planner cannot tell whether M3 is blocked on a third party's review queue or merely on local work.
evidence: TRD.md:313 "| M3 Public 0.1.0 | hook bus + `AgentExtension` (§3.6), DOC-1..4, Conformance Kit (TEST-6), `apuskit-cli chat` (DOC-2), governance files, SPI listing |"; PRD.md:138 "- [ ] Governance files, public repo, package-index listing". The repo already carries the index-side config: /Users/gregor/projects/ApusKit/.spi.yml lists documentation_targets, but nothing states who submits or owns the listing.
question: Is third-party acceptance of the package-index listing part of the M3 gate, or a post-milestone follow-up that does not block M3?
options: [PRD] Separate the index listing from the M3 gate and track it as an outside-dependency task with its own owner (recommended) / [PRD] Keep the listing inside M3 and state what evidence proves it (index URL, accepted submission reference)
status: open

### spec-007 · major · external_dep
key: external_dep@F7.3+M5+WF-3|| m5 | workflows | f7.1–f7.4 | a red-team workflow (parallel researchers → adver
where: PRD.md:86
refs: M5, F7.3, WF-3
quote: | M5 | Workflows | F7.1–F7.4 | A red-team workflow (parallel researchers → adversarial judge → synthesis) runs across two different providers using only public API |
finding: The M5 gate turns on "two different providers" without saying whether those must be two live third-party vendor services — two funded accounts and network access outside this repository — or whether two registered entries such as ScriptedProvider and a local endpoint satisfy it. One reading makes M5 a CI-runnable check, the other makes it a credentialed live run subject to the same TEST-5 conflict as M1.
evidence: TRD.md:315 restates it without resolving the ambiguity: "| M5 Workflows | §3.8 full (WF-1..4); gate = two-provider red-team workflow on public API, journaled (WF-1) |". F1.5 (PRD.md:22) establishes an offline provider exists: "A deterministic scripted provider so agents can be developed and tested with no network and no API keys."
question: Does the M5 gate require two live external vendor services, or do two distinct registered providers of any kind (including scripted or local) satisfy it?
options: [PRD] Specify that two distinct registered providers of any kind satisfy the gate, keeping M5 free of external accounts (recommended) / [PRD] Require two live vendor services and state the out-of-CI evidence form, matching whatever M1's live smoke resolves to
status: open

### spec-008 · minor · leak_prd
key: leak_prd@PRD§5+PROG-1|**current status: 🔨 m1 in progress — **m0 is complete** (2026-08-25): its gate 
where: PRD.md:95
refs: PRD§5, PROG-1
quote: **Current status: 🔨 M1 in progress — **M0 is complete** (2026-08-25): its gate is green in CI — `AgentGateTests/multiTurnToolRoundTrip` round-trips a scripted multi-turn conversation through a fake tool, including the return leg, in [Tests run 32883395354](https://github.com/ApusKit/ApusKit/actions/runs/32883395354) (165 tests, 28 suites on Swift 6.2).
finding: The PRD's status prose binds TRD-owned artefacts — a test target and method name, a toolchain version, target names such as `ApusKitWireFormat`, a dropped dependency (`swift-snapshot-testing`) and TRD rule codes (TEST-4, PKG-5, TOOL-1, TRUNC-1, PKG-6, ACC-2, SESS-1, DOC-3) — none of which the product statement introduces. A second TRD could not reuse these lines, and renaming any rule or target in the TRD silently falsifies the PRD.
evidence: PRD.md:95 also carries "`swift-snapshot-testing` was dropped for plain `#expect` (TEST-4, PKG-5)" and PRD.md:97 carries "the `ApusKitSessions` target ships as its own library target and product, depending only on `ApusKitCore` and `ApusKitWireFormat` (`PKG-6`)" — target names and rule codes defined only in TRD.md §2/§3/§5.
options: [PRD] Keep §5 status at capability/milestone granularity (F-ids, gate links, dates) and let the TRD-side detail live in the TRD or in the CI evidence it links to (recommended) / [PRD] Declare §5 explicitly as the Apple implementation's state, exempt from the PRD's platform-neutral body
status: noted

## History
- 2026-08-26 · full · 9ab9319b1d8e · 4 lenses · 8 findings (3 blocker, 4 major) · draft
