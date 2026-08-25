import ApusKitCore
import ApusKitProviders

// Proves `ApusKitProviders` is usable with `ApusKitProviders` as the
// package's only product dependency — which is what DOC-3 gates. The
// `import ApusKitCore` is required, not accidental: ApusKitProviders
// declares `public import ApusKitCore`, but that propagates API-surface
// diagnostics, NOT transitive bare-name visibility, so spelling `Usage`
// and the `StreamEvent` cases here needs the declaring module imported.
// Package.swift still declares exactly one ApusKit product.
//
// The script is a real PROV-1 sequence — exactly one `.start` first, one
// terminal `.done` last — rather than an empty one. An empty script is a
// turn that streams no events at all, which is precisely what PROV-1
// forbids, so shipping it as the worked example would document the
// opposite of the rule.
var registry = ProviderRegistry()
registry.register(
  ScriptedProvider(
    id: .scripted,
    scripts: [
      [
        .start,
        .textDelta(contentIndex: 0, text: "hello from a scripted turn"),
        .done(usage: Usage(inputTokens: 1, outputTokens: 1), stopReason: .endTurn),
      ]
    ]
  )
)
print(registry.implementation(id: .scripted)?.id.rawValue ?? "none")
