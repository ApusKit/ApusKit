# CI deferrals

TRD §7 lists ten CI gate-table rows. Five are implemented as workflows in
`.github/workflows/` at M0 (R8). The other five have no subject yet at M0
— nothing in the M0 tree exercises them — so they are recorded here
instead of shipped as an inert or always-skipped job. Each gets a
workflow once the milestone that gives it a subject lands.

| §7 row | Why it has no subject at M0 | Milestone that gives it a subject |
|---|---|---|
| Soundness (`swiftlang/github-workflows` reusable: license headers, format, DocC `--analyze`) | The reusable workflow duplicates checks this milestone's own `Format`/`Docs` jobs already run standalone; wiring the shared reusable workflow is a governance step, not an M0 build-shape concern. | M3 Public 0.1.0 (governance files land alongside the reusable-workflow adoption) |
| API breakage (`swift package diagnose-api-breaking-changes` vs PR base) | There is no prior tagged/released API to diff against — M0 is the first commit establishing the public surface. | M3 Public 0.1.0 (first tagged 0.1.0 gives the tool a base to diff against) |
| Traits matrix (build with no traits / `NIO` / `MCP` / both) | `NIO` and `MCP` traits are declared in `Package.swift` (PKG law) but inert: no source file is conditionalized on either trait yet, so every leg of the matrix would build the identical, trait-blind M0 tree — nothing to vary. | M1 Real streaming (`NIO`, via `AsyncHTTPClientTransport`) and M4 MCP (`MCP` trait) |
| Fuzz (nightly): libFuzzer+ASan on SSE + JSONL + partial-JSON kernels | The wire-format kernels (SSE parser, JSONL, partial-JSON) don't exist yet — M0 ships no parsing code to fuzz. | M1 Real streaming (§3.2 kernels) |
| Benchmarks (nightly): `package-benchmark` run, trend recorded | No hot path exists to benchmark yet: `ScriptedProvider` and the M0 run loop are deterministic, in-memory, and not performance-sensitive. | M1 Real streaming (real wire-format kernels give the suite something worth trending) |

## Docs gate deviation

The `Docs` row *is* shipped (`.github/workflows/docs.yml`), but not with
§7's literal command line. Run unscoped, `swift package
generate-documentation --warnings-as-errors` exits 1 — and not because of
ApusKit.

With no `--target`, swift-docc-plugin 1.5.0 documents
`Package.allDocumentableTargets`, described in the plugin's own source
(`Plugins/SharedPackagePluginExtensions/PackageExtensions.swift`) as "All
targets defined in this package **and its dependencies** that can produce
documentation". So the unscoped run also builds documentation for
swift-json-schema's `JSONSchema` and `JSONSchemaBuilder` modules, whose
own doc comments carry broken cross-references — errors under
`--warnings-as-errors`. The defect is in a pinned third-party dependency;
fixing it is not in ApusKit's gift, and the dependency is required by
PKG-5 (`swift-json-schema` for `@Schemable`) and by §3.4's `Tool`
signature (`associatedtype Arguments: Schemable & Decodable & Sendable`).

Measured, not assumed:

- Unscoped run: **exit 1, 183 `error:` diagnostics, every one of them
  raised against a swift-json-schema source file**; zero originate in an
  ApusKit target (174 name `/JSONSchemaBuilder/...` in the message
  itself, the other 9 point at
  `Sources/JSONSchemaBuilder/JSONComponent/JSONSchemaComponent.swift`).
  By file: `JSONComponent/JSONSchemaComponent+Conditionals.swift` (87),
  `JSONComponent/TypeSpecific/JSONObject.swift` (29),
  `Documentation.docc/Articles/*.md` (15),
  `JSONComponent/JSONSchemaComponent.swift` (8). By family:
  ``Keywords`` (58), ``dependentRequired`` (31),
  ``Keywords.AdditionalProperties`` (29), ``dependentSchemas`` (29).
- Those links are **unresolvable by construction**: `Keywords` is
  declared `package enum Keywords` in
  `Sources/JSONSchema/Keywords/Keywords.swift` — a *different* module,
  below `public`, so it is absent from JSONSchemaBuilder's symbol graph.
- **Nothing to bump to.** `v0.9.1` — the version PKG-5 pins exactly — is
  swift-json-schema's newest tag (`git ls-remote --tags`), so there is no
  later release carrying a fix.
- **Not fixable by bumping the plugin.** `swift-docc-plugin`'s newest tag
  is 1.5.0 — the resolved version — and it still selects
  `context.package.allDocumentableTargets` whenever no `--target` is
  given (`Plugins/Swift-DocC Convert/SwiftDocCConvert.swift:22-25`). The
  plugin exposes no flag to exclude a dependency's targets; `--target` is
  the only lever.

The workflow therefore passes one `--target` per ApusKit target — the
same five as `.spi.yml`'s `documentation_targets` — which is what DOC-1
("DocC per target") asks for, and which is clean (exit 0, five archives).
Revisit if swift-json-schema fixes the cross-references upstream, or if
swift-docc-plugin gains a dependency-exclusion flag, at which point the
unscoped form can be restored verbatim.
